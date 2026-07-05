import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'core/phantom_core.dart';
import 'core/ipfs_daemon.dart';
import 'core/i2pd_daemon.dart';
import 'core/waku_daemon.dart';
import 'core/yggdrasil_daemon.dart';
import 'core/yggdrasil_peers.dart';
import 'core/notification_service.dart';
import 'core/transport_debugger.dart';
import 'core/crypto/native/phantom_crypto_native.dart';
import 'core_provider.dart';
import 'ui/theme/phantom_theme.dart';
import 'ui/screens/screens.dart';

const _seedKey = 'phantom_seed_v1';

const _messagingChannel = MethodChannel('phantom/messaging');

void _startMessagingService() {
  if (!Platform.isAndroid) return;
  _messagingChannel.invokeMethod<void>('startService').catchError((_) {});
}

void _stopMessagingService() {
  if (!Platform.isAndroid) return;
  _messagingChannel.invokeMethod<void>('stopService').catchError((_) {});
}

/// Persists [error] + [stack] to `<app docs>/last_crash.txt` so we can read
/// the next time the app launches (via [_dumpPreviousCrashIfAny]). This is
/// the only viable diagnostic channel in release mode when the user can't
/// run `adb logcat` — Dart's normal stderr is invisible there.
///
/// We deliberately do NOT mirror to public Downloads anymore: a stack trace
/// can capture buffer contents, plaintext message bytes, ratchet state, or
/// other sensitive material in error messages, and the public Downloads
/// folder is readable by any installed app with READ_EXTERNAL_STORAGE.
/// App-private internal storage is sandboxed per app uid; that's the only
/// place a crash log belongs.
Future<void> _writeCrashLog(Object error, StackTrace? stack) async {
  final ts = DateTime.now().toIso8601String();
  final body = '─── CRASH @ $ts ───\n$error\n$stack\n\n';

  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/last_crash.txt');
    await f.writeAsString(body, mode: FileMode.append);
  } catch (e) {
    debugPrint('Failed to write crash log: $e');
  }
}

/// On startup, if [_writeCrashLog] wrote anything in a previous run, surface
/// it through debugPrint (and the in-app TransportDebugger) and then delete
/// the file so it doesn't keep replaying on subsequent launches.
Future<void> _dumpPreviousCrashIfAny() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/last_crash.txt');
    if (!await f.exists()) return;
    final body = await f.readAsString();
    debugPrint('═══ PREVIOUS-RUN CRASH LOG ═══\n$body═══ END CRASH LOG ═══');
    await f.delete();
  } catch (e) {
    debugPrint('Failed to dump previous crash: $e');
  }
}

void main() {
  // Global kill switch for every debugPrint in the app AND the framework.
  // In release these lines leak network locators and the social graph
  // (I2P dests, IPFS peer IDs, contact IDs, who talks to whom) to logcat,
  // which `adb logcat` and any READ_LOGS-holding app on a rooted device can
  // read. A metadata-minimising messenger must emit nothing there. Crashes
  // are still captured privately via _writeCrashLog + the in-app debugger.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  runZonedGuarded<void>(() {
    WidgetsFlutterBinding.ensureInitialized();

    // Any framework-level exception (assertion, build error, async surface)
    // funnels through here. Persist it and still pass to the default handler
    // so the console / red-screen behaviour you'd expect in debug remains.
    FlutterError.onError = (FlutterErrorDetails details) {
      _writeCrashLog(details.exception, details.stack);
      FlutterError.presentError(details);
    };

    // Native side errors that reach Dart (PlatformDispatcher) — covers
    // crashes from MethodChannel handlers and other engine-originated
    // exceptions that don't go through FlutterError.
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      _writeCrashLog(error, stack);
      return true;
    };

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    _dumpPreviousCrashIfAny();
    runApp(const PhantomApp());
  }, (error, stack) {
    // Any uncaught error in the zone — async errors with no awaiter, errors
    // thrown out of timer callbacks, etc. This is the catch-all that kept
    // release-mode crashes invisible before.
    _writeCrashLog(error, stack);
  });
}

class PhantomApp extends StatefulWidget {
  const PhantomApp({super.key});

  @override
  State<PhantomApp> createState() => _PhantomAppState();
}

/// Hardened storage options used for everything that derives the user's
/// identity (the seed phrase, theme prefs that live in secure storage, etc).
///
/// Android: the default flutter_secure_storage v10 scheme is already
/// hardware-backed — AES/GCM/NoPadding for the data, wrapped by an
/// Android-Keystore-resident RSA/ECB/OAEPwithSHA-256 key. We tried the
/// `biometric()` (Keystore-resident AES) variant for a marginally stronger
/// key custody, but switching cipher schemes triggers an on-read migration
/// of pre-existing entries that hangs / throws on some devices, which froze
/// the app on the loading screen. The default scheme's security is
/// effectively equivalent for our threat model, so we stay on it.
///
/// iOS: `first_unlock_this_device` — Keychain entries are unreadable until
/// the device has been unlocked at least once since boot, and they are
/// excluded from iCloud Keychain backup. Without this the seed could end up
/// in an iCloud backup, defeating the device-binding property.
const _kSecure = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
);

class _PhantomAppState extends State<PhantomApp> with WidgetsBindingObserver {
  ThemeController _themeCtrl = ThemeController();
  static const _secure = _kSecure;

  PhantomCore? _core;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeCtrl.addListener(() => setState(() {}));
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _core?.onAppPaused();
        _startMessagingService();
      case AppLifecycleState.resumed:
        _core?.onAppResumed();
        _stopMessagingService();
      default:
        break;
    }
  }

  Future<void> _init() async {
    NotificationService.initialize().catchError((_) {});
    // Theme load reads secure storage; a storage hiccup here must never block
    // the account-restore path below (it would otherwise leave the app stuck
    // on the loading spinner forever, since _init runs fire-and-forget).
    try {
      final persisted = await ThemeController.load();
      persisted.addListener(() { if (mounted) setState(() {}); });
      if (mounted) setState(() => _themeCtrl = persisted);
    } catch (e) {
      debugPrint('Theme load error (continuing with defaults): $e');
    }
    if (Platform.isAndroid) {
      // Start both Waku and IPFS regardless. Transport-level priority in
      // TransportManager.publish already prefers Waku for messaging and
      // demotes IPFS to a fallback / broadcast channel — but we still need
      // the IPFS daemon up because:
      //  - PresenceService publishes / subscribes heartbeats over IPFS
      //    pubsub (the green online dot, contact discovery on cold start).
      //  - It's the only sender-anonymous broadcast channel we have when
      //    Waku is unreachable (DNS blocked, peer count drops to 0, etc).
      //  - File transfers will rehydrate it on-demand anyway; keeping it
      //    warm just avoids a multi-second spin-up on the first send.
      //
      // Spawn them in parallel so Waku's enrtree DNS resolve doesn't gate
      // IPFS startup time.
      try {
        await Future.wait([
          WakuDaemon.instance.ensure().catchError((e) {
            debugPrint('Waku error: $e');
          }),
          IpfsDaemon.instance.ensure().catchError((e) {
            debugPrint('Ipfs error: $e');
          }),
        ]);
      } catch (e) {
        debugPrint('Daemon ensure error: $e');
      }

      try { await I2pdDaemon.instance.ensure(); } catch (e) { debugPrint('I2pd error: $e'); }
      try { await _prepareYggdrasilAndEnsure(); } catch (e) { debugPrint('Ygg error: $e'); }
    }
    // Load the Rust crypto core and verify it agrees with the Dart crypto on
    // this device (parity oracle). It does NOT yet handle any real message —
    // this is the runtime gate before a hot-path cutover. Result shows in the
    // in-app Transport Debugger as "NATIVE: …".
    unawaited(() async {
      final native = PhantomCryptoNative.tryLoad();
      if (native == null) {
        TransportDebugger.instance.log('NATIVE: Rust core not available on this build');
      } else {
        await native.runParityOracle();
      }
    }());
    await _tryRestoreAccount();
  }

  /// Reads Yggdrasil user preferences from secure storage, prepares the
  /// peer list (custom slots or freshly-fetched dynamic public list), hands
  /// the result to [YggdrasilDaemon.setPeerOverride], and finally invokes
  /// `ensure()`. When Yggdrasil is disabled in settings we just skip the
  /// daemon entirely so the VPN permission never gets requested.
  Future<void> _prepareYggdrasilAndEnsure() async {
    // Storage isn't initialized until the user has an account, so on the
    // first launch (pre-onboarding) we skip and fall back to the daemon's
    // built-in bootstrap peers. Settings will pick this up on the next
    // launch after onboarding writes the seed + initializes storage.
    bool storageReady = true;
    try { PhantomStorage.instance; } catch (_) { storageReady = false; }
    if (!storageReady) {
      await YggdrasilDaemon.instance.ensure();
      return;
    }

    final storage = PhantomStorage.instance;
    final enabled = await storage.getYggEnabled().catchError((_) => false);
    if (!enabled) {
      // User has Yggdrasil off — don't start the VPN service at all.
      return;
    }

    final useCustom = await storage.getYggUseCustomPeers().catchError((_) => false);
    List<String> peers;
    if (useCustom) {
      peers = (await storage.getYggCustomPeers().catchError((_) => <String>[]))
          .where((p) => p.trim().isNotEmpty)
          .toList();
      if (peers.isEmpty) {
        peers = YggdrasilPeerCatalog.fallback;
      }
    } else {
      peers = await _resolvePublicYggPeers(storage);
    }
    YggdrasilDaemon.instance.setPeerOverride(peers);
    await YggdrasilDaemon.instance.ensure();
  }

  /// Returns the peer list to inject into yggdrasil-go: cache when fresh,
  /// upstream fetch when stale, hard-coded fallback when both fail. Each
  /// call shuffles + trims down to a small subset so we rotate fairly.
  Future<List<String>> _resolvePublicYggPeers(PhantomStorage storage) async {
    final stale = await storage.isYggPeerCacheStale().catchError((_) => true);
    if (!stale) {
      final cached = await storage.getYggCachedPeers().catchError((_) => null);
      if (cached != null && cached.peers.isNotEmpty) {
        return YggdrasilPeerCatalog.pickRandom(
            cached.peers, YggdrasilPeerCatalog.defaultPickCount);
      }
    }
    final catalog = YggdrasilPeerCatalog();
    try {
      final fresh = await catalog.fetchUpstream();
      if (fresh.isNotEmpty) {
        await storage.setYggCachedPeers(fresh).catchError((_) {});
        return YggdrasilPeerCatalog.pickRandom(
            fresh, YggdrasilPeerCatalog.defaultPickCount);
      }
    } catch (e) {
      debugPrint('Yggdrasil upstream fetch error: $e');
    }
    final cached = await storage.getYggCachedPeers().catchError((_) => null);
    if (cached != null && cached.peers.isNotEmpty) {
      return YggdrasilPeerCatalog.pickRandom(
          cached.peers, YggdrasilPeerCatalog.defaultPickCount);
    }
    return YggdrasilPeerCatalog.fallback;
  }

  Future<void> _tryRestoreAccount() async {
    if (!mounted) return;
    try {
      final seed = await _secure.read(key: _seedKey);
      if (seed != null) {
        final dir  = await getApplicationDocumentsDirectory();
        final core = await PhantomCore.restoreAccount(
          seedPhrase:  seed,
          storagePath: dir.path,
        );
        if (mounted) setState(() => _core = core);
        NotificationService.requestPermission();
      }
    } catch (e) {
      debugPrint('Account restore error: $e');
      // Seed corrupted or storage error — fall through to onboarding.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onAccountReady(PhantomCore core, String seedPhrase) async {
    await _secure.write(key: _seedKey, value: seedPhrase);
    if (mounted) setState(() => _core = core);
    NotificationService.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    return CoreProvider(
      core:           _core,
      themeCtrl:      _themeCtrl,
      onAccountReady: _onAccountReady,
      child: PhantomTheme(
        tokens:    _themeCtrl.tokens,
        accent:    _themeCtrl.accent,
        isDark:    _themeCtrl.isDark,
        intensity: _themeCtrl.intensity,
        child: MaterialApp(
          title: 'Phantom',
          debugShowCheckedModeBanner: false,
          theme: _themeCtrl.materialTheme,
          home: _loading
              ? const _LoadingScreen()
              : _core != null
                  ? const ConversationsScreen()
                  : const OnboardingScreen(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeCtrl.dispose();
    _core?.dispose();
    super.dispose();
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    return Scaffold(
      backgroundColor: t.bgBase,
      body: Center(
        child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1),
      ),
    );
  }
}
