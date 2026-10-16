import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/bridges/native_bridge.dart';
import '../../../core/security/unlock_attempt_guard.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../widgets/lock_screen_shell.dart';

/// Color de confirmación (desbloqueo correcto).
const Color _kSuccess = Color(0xFF66BB6A);

/// `/lock/pin`
///
/// Pantalla de bloqueo por PIN numérico de la app indicada por [packageName].
///
///  - Teclado numérico propio (0-9, borrar) con validación automática a los
///    6 dígitos y botón "Desbloquear" a partir de 4.
///  - La verificación usa `LocalStorageService.verifyCredential(packageName,
///    pin)`: el PIN nunca se guarda ni compara en claro (salt + SHA-256 en el
///    Keystore del dispositivo).
///  - Acierto: vibración ligera + `NativeBridge.unlockCurrentApp()` (Kotlin
///    marca la sesión y retira el overlay).
///  - Fallo: vibración fuerte, sacudida, mensaje rojo y registro del intento.
///    A los 5 fallos consecutivos el teclado queda bloqueado 30 s con
///    contador regresivo.
///  - "Salir al Inicio" es la única salida sin desbloquear (el gesto Atrás
///    está bloqueado nativamente y por [LockScreenShell]).
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({
    super.key,
    required this.packageName,
    this.appLabel = '',
  });

  final String packageName;
  final String appLabel;

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen>
    with SingleTickerProviderStateMixin {
  static const int _minDigits = 4;
  static const int _maxDigits = 6;

  final UnlockAttemptGuard _guard = UnlockAttemptGuard();
  final List<String> _digits = <String>[];

  late final AnimationController _shakeController;

  /// Sesión de bloqueo actual (ver [_onLockRequestChanged]).
  late int _sessionId;

  bool _verifying = false;
  bool _unlocked = false;
  String? _error;

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
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
  }

  @override
  void dispose() {
    NativeBridge.instance.activeLockRequest.removeListener(
      _onLockRequestChanged,
    );
    _shakeController.dispose();
    _guard.dispose();
    super.dispose();
  }

  /// El motor de bloqueo es único y reutilizado: cuando Kotlin anuncia un
  /// bloqueo NUEVO (sesión distinta) la pantalla vuelve a su estado inicial,
  /// aunque sea la misma app que el bloqueo anterior. Los intentos fallidos
  /// y el bloqueo temporal NO se reinician (viven en [UnlockAttemptGuard]).
  void _onLockRequestChanged() {
    if (!mounted) return;
    final LockScreenRequest? request =
        NativeBridge.instance.activeLockRequest.value;
    if (request == null || request.sessionId == _sessionId) return;
    _sessionId = request.sessionId;
    setState(() {
      _digits.clear();
      _verifying = false;
      _unlocked = false;
      _error = null;
    });
  }

  // ------------------------------------------------------------------
  // Entrada del teclado
  // ------------------------------------------------------------------

  void _onDigit(String digit) {
    if (_busy || _invalidRequest || _digits.length >= _maxDigits) return;
    HapticFeedback.selectionClick();
    setState(() {
      _digits.add(digit);
      _error = null;
    });
    if (_digits.length == _maxDigits) {
      unawaited(_submit());
    }
  }

  void _onBackspace() {
    if (_busy || _digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits.removeLast());
  }

  // ------------------------------------------------------------------
  // Verificación
  // ------------------------------------------------------------------

  Future<void> _submit() async {
    if (_busy || _invalidRequest) return;
    final String pin = _digits.join();
    if (pin.length < _minDigits) {
      setState(
        () => _error = 'El PIN debe tener al menos $_minDigits dígitos.',
      );
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });

    // Se fija la app y la sesión al empezar: si el bloqueo cambia mientras
    // se verifica, el resultado se descarta (nunca se desbloquea otra app).
    final String packageName = widget.packageName;
    final int session = _sessionId;
    bool valid = false;
    try {
      valid = await LocalStorageService.instance.verifyCredential(
        packageName,
        pin,
      );
    } catch (_) {
      // Almacén de credenciales no disponible: se trata como fallo para no
      // desbloquear ante un error inesperado.
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
      _handleFailure();
    }
  }

  Future<void> _handleSuccess() async {
    HapticFeedback.lightImpact();
    _guard.registerSuccess();
    setState(() {
      _unlocked = true;
      _verifying = false;
      _error = null;
      _digits.clear();
    });
    final bool accepted =
        await NativeBridge.instance.unlockCurrentApp(widget.packageName);
    if (!mounted || accepted) return;
    // El servicio ya no tenía ese bloqueo activo: se permite reintentar sin
    // dejar la pantalla bloqueada.
    setState(() {
      _unlocked = false;
      _error = 'No se pudo confirmar el desbloqueo. Inténtalo de nuevo.';
    });
  }

  void _handleFailure() {
    HapticFeedback.heavyImpact();
    unawaited(
      NativeBridge.instance.reportFailedUnlockAttempt(widget.packageName),
    );
    final bool lockoutActivated = _guard.registerFailure();
    _shakeController.forward(from: 0);
    setState(() {
      _verifying = false;
      _digits.clear();
      _error = lockoutActivated
          ? 'Demasiados intentos fallidos.'
          : 'PIN incorrecto. Inténtalo de nuevo.';
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
              : 'Ingresa el PIN para desbloquear',
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_unlocked)
          const Icon(Icons.lock_open, size: 64, color: _kSuccess)
        else
          _buildDots(scheme),
        const SizedBox(height: 26),
        if (_unlocked)
          const SizedBox.shrink()
        else if (_guard.isLockedOut)
          _buildLockoutNotice(scheme)
        else
          _buildKeypad(scheme),
      ],
    );
  }

  Widget _buildDots(ColorScheme scheme) {
    final int slots = math.max(_minDigits, _digits.length);
    return AnimatedBuilder(
      animation: _shakeController,
      builder: (BuildContext context, Widget? child) {
        final double progress = _shakeController.value;
        final double dx =
            math.sin(progress * math.pi * 6) * 12 * (1 - progress);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(slots, (int index) {
          final bool filled = index < _digits.length;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.symmetric(horizontal: 7),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? scheme.primary : Colors.transparent,
              border: Border.all(
                color: filled ? scheme.primary : scheme.outlineVariant,
                width: 1.6,
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLockoutNotice(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: <Widget>[
          Icon(Icons.timer_outlined, size: 44, color: scheme.error),
          const SizedBox(height: 12),
          Text(
            '${_guard.remainingLockoutSeconds} s',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: scheme.error,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Teclado bloqueado temporalmente',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeypad(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _keyRow(<Widget>[_digitKey('1'), _digitKey('2'), _digitKey('3')]),
        _keyRow(<Widget>[_digitKey('4'), _digitKey('5'), _digitKey('6')]),
        _keyRow(<Widget>[_digitKey('7'), _digitKey('8'), _digitKey('9')]),
        _keyRow(<Widget>[
          const _KeySlot(),
          _digitKey('0'),
          _KeypadButton(
            onTap: _onBackspace,
            semanticLabel: 'Borrar',
            child: const Icon(Icons.backspace_outlined),
          ),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy || _digits.length < _minDigits ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            icon: _verifying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.lock_open_outlined),
            label: const Text('Desbloquear'),
          ),
        ),
      ],
    );
  }

  Widget _keyRow(List<Widget> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: keys,
    );
  }

  Widget _digitKey(String digit) {
    return _KeypadButton(
      onTap: _busy ? null : () => _onDigit(digit),
      semanticLabel: digit,
      child: Text(
        digit,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Hueco del teclado (esquina inferior izquierda).
class _KeySlot extends StatelessWidget {
  const _KeySlot();

  @override
  Widget build(BuildContext context) => const SizedBox(width: 86, height: 86);
}

/// Botón circular del teclado numérico.
class _KeypadButton extends StatelessWidget {
  const _KeypadButton({
    required this.child,
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget button = SizedBox(
      width: 76,
      height: 76,
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(5),
      child: semanticLabel == null
          ? button
          : Semantics(button: true, label: semanticLabel, child: button),
    );
  }
}
