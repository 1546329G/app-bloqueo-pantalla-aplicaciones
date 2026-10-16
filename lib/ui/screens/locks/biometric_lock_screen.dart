import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/bridges/native_bridge.dart';
import '../../widgets/lock_screen_shell.dart';

/// Color de confirmación (desbloqueo correcto).
const Color _kSuccess = Color(0xFF66BB6A);

/// `/lock/biometric`
///
/// Pantalla de bloqueo biométrico de la app [packageName].
///
///  - Al montarse dispara automáticamente el diálogo nativo de Android
///    (huella / rostro) con `local_auth`.
///  - Si el usuario cancela o el sensor falla, la pantalla queda con un
///    estado elegante y un botón "Intentar de nuevo".
///  - Acierto: vibración ligera + `NativeBridge.unlockCurrentApp()`, que
///    marca la sesión y retira el overlay.
///  - Los `PlatformException` del plugin (sensor bloqueado, sin huellas,
///    sin bloqueo de pantalla…) se traducen a mensajes claros.
class BiometricLockScreen extends StatefulWidget {
  const BiometricLockScreen({
    super.key,
    required this.packageName,
    this.appLabel = '',
  });

  final String packageName;
  final String appLabel;

  @override
  State<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends State<BiometricLockScreen> {
  final LocalAuthentication _auth = LocalAuthentication();

  bool _authenticating = false;
  bool _unlocked = false;
  bool _supported = true;
  String? _error;

  /// Sesión de bloqueo actual (ver [_onLockRequestChanged]).
  late int _sessionId;

  String get _label =>
      widget.appLabel.isEmpty ? widget.packageName : widget.appLabel;

  bool get _invalidRequest => widget.packageName.isEmpty;

  @override
  void initState() {
    super.initState();
    _sessionId =
        NativeBridge.instance.activeLockRequest.value?.sessionId ?? 0;
    NativeBridge.instance.activeLockRequest.addListener(_onLockRequestChanged);
    // El diálogo nativo necesita la Activity ya montada: primer frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_authenticate());
    });
  }

  @override
  void dispose() {
    NativeBridge.instance.activeLockRequest.removeListener(
      _onLockRequestChanged,
    );
    super.dispose();
  }

  /// Bloqueo nuevo (sesión distinta): se relanza el diálogo biométrico para
  /// la app recién bloqueada, aunque el motor siga montado.
  void _onLockRequestChanged() {
    if (!mounted) return;
    final LockScreenRequest? request =
        NativeBridge.instance.activeLockRequest.value;
    if (request == null || request.sessionId == _sessionId) return;
    _sessionId = request.sessionId;
    setState(() {
      _authenticating = false;
      _unlocked = false;
      _error = null;
    });
    unawaited(_authenticate());
  }

  // ------------------------------------------------------------------
  // Autenticación
  // ------------------------------------------------------------------

  Future<void> _authenticate() async {
    if (_authenticating || _unlocked || _invalidRequest) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });

    // App y sesión fijadas al empezar: si el bloqueo cambia mientras el
    // diálogo está abierto, el resultado se descarta y no se desbloquea otra
    // aplicación con una autenticación ya caducada.
    final String packageName = widget.packageName;
    final int session = _sessionId;
    bool authenticated = false;
    bool deviceSupported = true;
    String? errorMessage;
    try {
      final bool supported = await _auth.isDeviceSupported();
      if (!supported) {
        deviceSupported = false;
        errorMessage = 'Este dispositivo no tiene biometría disponible.';
      } else {
        authenticated = await _auth.authenticate(
          localizedReason: 'Desbloquea $_label',
        );
      }
    } on PlatformException catch (error) {
      deviceSupported = error.code != 'notAvailable';
      errorMessage = _describeError(error);
    } catch (_) {
      // Fallo distinto de PlatformException (p. ej. plugin sin registrar).
      errorMessage = 'No se pudo iniciar la autenticación biométrica.';
    }

    if (!mounted ||
        packageName != widget.packageName ||
        session != _sessionId) {
      return;
    }
    if (authenticated) {
      await _handleSuccess();
      return;
    }
    setState(() {
      _authenticating = false;
      _supported = deviceSupported;
      _error = errorMessage ??
          'Autenticación no completada. Pulsa "Intentar de nuevo".';
    });
  }

  Future<void> _handleSuccess() async {
    HapticFeedback.lightImpact();
    setState(() {
      _unlocked = true;
      _authenticating = false;
      _error = null;
    });
    final bool accepted =
        await NativeBridge.instance.unlockCurrentApp(widget.packageName);
    if (!mounted || accepted) return;
    setState(() {
      _unlocked = false;
      _error = 'No se pudo confirmar el desbloqueo. Inténtalo de nuevo.';
    });
  }

  Future<void> _exitToHome() async {
    final bool ok = await NativeBridge.instance.goToHome();
    if (!mounted || ok) return;
    setState(() => _error = 'No se pudo salir al Inicio del teléfono.');
  }

  /// Traduce los códigos de error de local_auth a mensajes claros en español.
  String _describeError(PlatformException error) {
    return switch (error.code) {
      'notAvailable' => 'La biometría no está disponible en este dispositivo.',
      'notEnrolled' => 'No hay huellas ni rostro registrados en el teléfono.',
      'lockedOut' =>
        'Sensor bloqueado por demasiados intentos. Espera unos segundos '
            'e inténtalo de nuevo.',
      'permanentlyLockedOut' =>
        'Biometría bloqueada. Desbloquea el teléfono con su PIN o patrón '
            'para reactivarla.',
      'passcodeNotSet' =>
        'Configura un bloqueo de pantalla en el teléfono para usar biometría.',
      _ => error.message ?? 'Error de biometría (${error.code}).',
    };
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LockScreenShell(
      title: _label,
      subtitle: _invalidRequest
          ? 'Bloqueo sin aplicación identificada'
          : 'Coloca tu huella o mira al sensor',
      message: _message,
      messageIsError: _error != null && !_unlocked,
      onExitToHome: _exitToHome,
      child: _invalidRequest ? _buildInvalidRequest() : _buildCenter(),
    );
  }

  String? get _message {
    if (_unlocked) return 'Desbloqueado. Abriendo $_label…';
    if (_error != null) return _error;
    if (_authenticating) return 'Esperando autenticación…';
    return 'Usa tu huella o tu rostro para desbloquear.';
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _unlocked
                ? _kSuccess.withValues(alpha: 0.16)
                : scheme.primaryContainer.withValues(alpha: 0.35),
          ),
          child: Icon(
            _unlocked ? Icons.lock_open : Icons.fingerprint,
            size: 68,
            color: _unlocked ? _kSuccess : scheme.primary,
          ),
        ),
        const SizedBox(height: 26),
        if (_unlocked)
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.check_circle, color: _kSuccess, size: 22),
              SizedBox(width: 8),
              Text('Identidad verificada'),
            ],
          )
        else if (_authenticating)
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 10),
              Text('Esperando autenticación…'),
            ],
          )
        else
          FilledButton.tonalIcon(
            onPressed: _authenticate,
            icon: Icon(_supported ? Icons.fingerprint : Icons.refresh),
            label: const Text('Intentar de nuevo'),
          ),
      ],
    );
  }
}
