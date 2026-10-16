import 'dart:async';

import 'package:flutter/foundation.dart';

/// Control de intentos fallidos compartido por las tres pantallas de bloqueo
/// (PIN, patrón y biometría).
///
/// Comportamiento:
///  - Cuenta los intentos fallidos consecutivos.
///  - Al alcanzar [maxAttempts] activa un bloqueo temporal de [lockoutSeconds]
///    segundos con contador regresivo (notifica cada segundo a sus oyentes).
///  - Un acierto limpia todo el estado de inmediato.
///
/// IMPORTANTE: los contadores y la fecha de desbloqueo son ESTÁTICOS (estado
/// a nivel del motor Flutter de bloqueo, no de la pantalla). El motor es
/// único y reutilizado entre bloqueos, así que el bloqueo temporal sobrevive
/// a la recreación de la pantalla: cerrarla y volver a abrir la app protegida
/// no permite reiniciar el contador de intentos.
class UnlockAttemptGuard extends ChangeNotifier {
  UnlockAttemptGuard({this.maxAttempts = 5, this.lockoutSeconds = 30}) {
    if (isLockedOut) {
      _startTicker();
    }
  }

  /// Fallos consecutivos necesarios para activar el bloqueo temporal.
  final int maxAttempts;

  /// Duración del bloqueo temporal tras agotar los intentos.
  final int lockoutSeconds;

  // Estado compartido entre todas las instancias del motor de bloqueo.
  static int _sharedFailedAttempts = 0;
  static DateTime? _sharedLockedUntil;

  Timer? _ticker;

  int get failedAttempts => _sharedFailedAttempts;

  bool get isLockedOut => remainingLockoutSeconds > 0;

  /// Segundos restantes del bloqueo temporal (0 si no hay bloqueo activo).
  int get remainingLockoutSeconds {
    final DateTime? until = _sharedLockedUntil;
    if (until == null) return 0;
    final int milliseconds = until.difference(DateTime.now()).inMilliseconds;
    if (milliseconds <= 0) return 0;
    return (milliseconds / 1000).ceil();
  }

  /// Registra un intento fallido.
  ///
  /// Devuelve true si con este fallo se acaba de activar el bloqueo temporal.
  bool registerFailure() {
    if (isLockedOut) return true;
    _sharedFailedAttempts++;
    if (_sharedFailedAttempts >= maxAttempts) {
      _sharedFailedAttempts = 0;
      _sharedLockedUntil = DateTime.now().add(
        Duration(seconds: lockoutSeconds),
      );
      _startTicker();
      notifyListeners();
      return true;
    }
    notifyListeners();
    return false;
  }

  /// Intento correcto: limpia fallos y bloqueos pendientes.
  void registerSuccess() {
    _sharedFailedAttempts = 0;
    _sharedLockedUntil = null;
    _stopTicker();
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (remainingLockoutSeconds <= 0) {
        _sharedLockedUntil = null;
        _stopTicker();
      }
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}
