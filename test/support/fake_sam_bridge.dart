import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// An in-process SAM v3 bridge: enough of i2pd's SAM surface for the REAL
/// [I2PTransport] to run against, with no I2P network, no daemon and no
/// tunnel build. Two transports pointed at one bridge can message each other
/// the way two phones do — same SAM conversation, same UDP forwarding, same
/// datagram framing.
///
/// It exists because the I2P path had no lab. The loopback lab replaces the
/// transport entirely, so everything below PhantomCore — the SAM handshake,
/// the forwarded-datagram header, the ACK/retransmit layer, destination
/// learning — ran for the first time on a phone, and both of the bugs that
/// cost a field test lived exactly there.
///
/// Faithful in the ways that have actually bitten:
///
///  * **Version-dependent datagram header.** Up to SAM 3.1 a forwarded
///    datagram is `<dest>\n<payload>`; from 3.2 it is
///    `<dest> FROM_PORT=n TO_PORT=n\n<payload>`. We negotiate 3.3, so the
///    second shape is what a phone really sees — and reading that whole line
///    as the destination is what poisoned the address book.
///  * **Silence on a bad destination.** SAM does not report an unroutable
///    send. The datagram is dropped and the sender's UDP write still
///    succeeds, so a broken destination looks exactly like a working one
///    from the app's side. [droppedSends] is the visibility the real bridge
///    denies you.
///  * **Loss.** I2P datagrams are fire-and-forget; [lossRate] makes that
///    concrete so the ARQ can be tested rather than assumed.
class FakeSamBridge {
  /// Highest SAM version the bridge speaks. 3.3 mirrors a current i2pd; drop
  /// it to 3.1 to reproduce a pre-3.2 bridge, whose datagram header carries
  /// no ports.
  final double maxVersion;

  /// When true, the destination in a datagram send header is taken as the
  /// whole remainder of the line — the behaviour of a SAM bridge that does
  /// not parse per-datagram options. A destination with anything appended is
  /// then unroutable. Older i2pd did this; whether a given build tolerates
  /// the options is not something to bet a conversation on, so the transport
  /// must send a bare destination and this flag pins that.
  final bool strictSendHeader;

  /// Fraction of forwarded datagrams to drop, 0.0–1.0.
  double lossRate;

  /// Artificial one-way delay before a datagram is forwarded.
  Duration latency;

  final Random _rng;

  ServerSocket? _tcp;
  RawDatagramSocket? _udp;

  final Map<String, _SamSession> _byId = {};
  final Map<String, _SamSession> _byDest = {};
  final List<Socket> _clients = [];

  /// Send headers the bridge could not route, as the destination string the
  /// client asked for. A non-empty list after a failed test says the app sent
  /// to something SAM does not recognise.
  final List<String> droppedSends = [];

  /// Datagrams actually forwarded to a session's UDP port.
  int deliveredCount = 0;

  /// Datagrams dropped by [lossRate].
  int lostCount = 0;

  FakeSamBridge({
    this.maxVersion = 3.3,
    this.strictSendHeader = false,
    this.lossRate = 0.0,
    this.latency = Duration.zero,
    int seed = 1,
  }) : _rng = Random(seed);

  /// TCP control port — pass as `samPort`.
  int get samPort => _tcp!.port;

  /// UDP datagram port — pass as `samUdpPort`. The transport defaults it to
  /// `samPort - 1`, which two ephemeral binds cannot promise, so a lab always
  /// passes it explicitly.
  int get samUdpPort => _udp!.port;

  /// True once both sockets are listening.
  bool get isRunning => _tcp != null && _udp != null;

  Future<void> start() async {
    _udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    _udp!.listen(_onUdp, onError: (_) {}, cancelOnError: false);
    _tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _tcp!.listen(_onClient, onError: (_) {}, cancelOnError: false);
  }

  Future<void> dispose() async {
    for (final c in List.of(_clients)) {
      try { await c.close(); } catch (_) {}
    }
    _clients.clear();
    _udp?.close();
    _udp = null;
    try { await _tcp?.close(); } catch (_) {}
    _tcp = null;
    _byId.clear();
    _byDest.clear();
  }

  /// The public destination the session named [sessionIdPrefix] ended up with.
  /// Tests normally use [destinationOf] via the transport instead.
  String? destinationFor(String sessionIdPrefix) => _byId.entries
      .where((e) => e.key.startsWith(sessionIdPrefix))
      .map((e) => e.value.dest)
      .firstOrNull;

  /// Every destination currently registered on the bridge.
  List<String> get destinations => _byDest.keys.toList();

  // ── SAM control socket ────────────────────────────────────────────────────

  void _onClient(Socket socket) {
    _clients.add(socket);
    var version = 3.0;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      void reply(String s) {
        try { socket.add(utf8.encode('$s\n')); } catch (_) {}
      }

      if (line.startsWith('HELLO')) {
        // HELLO VERSION MIN=a MAX=b — answer with the highest we both speak.
        final min = _numOpt(line, 'MIN') ?? 3.0;
        final max = _numOpt(line, 'MAX') ?? 3.0;
        if (min > maxVersion) {
          reply('HELLO REPLY RESULT=NOVERSION');
          return;
        }
        version = max < maxVersion ? max : maxVersion;
        reply('HELLO REPLY RESULT=OK VERSION=$version');
        return;
      }

      if (line.startsWith('SESSION CREATE')) {
        final id = _strOpt(line, 'ID');
        final destArg = _strOpt(line, 'DESTINATION') ?? 'TRANSIENT';
        final port = int.tryParse(_strOpt(line, 'PORT') ?? '');
        if (id == null || port == null) {
          reply('SESSION STATUS RESULT=I2P_ERROR MESSAGE="bad create"');
          return;
        }
        if (_byId.containsKey(id)) {
          reply('SESSION STATUS RESULT=DUPLICATED_ID');
          return;
        }
        // TRANSIENT mints a fresh keypair; anything else is a private key we
        // handed out earlier, whose first 516 chars are its destination.
        final priv = destArg == 'TRANSIENT' ? _newPrivateKey() : destArg;
        final dest = priv.substring(0, _destLen);
        final session = _SamSession(
            id: id, dest: dest, priv: priv, forwardPort: port, version: version);
        _byId[id] = session;
        _byDest[dest] = session;
        reply('SESSION STATUS RESULT=OK DESTINATION=$priv');
        return;
      }

      if (line.startsWith('NAMING LOOKUP')) {
        final name = _strOpt(line, 'NAME');
        if (name == 'ME') {
          // The session that owns this control socket is the most recent one
          // created on it; a lab client only ever creates one.
          final mine = _byId.values.isEmpty ? null : _byId.values.last;
          if (mine == null) {
            reply('NAMING REPLY RESULT=KEY_NOT_FOUND NAME=ME');
          } else {
            reply('NAMING REPLY RESULT=OK NAME=ME VALUE=${mine.dest}');
          }
          return;
        }
        reply('NAMING REPLY RESULT=KEY_NOT_FOUND NAME=$name');
        return;
      }
    }, onError: (_) {}, onDone: () => _clients.remove(socket));
  }

  // ── Datagram plane ────────────────────────────────────────────────────────

  void _onUdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udp!.receive();
    if (dg == null) return;
    final data = dg.data;
    final nl = data.indexOf(10);
    if (nl < 0) return;
    final header = utf8.decode(data.sublist(0, nl), allowMalformed: true);
    final payload = Uint8List.fromList(data.sublist(nl + 1));

    // "3.0 <sessionId> <destination> [KEY=VALUE ...]"
    final firstSpace = header.indexOf(' ');
    if (firstSpace < 0) return;
    final afterVersion = header.substring(firstSpace + 1);
    final secondSpace = afterVersion.indexOf(' ');
    if (secondSpace < 0) return;
    final sessionId = afterVersion.substring(0, secondSpace);
    final rest = afterVersion.substring(secondSpace + 1).trim();

    final session = _byId[sessionId];
    if (session == null) {
      droppedSends.add('<unknown session $sessionId>');
      return;
    }

    // A tolerant bridge parses trailing options; a strict one treats the whole
    // remainder as the destination. Either way the destination itself must be
    // clean — that is the invariant a lab is here to hold.
    final target = strictSendHeader ? rest : rest.split(' ').first;

    final to = _byDest[target];
    if (to == null) {
      // Exactly what i2pd does with an address it cannot resolve: nothing.
      // The client's UDP write already succeeded.
      droppedSends.add(target);
      return;
    }
    _forward(from: session, to: to, payload: payload);
  }

  void _forward({
    required _SamSession from,
    required _SamSession to,
    required Uint8List payload,
  }) {
    if (lossRate > 0 && _rng.nextDouble() < lossRate) {
      lostCount++;
      return;
    }
    // From SAM 3.2 the forwarded header carries the ports; before that it is
    // the bare destination. The receiving session's negotiated version decides.
    final head = to.version >= 3.2
        ? '${from.dest} FROM_PORT=0 TO_PORT=0\n'
        : '${from.dest}\n';
    final headBytes = utf8.encode(head);
    final frame = Uint8List(headBytes.length + payload.length)
      ..setRange(0, headBytes.length, headBytes)
      ..setRange(headBytes.length, headBytes.length + payload.length, payload);

    void send() {
      final sock = _udp;
      if (sock == null) return;
      sock.send(frame, InternetAddress.loopbackIPv4, to.forwardPort);
      deliveredCount++;
    }

    if (latency == Duration.zero) {
      send();
    } else {
      Timer(latency, send);
    }
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// A bare I2P destination is 516 base64 characters.
  static const _destLen = 516;
  static const _b64 =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-~';

  String _newPrivateKey() {
    final buf = StringBuffer();
    // 512 random + the "AAAA" a null certificate ends with, then private
    // material the destination is the prefix of.
    for (var i = 0; i < _destLen - 4; i++) {
      buf.write(_b64[_rng.nextInt(_b64.length)]);
    }
    buf.write('AAAA');
    for (var i = 0; i < 64; i++) {
      buf.write(_b64[_rng.nextInt(_b64.length)]);
    }
    return buf.toString();
  }

  static String? _strOpt(String line, String key) =>
      RegExp('$key=(\\S+)').firstMatch(line)?.group(1);

  static double? _numOpt(String line, String key) {
    final raw = _strOpt(line, key);
    return raw == null ? null : double.tryParse(raw);
  }
}

class _SamSession {
  final String id;
  final String dest;
  final String priv;
  final int forwardPort;
  final double version;
  _SamSession({
    required this.id,
    required this.dest,
    required this.priv,
    required this.forwardPort,
    required this.version,
  });
}
