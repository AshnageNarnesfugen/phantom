import 'package:flutter/widgets.dart';
import 'core/phantom_core.dart';
import 'ui/theme/phantom_theme.dart';

/// Provides [PhantomCore] and [ThemeController] to the widget tree.
///
/// [core] is null during startup and until the user completes onboarding.
/// Call [onAccountReady] after creating or restoring an account to set the core.
class CoreProvider extends InheritedWidget {
  final PhantomCore? core;
  final ThemeController themeCtrl;
  final Future<void> Function(PhantomCore core, String seedPhrase) onAccountReady;

  const CoreProvider({
    super.key,
    required this.core,
    required this.themeCtrl,
    required this.onAccountReady,
    required super.child,
  });

  static CoreProvider of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CoreProvider>()!;

  @override
  bool updateShouldNotify(CoreProvider old) =>
      core != old.core || themeCtrl != old.themeCtrl;
}
