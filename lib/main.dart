import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/bridges/native_bridge.dart';
import 'core/routes/app_routes.dart';
import 'core/storage/local_storage_service.dart';

/// Punto de entrada. Este `main()` se ejecuta en DOS isolates/engines:
///
///  1. Motor principal (`MainActivity`): UI de configuración. Ruta inicial
///     '/' y resolución de permisos.
///  2. Motor de bloqueo (`LockScreenActivity`, precalentado por Kotlin):
///     ruta inicial `/lock/standby`; NativeBridge detecta el bloqueo activo
///     y navega a `/lock/pin|pattern|biometric`.
///
/// `NativeBridge.isLockEngine` decide el modo tras inicializar los canales.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LocalStorageService.instance.initialize();
  await NativeBridge.instance.initialize();

  // GlobalKey del Navigator raíz: permite a NativeBridge navegar a las rutas
  // de bloqueo en cualquier momento, aunque el usuario esté en otra pantalla.
  NativeBridge.instance.attachRootNavigatorKey(AppRouter.rootNavigatorKey);

  final bool isLockEngine = NativeBridge.instance.isLockEngine;

  final GoRouter router = AppRouter.create(
    initialLocation: isLockEngine ? AppRoutes.lockStandby : AppRoutes.splash,
    resolveStartLocation: isLockEngine ? null : _resolveStartLocation,
  );

  if (!isLockEngine) {
    unawaited(_bootstrapMainEngine());
  }

  runApp(AppLockerApp(router: router, isLockOverlay: isLockEngine));

  // La navegación pendiente (si Kotlin empujó el bloqueo antes de que el
  // Navigator existiera) necesita el primer frame ya montado.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    NativeBridge.instance.flushPendingNavigation();
  });
  // Segundo intento: cubre el arranque en frío del motor de bloqueo.
  Timer(const Duration(milliseconds: 350), () {
    NativeBridge.instance.flushPendingNavigation();
  });
}

/// A dónde ir desde el splash, según el estado nativo real.
Future<String> _resolveStartLocation() async {
  final NativeStatus status = await NativeBridge.instance.getStatus();
  return status.hasCorePermissions ? AppRoutes.home : AppRoutes.permissions;
}

/// Tareas del motor principal que no deben retrasar el primer frame.
Future<void> _bootstrapMainEngine() async {
  // El mapa de bloqueo vive en Dart: Kotlin recibe la copia para su cache
  // O(1) del AccessibilityService.
  await LocalStorageService.instance.syncLockedApps();

  final NativeStatus status = await NativeBridge.instance.getStatus();
  if (status.hasCorePermissions) {
    unawaited(NativeBridge.instance.startKeepAliveService());
    unawaited(NativeBridge.instance.requestNotificationPermission());
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFF0B0F17),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
}

/// Raíz de la aplicación. El mismo widget sirve a la UI de configuración y a
/// la pantalla de bloqueo (que además es translúcida, definida en Android).
class AppLockerApp extends StatelessWidget {
  const AppLockerApp({
    super.key,
    required this.router,
    required this.isLockOverlay,
  });

  final GoRouter router;

  /// true cuando corre sobre el motor del motor de bloqueo.
  final bool isLockOverlay;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'App Locker',
      debugShowCheckedModeBanner: false,
      theme: buildAppLockerTheme(),
      darkTheme: buildAppLockerTheme(),
      themeMode: ThemeMode.dark,
      locale: const Locale('es'),
      supportedLocales: const <Locale>[Locale('es'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}

/// Tema oscuro Material 3 para una app de seguridad.
ThemeData buildAppLockerTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6C8CFF),
    brightness: Brightness.dark,
    surface: const Color(0xFF0B0F17),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
}
