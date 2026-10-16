import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../models/locked_app_model.dart';
import '../routes/app_routes.dart';

/// Estado de permisos y servicios reportado por Kotlin (`getStatus`).
@immutable
class NativeStatus {
  const NativeStatus({
    required this.accessibilityEnabled,
    required this.overlayGranted,
    required this.batteryOptimizationIgnored,
    required this.notificationsGranted,
    required this.keepAliveRunning,
    required this.lockEngineReady,
    required this.blockedCount,
  });

  /// Estado de partida mientras Kotlin responde.
  static const NativeStatus unknown = NativeStatus(
    accessibilityEnabled: false,
    overlayGranted: false,
    batteryOptimizationIgnored: false,
    notificationsGranted: false,
    keepAliveRunning: false,
    lockEngineReady: false,
    blockedCount: 0,
  );

  final bool accessibilityEnabled;
  final bool overlayGranted;

  /// true cuando la app está EXCLUIDA de la optimización de batería.
  final bool batteryOptimizationIgnored;
  final bool notificationsGranted;
  final bool keepAliveRunning;
  final bool lockEngineReady;
  final int blockedCount;

  /// Sin estos dos permisos el motor de bloqueo no puede funcionar.
  bool get hasCorePermissions => accessibilityEnabled && overlayGranted;

  /// Configuración recomendada completa (core + Doze + notificaciones).
  bool get isFullyConfigured =>
      hasCorePermissions &&
      batteryOptimizationIgnored &&
      notificationsGranted;

  factory NativeStatus.fromMap(Map<String, dynamic> map) => NativeStatus(
    accessibilityEnabled: map['accessibilityEnabled'] == true,
    overlayGranted: map['overlayGranted'] == true,
    batteryOptimizationIgnored: map['batteryOptimizationIgnored'] == true,
    notificationsGranted: map['notificationsGranted'] == true,
    keepAliveRunning: map['keepAliveRunning'] == true,
    lockEngineReady: map['lockEngineReady'] == true,
    blockedCount: map['blockedCount'] is int ? map['blockedCount'] as int : 0,
  );
}

/// App instalada devuelta por `getInstalledApps`.
@immutable
class InstalledAppInfo {
  const InstalledAppInfo({
    required this.packageName,
    required this.appName,
    required this.isSystem,
  });

  final String packageName;
  final String appName;
  final bool isSystem;

  factory InstalledAppInfo.fromMap(Map<String, dynamic> map) => InstalledAppInfo(
    packageName: map['packageName'] is String
        ? map['packageName'] as String
        : '',
    appName: map['appName'] is String ? map['appName'] as String : '',
    isSystem: map['isSystem'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is InstalledAppInfo && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;
}

/// Señal de bloqueo enviada por Kotlin: qué app entró en primer plano y con
/// qué método de bloqueo hay que protegerla.
@immutable
class LockScreenRequest {
  const LockScreenRequest({
    required this.packageName,
    required this.appLabel,
    required this.lockType,
    this.sessionId = 0,
  });

  final String packageName;
  final String appLabel;
  final LockType lockType;

  /// Identificador de la sesión de bloqueo: Kotlin lo incrementa en cada
  /// bloqueo nuevo. Cambia aunque la app y el método sean los mismos, lo que
  /// permite reiniciar las pantallas de bloqueo entre bloqueos consecutivos
  /// (el motor Flutter de bloqueo es único y reutilizado).
  final int sessionId;

  bool get isValid => packageName.isNotEmpty && lockType.isActive;

  LockedAppModel toLockedAppModel() => LockedAppModel(
    packageName: packageName,
    appName: appLabel,
    isLocked: true,
    lockType: lockType,
  );

  factory LockScreenRequest.fromMap(Map<String, dynamic> map) =>
      LockScreenRequest(
        packageName: map['packageName'] is String
            ? map['packageName'] as String
            : '',
        appLabel: map['appLabel'] is String ? map['appLabel'] as String : '',
        lockType: LockType.fromWire(map['lockType']),
        sessionId: map['sessionId'] is int ? map['sessionId'] as int : 0,
      );

  @override
  String toString() =>
      'LockScreenRequest($packageName, "$appLabel", ${lockType.wireValue}, '
      'session: $sessionId)';
}

/// Puente con la capa nativa de Android.
///
/// Canales (idénticos a los declarados en `AppLockerBridge.kt`):
///  - `com.example.app_locker/main`   : Dart -> Kotlin (permisos, apps,
///    sincronización del mapa de bloqueo, FLAG_SECURE…).
///  - `com.example.app_locker/lock`   : canal del motor de bloqueo
///    (`LockScreenActivity`). Kotlin empuja `onShowLockScreen` y
///    `onLockDismissed`; Dart responde con `submitUnlock`.
///  - `com.example.app_locker/events` : EventChannel (solo motor principal)
///    con eventos de estado: locksChanged, keepAliveState, lockShown…
///
/// `main()` se ejecuta en DOS isolates distintos (motor principal y motor de
/// bloqueo). `initialize()` detecta en cuál está sondeando `getActiveLock`:
/// el motor de bloqueo es el único que tiene un handler sobre el canal /lock.
class NativeBridge {
  NativeBridge._();

  static final NativeBridge instance = NativeBridge._();

  static const MethodChannel _mainChannel = MethodChannel(
    'com.example.app_locker/main',
  );

  static const MethodChannel _lockChannel = MethodChannel(
    'com.example.app_locker/lock',
  );

  static const EventChannel _eventsChannel = EventChannel(
    'com.example.app_locker/events',
  );

  final StreamController<Map<String, dynamic>> _eventsController =
      StreamController<Map<String, dynamic>>.broadcast();

  final ValueNotifier<NativeStatus> _status = ValueNotifier<NativeStatus>(
    NativeStatus.unknown,
  );

  final ValueNotifier<LockScreenRequest?> _activeLockRequest =
      ValueNotifier<LockScreenRequest?>(null);

  bool _initialized = false;
  bool _isLockEngine = false;
  GlobalKey<NavigatorState>? _rootNavigatorKey;
  String? _pendingLocation;

  /// Eventos crudos de Kotlin (para refrescar la UI al vuelo).
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  /// Último estado conocido de permisos/servicios.
  ValueNotifier<NativeStatus> get status => _status;

  /// Bloqueo activo (solo tiene valor en el motor de bloqueo).
  ValueNotifier<LockScreenRequest?> get activeLockRequest => _activeLockRequest;

  /// true si este isolate corre sobre el motor Flutter de `LockScreenActivity`.
  bool get isLockEngine => _isLockEngine;

  // ------------------------------------------------------------------
  // Ciclo de vida
  // ------------------------------------------------------------------

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _mainChannel.setMethodCallHandler(_handlePlatformCall);
    _lockChannel.setMethodCallHandler(_handlePlatformCall);

    _isLockEngine = await _probeLockEngine();

    if (_isLockEngine) {
      // Motor de bloqueo: recupera por PULL el estado pendiente. Cubre el
      // arranque en frío, cuando el push de Kotlin llega antes de que este
      // isolate registre sus handlers.
      final LockScreenRequest? active = await getActiveLock();
      if (active != null && active.isValid) {
        _dispatchLockRequest(active);
      }
    } else {
      // Motor principal: único con StreamHandler registrado para /events.
      _eventsChannel.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (Object error) {
          // Sin handler de eventos (no debería ocurrir en el motor principal).
        },
      );
      unawaited(getStatus());
    }
  }

  void dispose() {
    _mainChannel.setMethodCallHandler(null);
    _lockChannel.setMethodCallHandler(null);
    if (!_eventsController.isClosed) {
      _eventsController.close();
    }
  }

  /// El motor de bloqueo es el único que tiene handler sobre /lock: si
  /// `getActiveLock` no lanza MissingPluginException, estamos en él.
  Future<bool> _probeLockEngine() async {
    try {
      await _lockChannel.invokeMethod<Object?>('getActiveLock');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Permisos y estado del sistema
  // ------------------------------------------------------------------

  Future<NativeStatus> getStatus() async {
    final Object? raw = await _invokeMain<Object?>('getStatus');
    final NativeStatus parsed = raw is Map
        ? NativeStatus.fromMap(_asStringKeyedMap(raw))
        : NativeStatus.unknown;
    _status.value = parsed;
    return parsed;
  }

  Future<bool> checkAccessibilityPermission() async =>
      (await getStatus()).accessibilityEnabled;

  /// Abre Ajustes > Accesibilidad (el usuario debe activar el servicio).
  Future<void> requestAccessibilityPermission() =>
      _invokeMain<Object?>('openAccessibilitySettings');

  Future<bool> checkOverlayPermission() async =>
      (await getStatus()).overlayGranted;

  /// Abre Ajustes > Mostrar sobre otras apps.
  Future<void> requestOverlayPermission() =>
      _invokeMain<Object?>('openOverlaySettings');

  /// true cuando la app está EXCLUIDA de la optimización de batería.
  Future<bool> checkBatteryOptimization() async =>
      (await getStatus()).batteryOptimizationIgnored;

  /// Lanza el diálogo del sistema para excluir la app de Doze.
  Future<void> requestIgnoreBatteryOptimization() =>
      _invokeMain<Object?>('requestIgnoreBatteryOptimizations');

  /// Alternativa sin diálogo: lista de apps excluidas en Ajustes.
  Future<void> openBatteryOptimizationSettings() =>
      _invokeMain<Object?>('openBatteryOptimizationSettings');

  Future<void> requestNotificationPermission() =>
      _invokeMain<Object?>('requestNotificationPermission');

  /// Arranca (o rearma) el KeepAliveForegroundService.
  Future<bool> startKeepAliveService() async =>
      (await _invokeMain<bool>('startKeepAliveService')) ?? false;

  /// FLAG_SECURE en la Activity principal (pantallas sensibles de config).
  Future<void> setSecureScreen(bool enabled) =>
      _invokeMain<Object?>('setSecureScreen', <String, dynamic>{
        'enabled': enabled,
      });

  // ------------------------------------------------------------------
  // Apps instaladas e iconos
  // ------------------------------------------------------------------

  Future<List<InstalledAppInfo>> getInstalledApps() async {
    final Object? raw = await _invokeMain<Object?>('getInstalledApps');
    if (raw is! List) return const <InstalledAppInfo>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> map) => InstalledAppInfo.fromMap(
              _asStringKeyedMap(map),
            ))
        .where((InstalledAppInfo app) => app.packageName.isNotEmpty)
        .toList(growable: false);
  }

  Future<Uint8List?> getAppIcon(String packageName) async {
    final Object? raw = await _invokeMain<Object?>('getAppIcon', <String, dynamic>{
      'packageName': packageName,
    });
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  }

  Future<bool> openInstalledApp(String packageName) async =>
      (await _invokeMain<bool>('openInstalledApp', <String, dynamic>{
        'packageName': packageName,
      })) ??
      false;

  // ------------------------------------------------------------------
  // Sincronización del mapa de bloqueo con Kotlin
  // ------------------------------------------------------------------

  /// Empuja a Kotlin el mapa completo de apps bloqueadas.
  ///
  /// Acepta tanto el mapa simple {pkg: "PIN"} como el rico
  /// {pkg: {"isLocked": true, "lockType": "PIN"}} (ambos producidos por
  /// `LocalStorageService.exportForNative()`).
  ///
  /// Kotlin lo persiste en su SharedPreferences ("app_locker_native") y lo
  /// cachea en memoria: el AccessibilityService resuelve "¿está bloqueada?"
  /// en O(1) sin tocar disco ni JSON.
  Future<int> syncLockedAppsWithNative(Map<String, dynamic> lockedApps) async {
    final List<Map<String, dynamic>> apps = <Map<String, dynamic>>[];
    lockedApps.forEach((String packageName, dynamic value) {
      if (packageName.isEmpty) return;
      final LockedAppModel model = LockedAppModel.fromEntry(packageName, value);
      if (model.isEffectiveLock) {
        apps.add(model.toNativeJson());
      }
    });
    final Object? result = await _invokeMain<Object?>('syncLockedApps', <String, dynamic>{
      'apps': apps,
    });
    return result is int ? result : 0;
  }

  /// Configuración tal y como la tiene Kotlin ahora mismo (verificación).
  Future<List<LockedAppModel>> getLockedAppsFromNative() async {
    final Object? raw = await _invokeMain<Object?>('getLockedApps');
    if (raw is! List) return const <LockedAppModel>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> map) {
          final Map<String, dynamic> typed = _asStringKeyedMap(map);
          final Object? pkg = typed['packageName'];
          return LockedAppModel(
            packageName: pkg is String ? pkg : '',
            isLocked: true,
            lockType: LockType.fromWire(typed['lockType']),
          );
        })
        .where((LockedAppModel app) => app.packageName.isNotEmpty)
        .toList(growable: false);
  }

  // ------------------------------------------------------------------
  // Pantalla de bloqueo (motor dedicado)
  // ------------------------------------------------------------------

  /// Estado de bloqueo actual según Kotlin (o null si no hay ninguno).
  Future<LockScreenRequest?> getActiveLock() async {
    try {
      final Object? raw = await _lockChannel.invokeMethod<Object?>('getActiveLock');
      if (raw is Map) {
        final LockScreenRequest request = LockScreenRequest.fromMap(
          _asStringKeyedMap(raw),
        );
        return request.isValid ? request : null;
      }
    } on MissingPluginException {
      // Motor principal: sin handler de bloqueo.
    } on PlatformException {
      // Ignorado: sin bloqueo activo.
    }
    return null;
  }

  /// Avisa a Kotlin de que el usuario acertó la clave: se retira el overlay
  /// y la app queda usable hasta que cambie de app o se apague la pantalla
  /// (la sesión la gestiona `LockOverlayManager` en el lado nativo).
  Future<bool> unlockCurrentApp(String packageName) async {
    if (packageName.isEmpty) return false;
    try {
      final Object? accepted = await _lockChannel.invokeMethod<Object?>(
        'submitUnlock',
        <String, dynamic>{'packageName': packageName, 'success': true},
      );
      if (accepted == true) {
        _activeLockRequest.value = null;
        return true;
      }
    } on MissingPluginException {
      // Sin motor de bloqueo activo.
    } on PlatformException {
      // Ignorado.
    }
    return false;
  }

  /// Registrar un intento fallido (Kotlin lo publica en el EventChannel).
  Future<void> reportFailedUnlockAttempt(String packageName) async {
    if (packageName.isEmpty) return;
    try {
      await _lockChannel.invokeMethod<Object?>(
        'submitUnlock',
        <String, dynamic>{'packageName': packageName, 'success': false},
      );
    } on MissingPluginException {
      // Ignorado.
    } on PlatformException {
      // Ignorado.
    }
  }

  /// "Salir al Inicio" desde las pantallas de bloqueo: Kotlin abre el
  /// Launcher del teléfono y retira el overlay. Si el usuario vuelve a abrir
  /// la app protegida, se le pedirá la clave otra vez.
  Future<bool> goToHome() async {
    try {
      final Object? accepted = await _lockChannel.invokeMethod<Object?>(
        'goToHome',
      );
      return accepted == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Navegación forzosa desde Kotlin
  // ------------------------------------------------------------------

  /// Conecta el `GlobalKey<NavigatorState>` del router (definido en
  /// `AppRouter`) para que Kotlin pueda forzar la navegación a la ruta de
  /// bloqueo correspondiente en cualquier momento.
  void attachRootNavigatorKey(GlobalKey<NavigatorState> key) {
    _rootNavigatorKey = key;
    flushPendingNavigation();
  }

  /// Si llegó una señal de bloqueo antes de que existiera el Navigator,
  /// se quedó encolada: este método la ejecuta.
  void flushPendingNavigation() {
    final String? location = _pendingLocation;
    if (location == null) return;
    if (_navigate(location)) {
      _pendingLocation = null;
    }
  }

  bool _navigate(String location) {
    final BuildContext? context = _rootNavigatorKey?.currentContext;
    if (context == null) return false;
    GoRouter.of(context).go(location);
    return true;
  }

  // ------------------------------------------------------------------
  // Handlers de plataforma
  // ------------------------------------------------------------------

  Future<void> _handlePlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'onShowLockScreen':
        final LockScreenRequest request = LockScreenRequest.fromMap(
          _asStringKeyedMap(call.arguments),
        );
        if (request.isValid) {
          _dispatchLockRequest(request);
        }
        break;
      case 'onLockDismissed':
        final Map<String, dynamic> args = _asStringKeyedMap(call.arguments);
        final String packageName = _activeLockRequest.value?.packageName ?? '';
        _activeLockRequest.value = null;
        _emit(<String, dynamic>{
          'type': 'onLockDismissed',
          'packageName': packageName,
          'reason': args['reason'] is String ? args['reason'] as String : 'unknown',
        });
        break;
      default:
        // Método nativo desconocido: se ignora.
        break;
    }
  }

  void _dispatchLockRequest(LockScreenRequest request) {
    _activeLockRequest.value = request;
    _emit(<String, dynamic>{
      'type': 'lockShown',
      'packageName': request.packageName,
      'appLabel': request.appLabel,
      'lockType': request.lockType.wireValue,
    });
    if (_isLockEngine) {
      final String location = AppRoutes.lockLocationFor(
        lockType: request.lockType,
        packageName: request.packageName,
        appLabel: request.appLabel,
        sessionId: request.sessionId,
      );
      if (!_navigate(location)) {
        _pendingLocation = location;
      }
    }
  }

  void _handleNativeEvent(Object? raw) {
    final Map<String, dynamic> event = _asStringKeyedMap(raw);
    if (event.isEmpty) return;
    final Object? type = event['type'];
    if (type == 'connected' || type == 'keepAliveState' || type == 'locksChanged') {
      unawaited(getStatus());
    }
    _emit(event);
  }

  void _emit(Map<String, dynamic> event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  Future<T?> _invokeMain<T>(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    if (_isLockEngine) return null;
    try {
      return await _mainChannel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      _emit(<String, dynamic>{
        'type': 'bridgeError',
        'method': method,
        'message': error.message ?? error.code,
      });
      return null;
    }
  }

  /// Normaliza los mapas que llegan por los canales (`Map<dynamic, dynamic>`)
  /// a `Map<String, dynamic>` con tipado estricto.
  static Map<String, dynamic> _asStringKeyedMap(Object? raw) {
    if (raw is! Map) return <String, dynamic>{};
    final Map<String, dynamic> typed = <String, dynamic>{};
    raw.forEach((dynamic key, dynamic value) {
      typed[key.toString()] = value;
    });
    return typed;
  }
}
