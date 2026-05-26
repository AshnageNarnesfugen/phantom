import 'dart:async';
import 'dart:io';
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
import 'core_provider.dart';
import 'ui/theme/phantom_theme.dart';
import 'ui/screens/screens.dart';

const _seedKey = 'phantom_seed_v1';

const _messagingChannel = MethodChannel('phantom/messaging');
const _diagnosticsChannel = MethodChannel('phantom/diagnostics');

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
Future<void> _writeCrashLog(Object error, StackTrace? stack) async {
  final ts = DateTime.now().toIso8601String();
  final body = '─── CRASH @ $ts ───\n$error\n$stack\n\n';

  // 1. Internal storage — read by [_dumpPreviousCrashIfAny] on next launch.
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/last_crash.txt');
    await f.writeAsString(body, mode: FileMode.append);
  } catch (e) {
    debugPrint('Failed to write crash log: $e');
  }

  // 2. Public Downloads via MediaStore — survives uninstall and is readable
  // from any file manager without root or adb. This is the diagnostic
  // channel the user can actually reach when a release-mode crash kills
  // the app before any UI loads.
  if (Platform.isAndroid) {
    try {
      await _diagnosticsChannel
          .invokeMethod<String>('writeCrashToDownloads', {'body': body});
    } catch (e) {
      debugPrint('Failed to write crash to downloads: $e');
    }
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

class _PhantomAppState extends State<PhantomApp> with WidgetsBindingObserver {
  ThemeController _themeCtrl = ThemeController();
  static const _secure = FlutterSecureStorage();

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
    final persisted = await ThemeController.load();
    persisted.addListener(() { if (mounted) setState(() {}); });
    if (mounted) setState(() => _themeCtrl = persisted);
    if (Platform.isAndroid) {
      // Waku starts FIRST — it's the primary messaging transport and is
      // lightweight enough to run permanently without draining the battery.
      try { await WakuDaemon.instance.ensure(); } catch (e) { debugPrint('Waku error: $e'); }
      // IPFS is now ON-DEMAND only (for file transfer). It will be started
      // by IpfsDaemon.instance.ensure() when sendFile() is called.
      // We skip auto-starting it here to save battery.
      try { await I2pdDaemon.instance.ensure(); } catch (e) { debugPrint('I2pd error: $e'); }
      try { await _prepareYggdrasilAndEnsure(); } catch (e) { debugPrint('Ygg error: $e'); }
    }
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
