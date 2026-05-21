import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'core/phantom_core.dart';
import 'core/ipfs_daemon.dart';
import 'core/i2pd_daemon.dart';
import 'core/yggdrasil_daemon.dart';
import 'core/notification_service.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const PhantomApp());
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
      try { await IpfsDaemon.instance.ensure(); } catch (_) {}
      try { await I2pdDaemon.instance.ensure(); } catch (_) {}
      try { await YggdrasilDaemon.instance.ensure(); } catch (_) {}
    }
    await _tryRestoreAccount();
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
    } catch (_) {
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
