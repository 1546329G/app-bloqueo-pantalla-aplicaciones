import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../ui/screens/app_config_screen.dart';
import '../../ui/screens/home_screen.dart';
import '../../ui/screens/locks/biometric_lock_screen.dart';
import '../../ui/screens/locks/pattern_lock_screen.dart';
import '../../ui/screens/locks/pin_lock_screen.dart';
import '../../ui/screens/permissions_screen.dart';
import '../models/locked_app_model.dart';

/// Rutas de la aplicación.
abstract final class AppRoutes {
  /// Splash: decide a dónde ir según el estado de permisos.
  static const String splash = '/';
  static const String permissions = '/permissions';
  static const String home = '/home';
  static const String configApp = '/config-app';

  /// Ruta interna del motor de bloqueo: cubre la pantalla mientras Kotlin
  /// envía (o Dart recupera) el bloqueo activo. Evita el "flash" de UI.
  static const String lockStandby = '/lock/standby';

  static const String lockPin = '/lock/pin';
  static const String lockPattern = '/lock/pattern';
  static const String lockBiometric = '/lock/biometric';

  static const String splashName = 'splash';
  static const String permissionsName = 'permissions';
  static const String homeName = 'home';
  static const String configAppName = 'config-app';
  static const String lockStandbyName = 'lock-standby';
  static const String lockPinName = 'lock-pin';
  static const String lockPatternName = 'lock-pattern';
  static const String lockBiometricName = 'lock-biometric';

  /// Ruta de desbloqueo según el método asignado a la app.
  static String lockForType(LockType type) => switch (type) {
    LockType.pattern => lockPattern,
    LockType.biometric => lockBiometric,
    LockType.pin => lockPin,
    LockType.none => lockPin,
  };

  /// Location completa (con argumentos) hacia la que el NativeBridge
  /// redirige cuando Kotlin detecta una app bloqueada en primer plano.
  ///
  /// [sessionId] viaja como `?session=` y forma parte de la `Key` de cada
  /// pantalla de bloqueo: garantiza que un bloqueo nuevo arranque con estado
  /// limpio aunque la app y el método sean idénticos al bloqueo anterior.
  static String lockLocationFor({
    required LockType lockType,
    required String packageName,
    String appLabel = '',
    int sessionId = 0,
  }) {
    final String base = switch (lockType) {
      LockType.pattern => lockPattern,
      LockType.biometric => lockBiometric,
      LockType.pin => lockPin,
      LockType.none => lockPin,
    };
    return Uri(
      path: base,
      queryParameters: <String, String>{
        'packageName': packageName,
        if (appLabel.isNotEmpty) 'appLabel': appLabel,
        if (sessionId > 0) 'session': sessionId.toString(),
      },
    ).toString();
  }
}

/// Enrutador central. `rootNavigatorKey` es el punto de entrada que usa
/// [NativeBridge] para forzar la navegación a una pantalla de bloqueo en
/// cualquier momento, aunque el usuario esté en otra ruta.
abstract final class AppRouter {
  /// GlobalKey del Navigator raíz: la comparte el enrutador con NativeBridge.
  static final GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>();

  /// Construye el enrutador.
  ///
  /// [initialLocation] es '/' para el motor principal y
  /// [AppRoutes.lockStandby] para el motor de bloqueo (LockScreenActivity).
  ///
  /// [resolveStartLocation] resuelve a dónde mandar al usuario desde el
  /// splash (permisos vs home). Si es null, '/' se queda en el splash.
  static GoRouter create({
    String initialLocation = AppRoutes.splash,
    Future<String> Function()? resolveStartLocation,
  }) {
    return GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: initialLocation,
      debugLogDiagnostics: false,
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.splash,
          name: AppRoutes.splashName,
          builder: (BuildContext context, GoRouterState state) =>
              const _SplashScreen(),
          redirect: (BuildContext context, GoRouterState state) async {
            final Future<String> Function()? resolver = resolveStartLocation;
            if (resolver == null) return null;
            return resolver();
          },
        ),
        GoRoute(
          path: AppRoutes.permissions,
          name: AppRoutes.permissionsName,
          builder: (BuildContext context, GoRouterState state) =>
              const PermissionsScreen(),
        ),
        GoRoute(
          path: AppRoutes.home,
          name: AppRoutes.homeName,
          builder: (BuildContext context, GoRouterState state) =>
              const HomeScreen(),
        ),
        GoRoute(
          path: AppRoutes.configApp,
          name: AppRoutes.configAppName,
          builder: (BuildContext context, GoRouterState state) =>
              AppConfigScreen(app: _resolveConfigApp(state)),
        ),
        GoRoute(
          path: AppRoutes.lockStandby,
          name: AppRoutes.lockStandbyName,
          builder: (BuildContext context, GoRouterState state) =>
              const _LockStandbyScreen(),
        ),
        GoRoute(
          path: AppRoutes.lockPin,
          name: AppRoutes.lockPinName,
          builder: (BuildContext context, GoRouterState state) => PinLockScreen(
            key: ValueKey<String>('lock-pin-${_query(state, 'session')}'),
            packageName: _query(state, 'packageName'),
            appLabel: _query(state, 'appLabel'),
          ),
        ),
        GoRoute(
          path: AppRoutes.lockPattern,
          name: AppRoutes.lockPatternName,
          builder: (BuildContext context, GoRouterState state) =>
              PatternLockScreen(
                key: ValueKey<String>('lock-pattern-${_query(state, 'session')}'),
                packageName: _query(state, 'packageName'),
                appLabel: _query(state, 'appLabel'),
              ),
        ),
        GoRoute(
          path: AppRoutes.lockBiometric,
          name: AppRoutes.lockBiometricName,
          builder: (BuildContext context, GoRouterState state) =>
              BiometricLockScreen(
                key: ValueKey<String>(
                  'lock-biometric-${_query(state, 'session')}',
                ),
                packageName: _query(state, 'packageName'),
                appLabel: _query(state, 'appLabel'),
              ),
        ),
      ],
    );
  }

  static String _query(GoRouterState state, String key) =>
      state.uri.queryParameters[key] ?? '';

  /// La pantalla de configuración recibe la app como `extra` (LockedAppModel)
  /// o, alternativamente, por query params (packageName + appLabel).
  static LockedAppModel _resolveConfigApp(GoRouterState state) {
    final Object? extra = state.extra;
    if (extra is LockedAppModel) return extra;
    return LockedAppModel(
      packageName: state.uri.queryParameters['packageName'] ?? '',
      appName: state.uri.queryParameters['appLabel'] ??
          state.uri.queryParameters['appName'] ??
          '',
    );
  }
}

/// Splash mientras se resuelve el estado de permisos.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.shield_outlined, size: 72, color: scheme.primary),
            const SizedBox(height: 16),
            Text('App Locker', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 28),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cobertura opaca del motor de bloqueo (anti-flash): visible solo durante
/// los milisegundos que tarda en llegar la orden de bloqueo.
class _LockStandbyScreen extends StatelessWidget {
  const _LockStandbyScreen();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF0B1020),
      child: SizedBox.expand(),
    );
  }
}
