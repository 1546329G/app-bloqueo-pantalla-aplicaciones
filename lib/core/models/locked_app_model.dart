/// Tipo de bloqueo asignado a una aplicación.
///
/// El `wireValue` de cada valor coincide EXACTAMENTE con las constantes que
/// usa Kotlin (`LockPrefs.LOCK_TYPE_PIN/PATTERN/BIOMETRIC`), de modo que el
/// String cruza el MethodChannel sin traducciones intermedias.
enum LockType {
  /// La app no tiene bloqueo activo.
  none,
  pin,
  pattern,
  biometric;

  /// Valor serializado que viaja a Kotlin y a SharedPreferences.
  String get wireValue => switch (this) {
    LockType.none => 'NONE',
    LockType.pin => 'PIN',
    LockType.pattern => 'PATTERN',
    LockType.biometric => 'BIOMETRIC',
  };

  /// Etiqueta legible para la UI.
  String get displayName => switch (this) {
    LockType.none => 'Sin bloqueo',
    LockType.pin => 'PIN numérico',
    LockType.pattern => 'Patrón de puntos',
    LockType.biometric => 'Biometría',
  };

  /// true cuando el tipo implica una clave utilizable.
  bool get isActive => this != LockType.none;

  /// Conversión segura String -> enum. Cualquier valor desconocido o null
  /// cae en [LockType.none] en lugar de lanzar una excepción.
  static LockType fromWire(Object? raw) {
    switch (raw?.toString().toUpperCase()) {
      case 'PIN':
        return LockType.pin;
      case 'PATTERN':
        return LockType.pattern;
      case 'BIOMETRIC':
        return LockType.biometric;
      default:
        return LockType.none;
    }
  }
}

/// Configuración de bloqueo de una aplicación concreta.
class LockedAppModel {
  const LockedAppModel({
    required this.packageName,
    this.appName = '',
    this.isLocked = false,
    this.lockType = LockType.none,
  });

  /// Nombre del paquete Android. Identificador único del modelo.
  final String packageName;

  /// Etiqueta visible (se guarda como copia local para poder listar la
  /// configuración sin depender del PackageManager).
  final String appName;

  final bool isLocked;
  final LockType lockType;

  /// true solo si el bloqueo está activo Y tiene un método válido.
  bool get isEffectiveLock => isLocked && lockType.isActive;

  /// JSON completo (se usa en argumentos de navegación y serialización).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'packageName': packageName,
    'appName': appName,
    'isLocked': isLocked,
    'lockType': lockType.wireValue,
  };

  /// JSON de entrada del mapa compartido con Kotlin/SharedPreferences
  /// (el packageName es la CLAVE del mapa, no un campo):
  /// {"com.whatsapp": {"isLocked": true, "lockType": "PIN"}}
  Map<String, dynamic> toEntryJson() => <String, dynamic>{
    'isLocked': isLocked,
    'lockType': lockType.wireValue,
    if (appName.isNotEmpty) 'appName': appName,
  };

  /// Payload plano que espera `syncLockedApps` en Kotlin.
  Map<String, dynamic> toNativeJson() => <String, dynamic>{
    'packageName': packageName,
    'isLocked': isEffectiveLock,
    'lockType': lockType.wireValue,
  };

  factory LockedAppModel.fromJson(Map<String, dynamic> json) {
    final Object? pkg = json['packageName'];
    final Object? name = json['appName'];
    return LockedAppModel(
      packageName: pkg is String ? pkg : '',
      appName: name is String ? name : '',
      isLocked: json['isLocked'] == true,
      lockType: LockType.fromWire(json['lockType']),
    );
  }

  /// Construye el modelo desde una entrada del mapa JSON compartido.
  /// Acepta tanto la forma rica ({"isLocked": true, "lockType": "PIN"}) como
  /// la forma simple de un único String de tipo de bloqueo ("PIN").
  factory LockedAppModel.fromEntry(String packageName, Object? rawEntry) {
    if (rawEntry is Map) {
      final Object? name = rawEntry['appName'];
      return LockedAppModel(
        packageName: packageName,
        appName: name is String ? name : '',
        isLocked: rawEntry['isLocked'] == true,
        lockType: LockType.fromWire(rawEntry['lockType']),
      );
    }
    if (rawEntry is String) {
      final LockType type = LockType.fromWire(rawEntry);
      return LockedAppModel(
        packageName: packageName,
        isLocked: type.isActive,
        lockType: type,
      );
    }
    if (rawEntry is bool) {
      return LockedAppModel(packageName: packageName, isLocked: rawEntry);
    }
    return LockedAppModel(packageName: packageName);
  }

  LockedAppModel copyWith({
    String? packageName,
    String? appName,
    bool? isLocked,
    LockType? lockType,
  }) {
    return LockedAppModel(
      packageName: packageName ?? this.packageName,
      appName: appName ?? this.appName,
      isLocked: isLocked ?? this.isLocked,
      lockType: lockType ?? this.lockType,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LockedAppModel &&
      other.packageName == packageName &&
      other.appName == appName &&
      other.isLocked == isLocked &&
      other.lockType == lockType;

  @override
  int get hashCode => Object.hash(packageName, appName, isLocked, lockType);

  @override
  String toString() =>
      'LockedAppModel($packageName, name: "$appName", locked: $isLocked, '
      'type: ${lockType.wireValue})';
}
