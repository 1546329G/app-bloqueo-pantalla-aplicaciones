import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/bridges/native_bridge.dart';
import '../../../core/security/unlock_attempt_guard.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../widgets/lock_screen_shell.dart';
import '../../widgets/pattern_pad.dart';

/// Colores del trazo según el resultado del intento.
const Color _kSuccess = Color(0xFF66BB6A);
const Color _kError = Color(0xFFEF5350);

/// `/lock/pattern`
///
/// Pantalla de bloqueo por patrón de puntos de la app [packageName].
///
///  - Reutiliza [PatternPad] (mismo widget que la configuración) con
///    `holdLastStroke: true`: el trazo queda pintado mientras se verifica.
///  - Al levantar el dedo se serializa la secuencia (0-1-2-5-8) y se valida
///    con `LocalStorageService.verifyPattern(packageName, indices)`.
///  - Acierto: trazo verde + vibración ligera + `unlockCurrentApp()`.
///  - Fallo: trazo rojo 800 ms + vibración fuerte + mensaje; a los 5 fallos
///    consecutivos, 30 s de bloqueo con contador regresivo.
class PatternLockScreen extends StatefulWidget {
  const PatternLockScreen({
    super.key,
    required this.packageName,
    this.appLabel = '',
  });

  final String packageName;
  final String appLabel;

  @override
  State<PatternLockScreen> createState() => _PatternLockScreenState();
}

class _PatternLockScreenState extends State<PatternLockScreen> {
  final UnlockAttemptGuard _guard = UnlockAttemptGuard();

  /// Key del pad: al cambiarla se recrea su estado (y con él se borra el
  /// último trazo retenido).
  Key _padKey = UniqueKey();

  Color? _accentColor;
  bool _verifying = false;
  bool _unlocked = false;
  String? _error;

  /// Sesión de bloqueo actual (ver [_onLockRequestChanged]).
  late int _sessionId;

  String get _label =>
      widget.appLabel.isEmpty ? widget.packageName : widget.appLabel;

  bool get _invalidRequest => widget.packageName.isEmpty;

  bool get _busy => _verifying || _unlocked || _guard.isLockedOut;

  @override
  void initState() {
    super.initState();
    _sessionId =
        NativeBridge.instance.activeLockRequest.value?.sessionId ?? 0;
    NativeBridge.instance.activeLockRequest.addListener(_onLockRequestChanged);
  }

  @override
  void dispose() {
    NativeBridge.instance.activeLockRequest.removeListener(
      _onLockRequestChanged,
    );
    _guard.dispose();
    super.dispose();
  }

  /// Bloqueo nuevo (sesión distinta): tablero limpio, aunque sea la misma
  /// app. Los fallos y el bloqueo temporal se conservan.
  void _onLockRequestChanged() {
    if (!mounted) return;
    final LockScreenRequest? request =
        NativeBridge.instance.activeLockRequest.value;
    if (request == null || request.sessionId == _sessionId) return;
    _sessionId = request.sessionId;
    setState(() {
      _padKey = UniqueKey();
      _accentColor = null;
      _verifying = false;
      _unlocked = false;
      _error = null;
    });
  }

  // ------------------------------------------------------------------
  // Verificación
  // ------------------------------------------------------------------

  Future<void> _onPatternCompleted(List<int> indexes) async {
    if (_busy || _invalidRequest) return;
    if (indexes.length < 4) {
      setState(() {
        _padKey = UniqueKey();
        _accentColor = null;
        _error = 'El patrón debe unir al menos 4 puntos.';
      });
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });

    // App y sesión fijadas al empezar: si el bloqueo cambia mientras se
    // verifica, el resultado se descarta.
    final String packageName = widget.packageName;
    final int session = _sessionId;
    bool valid = false;
    try {
      valid = await LocalStorageService.instance.verifyPattern(
        packageName,
        indexes,
      );
    } catch (_) {
      // Almacén de credenciales no disponible: se trata como fallo.
      valid = false;
    }
    if (!mounted ||
        packageName != widget.packageName ||
        session != _sessionId) {
      return;
    }
    if (valid) {
      await _handleSuccess();
    } else {
      await _handleFailure();
    }
  }

  Future<void> _handleSuccess() async {
    HapticFeedback.lightImpact();
    _guard.registerSuccess();
    setState(() {
      _accentColor = _kSuccess;
      _unlocked = true;
      _verifying = false;
      _error = null;
    });
    // El trazo verde se queda visible mientras el servicio retira el overlay.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    final bool accepted =
        await NativeBridge.instance.unlockCurrentApp(widget.packageName);
    if (!mounted || accepted) return;
    setState(() {
      _unlocked = false;
      _accentColor = null;
      _padKey = UniqueKey();
      _error = 'No se pudo confirmar el desbloqueo. Inténtalo de nuevo.';
    });
  }

  Future<void> _handleFailure() async {
    HapticFeedback.heavyImpact();
    unawaited(
      NativeBridge.instance.reportFailedUnlockAttempt(widget.packageName),
    );
    final bool lockoutActivated = _guard.registerFailure();
    setState(() {
      _accentColor = _kError;
      _verifying = false;
    });
    // Trazo rojo 800 ms antes de limpiar el tablero.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() {
      _accentColor = null;
      _padKey = UniqueKey();
      _error = lockoutActivated
          ? 'Demasiados intentos fallidos.'
          : 'Patrón incorrecto. Inténtalo de nuevo.';
    });
  }

  Future<void> _exitToHome() async {
    final bool ok = await NativeBridge.instance.goToHome();
    if (!mounted || ok) return;
    setState(() => _error = 'No se pudo salir al Inicio del teléfono.');
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _guard,
      builder: (BuildContext context, Widget? child) {
        return LockScreenShell(
          title: _label,
          subtitle: _invalidRequest
              ? 'Bloqueo sin aplicación identificada'
              : 'Dibuja tu patrón para desbloquear',
          message: _message,
          messageIsError: _error != null && !_unlocked,
          onExitToHome: _exitToHome,
          child: _invalidRequest ? _buildInvalidRequest() : _buildCenter(),
        );
      },
    );
  }

  String? get _message {
    if (_unlocked) return 'Desbloqueado. Abriendo $_label…';
    if (_guard.isLockedOut) {
      final int seconds = _guard.remainingLockoutSeconds;
      return 'Demasiados intentos. Espera $seconds s.';
    }
    return _error;
  }

  Widget _buildInvalidRequest() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Text(
        'El servicio no informó qué aplicación está bloqueada. '
        'Vuelve a abrir la app protegida o sal al Inicio.',
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildCenter() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        PatternPad(
          key: _padKey,
          size: 300,
          enabled: !_busy,
          holdLastStroke: true,
          accentColor: _accentColor,
          onCompleted: _onPatternCompleted,
        ),
        const SizedBox(height: 18),
        _buildStatus(),
      ],
    );
  }

  Widget _buildStatus() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_unlocked) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.check_circle, color: _kSuccess, size: 22),
          SizedBox(width: 8),
          Text('Patrón correcto'),
        ],
      );
    }
    if (_guard.isLockedOut) {
      return Column(
        children: <Widget>[
          Icon(Icons.timer_outlined, size: 36, color: scheme.error),
          const SizedBox(height: 6),
          Text(
            '${_guard.remainingLockoutSeconds} s',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: scheme.error,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }
    if (_verifying) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 10),
          Text('Verificando…'),
        ],
      );
    }
    return Text(
      'Conecta al menos 4 puntos',
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
