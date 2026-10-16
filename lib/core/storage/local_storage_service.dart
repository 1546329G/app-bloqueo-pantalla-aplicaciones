import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridges/native_bridge.dart';
import '../models/locked_app_model.dart';

/// Servicio Singleton de almacenamiento local. Doble capa:
///
///  1. SharedPreferences (rápido, compartible con Kotlin):
///     Bajo la clave [lockMapPrefsKey] se guarda el mapa JSON acordado:
///       {"com.whatsapp": {"isLocked": true, "lockType": "PIN"}}
///     El plugin `shared_preferences` en Android escribe ese valor en el
///     archivo "FlutterSharedPreferences" con el prefijo `flutter.`. Kotlin
///     NO lee ese archivo directamente: para que el AccessibilityService
///     tenga el mapa en memoria lo antes posible, este servicio lo empuja a
///     Kotlin con `NativeBridge.syncLockedAppsWithNative()`. Así solo existe
///     una fuente de verdad (la de Dart) y Kotlin queda como simple lector
///     O(1) de su propio SharedPreferences ("app_locker_native").
///
///  2. FlutterSecureStorage (Keystore del dispositivo):
///     Los secretos (PIN/patrón) NUNCA se guardan en claro. Por cada app se
///     generan 16 bytes de salt aleatorio + SHA-256(salt::secreto). La
///     verificación usa comparación en tiempo constante.
class LocalStorageService {
  LocalStorageService._();

  static final LocalStorageService instance = LocalStorageService._();

  /// Clave del mapa JSON dentro de SharedPreferences.
  /// (En disco: `flutter.app_locker_map` en FlutterSharedPreferences.)
  static const String lockMapPrefsKey = 'app_locker_map';

  static const String _credentialSaltPrefix = 'app_locker_cred_salt::';
  static const String _credentialHashPrefix = 'app_locker_cred_hash::';

  SharedPreferences? _prefs;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(migrateWithBackup: true),
  );

  /// Cache en memoria: evita re-decodificar el JSON en cada acceso de la UI.
  final Map<String, LockedAppModel> _cache = <String, LockedAppModel>{};

  bool _initialized = false;

  bool get isInitialized => _initialized;

  // ------------------------------------------------------------------
  // Ciclo de vida
  // ------------------------------------------------------------------

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _loadCacheFromPrefs();
    _initialized = true;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'LocalStorageService.initialize() debe ejecutarse antes de usar el servicio.',
      );
    }
  }

  // ------------------------------------------------------------------
  // Lecturas (sincrónicas tras initialize(): rutas calientes de la UI)
  // ------------------------------------------------------------------

  /// Todas las apps con bloqueo activo y método válido.
  List<LockedAppModel> getConfiguredApps() =>
      List<LockedAppModel>.unmodifiable(
        _cache.values.where((LockedAppModel app) => app.isEffectiveLock),
      );

  LockedAppModel? getApp(String packageName) => _cache[packageName];

  bool isAppLocked(String packageName) =>
      _cache[packageName]?.isEffectiveLock ?? false;

  LockType getLockType(String packageName) =>
      _cache[packageName]?.lockType ?? LockType.none;

  int get blockedAppCount => getConfiguredApps().length;

  // ------------------------------------------------------------------
  // Mutaciones del mapa de bloqueo
  // ------------------------------------------------------------------

  /// Guarda (o actualiza) la configuración de una app y sincroniza con Kotlin.
  Future<void> setAppLock(
    LockedAppModel model, {
    bool syncWithNative = true,
  }) async {
    _ensureInitialized();
    if (model.packageName.isEmpty) return;
    _cache[model.packageName] = model;
    await _persist();
    if (syncWithNative) {
      await syncLockedApps();
    }
  }

  /// Elimina la configuración de una app (y, por defecto, su credencial).
  Future<void> removeAppLock(
    String packageName, {
    bool deleteCredential = true,
    bool syncWithNative = true,
  }) async {
    _ensureInitialized();
    _cache.remove(packageName);
    if (deleteCredential) {
      await deleteCredentialFor(packageName);
    }
    await _persist();
    if (syncWithNative) {
      await syncLockedApps();
    }
  }

  /// Borrado total (reset de fábrica): mapa + credenciales.
  Future<void> clearAll() async {
    _ensureInitialized();
    _cache.clear();
    await _prefs?.remove(lockMapPrefsKey);
    await _secureStorage.deleteAll();
    await syncLockedApps();
  }

  Future<void> _persist() async {
    final Map<String, dynamic> map = <String, dynamic>{
      for (final LockedAppModel app in _cache.values)
        app.packageName: app.toEntryJson(),
    };
    await _prefs?.setString(lockMapPrefsKey, jsonEncode(map));
  }

  void _loadCacheFromPrefs() {
    _cache.clear();
    final String? raw = _prefs?.getString(lockMapPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((Object? key, Object? value) {
        final String packageName = key.toString();
        if (packageName.isEmpty) return;
        _cache[packageName] = LockedAppModel.fromEntry(packageName, value);
      });
    } on FormatException {
      // JSON corrupto: se arranca con el mapa vacío en lugar de fallar.
      _cache.clear();
    }
  }

  // ------------------------------------------------------------------
  // Sincronización con Kotlin
  // ------------------------------------------------------------------

  /// Mapa con el shape acordado con Kotlin (solo entradas efectivamente
  /// bloqueadas): {"com.whatsapp": {"isLocked": true, "lockType": "PIN"}}
  Map<String, dynamic> exportForNative() => <String, dynamic>{
    for (final LockedAppModel app in _cache.values)
      if (app.isEffectiveLock)
        app.packageName: <String, dynamic>{
          'isLocked': true,
          'lockType': app.lockType.wireValue,
        },
  };

  /// Empuja el mapa completo a Kotlin (SharedPreferences nativo del
  /// AccessibilityService). Devuelve cuántas apps quedaron bloqueadas.
  Future<int> syncLockedApps() async {
    if (!_initialized) return 0;
    return NativeBridge.instance.syncLockedAppsWithNative(exportForNative());
  }

  // ------------------------------------------------------------------
  // Credenciales (PIN / patrón) — Keystore, hasheadas con salt
  // ------------------------------------------------------------------

  /// Guarda el secreto de una app: salt aleatorio de 128 bits + SHA-256.
  /// Cada app tiene su propia clave aunque el usuario repita el mismo PIN.
  Future<void> saveCredential(String packageName, String secret) async {
    if (packageName.isEmpty || secret.isEmpty) return;
    final String salt = _generateSalt();
    final String hash = _computeHash(salt, secret);
    await _secureStorage.write(
      key: '$_credentialSaltPrefix$packageName',
      value: salt,
    );
    await _secureStorage.write(
      key: '$_credentialHashPrefix$packageName',
      value: hash,
    );
  }

  /// Verifica el secreto introducido con comparación en tiempo constante.
  Future<bool> verifyCredential(String packageName, String inputSecret) async {
    if (packageName.isEmpty || inputSecret.isEmpty) return false;
    final String? salt = await _secureStorage.read(
      key: '$_credentialSaltPrefix$packageName',
    );
    final String? storedHash = await _secureStorage.read(
      key: '$_credentialHashPrefix$packageName',
    );
    if (salt == null || storedHash == null) return false;
    final String candidate = _computeHash(salt, inputSecret);
    return _constantTimeEquals(candidate, storedHash);
  }

  Future<bool> hasCredential(String packageName) async {
    if (packageName.isEmpty) return false;
    return _secureStorage.containsKey(
      key: '$_credentialHashPrefix$packageName',
    );
  }

  Future<void> deleteCredentialFor(String packageName) async {
    if (packageName.isEmpty) return;
    await _secureStorage.delete(key: '$_credentialSaltPrefix$packageName');
    await _secureStorage.delete(key: '$_credentialHashPrefix$packageName');
  }

  /// Serializa un patrón (índices de los 9 puntos, en orden de trazo) al
  /// String que se hashea. Ej.: [0, 3, 6, 7] -> "0-3-6-7".
  static String serializePattern(List<int> indexes) => indexes.join('-');

  Future<void> savePattern(String packageName, List<int> indexes) =>
      saveCredential(packageName, serializePattern(indexes));

  Future<bool> verifyPattern(String packageName, List<int> indexes) =>
      verifyCredential(packageName, serializePattern(indexes));

  // ------------------------------------------------------------------
  // Criptografía
  // ------------------------------------------------------------------

  static final Random _random = Random.secure();

  String _generateSalt() {
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes);
  }

  String _computeHash(String salt, String secret) =>
      sha256.convert(utf8.encode('$salt::$secret')).toString();

  /// Comparación en tiempo constante: no corta en el primer byte distinto,
  /// para no filtrar información por temporización.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
