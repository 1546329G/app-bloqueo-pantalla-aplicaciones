import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/bridges/native_bridge.dart';
import '../../core/models/locked_app_model.dart';
import '../../core/routes/app_routes.dart';
import '../../core/storage/local_storage_service.dart';
import '../widgets/pattern_pad.dart';

/// Color de confirmación usado en toda la pantalla.
const Color _kSuccess = Color(0xFF66BB6A);

/// `/config-app`
///
/// Configuración individual de UNA aplicación:
///   - Activar/desactivar su bloqueo.
///   - Elegir método con `SegmentedButton`: PIN numérico (4-6 dígitos),
///     patrón de puntos 3x3 o biometría (verificada antes con `local_auth`).
///   - "Guardar configuración" persiste la credencial hasheada en
///     [LocalStorageService] (Keystore), guarda el [LockedAppModel] y empuja
///     el mapa completo a Kotlin con `NativeBridge.syncLockedAppsWithNative()`
///     para que el AccessibilityService lo aplique al instante.
///
/// Mientras esta pantalla está abierta se activa `FLAG_SECURE` (nada de
/// capturas ni miniaturas en Recientes con el PIN o el patrón a la vista).
class AppConfigScreen extends StatefulWidget {
  const AppConfigScreen({super.key, required this.app});

  /// App a configurar (al menos trae `packageName` y `appName`).
  final LockedAppModel app;

  @override
  State<AppConfigScreen> createState() => _AppConfigScreenState();
}

class _AppConfigScreenState extends State<AppConfigScreen> {
  /// PIN válido: entre 4 y 6 dígitos.
  static final RegExp _pinRegExp = RegExp(r'^\d{4,6}$');

  final LocalStorageService _storage = LocalStorageService.instance;
  final LocalAuthentication _auth = LocalAuthentication();

  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _pinConfirmController = TextEditingController();

  late bool _locked;
  late LockType _type;

  List<int>? _firstPattern;
  List<int>? _confirmedPattern;

  bool _checkingBiometrics = true;
  bool _biometricAvailable = false;
  bool _hadCredential = false;
  bool _saving = false;
  Uint8List? _iconBytes;
  String? _error;

  String get _packageName => widget.app.packageName;

  String get _appLabel =>
      widget.app.appName.isEmpty ? widget.app.packageName : widget.app.appName;

  bool get _isValidApp => widget.app.packageName.isNotEmpty;

  @override
  void initState() {
    super.initState();

    final LockedAppModel? existing = _storage.getApp(_packageName);
    final LockType storedType = existing?.lockType ?? LockType.none;
    _locked = existing?.isEffectiveLock ?? widget.app.isEffectiveLock;
    _type = storedType.isActive ? storedType : LockType.pin;

    // Pantalla sensible: sin capturas de pantalla ni vista previa en Recientes.
    unawaited(NativeBridge.instance.setSecureScreen(true));

    if (_isValidApp) {
      unawaited(_loadExtras());
    } else {
      _checkingBiometrics = false;
    }
  }

  @override
  void dispose() {
    unawaited(NativeBridge.instance.setSecureScreen(false));
    _pinController.dispose();
    _pinConfirmController.dispose();
    super.dispose();
  }

  Future<void> _loadExtras() async {
    final Uint8List? icon =
        await NativeBridge.instance.getAppIcon(_packageName);
    final bool hasCredential = await _storage.hasCredential(_packageName);
    bool biometricAvailable = false;
    try {
      biometricAvailable = await _auth.isDeviceSupported();
    } catch (_) {
      // Plugin sin respuesta (dispositivo raro): se trata como no soportado.
      biometricAvailable = false;
    }
    if (!mounted) return;
    setState(() {
      _iconBytes = icon;
      _hadCredential = hasCredential;
      _biometricAvailable = biometricAvailable;
      _checkingBiometrics = false;
    });
  }

  // ------------------------------------------------------------------
  // Selección de método
  // ------------------------------------------------------------------

  void _onTypeSelected(Set<LockType> selection) {
    if (selection.isEmpty) return;
    final LockType next = selection.first;
    if (next == _type) return;
    if (next == LockType.biometric &&
        !_checkingBiometrics &&
        !_biometricAvailable) {
      _snack('Este dispositivo no tiene biometría disponible.');
      return;
    }
    setState(() {
      _type = next;
      _error = null;
    });
  }

  void _onPatternDrawn(List<int> indexes) {
    if (indexes.length < 4) {
      setState(() => _error = 'El patrón debe unir al menos 4 puntos.');
      return;
    }
    final List<int>? first = _firstPattern;
    if (first == null) {
      // Primer trazo: queda pendiente de confirmación.
      setState(() {
        _firstPattern = indexes;
        _confirmedPattern = null;
        _error = null;
      });
      return;
    }
    if (listEquals(first, indexes)) {
      setState(() {
        _confirmedPattern = indexes;
        _error = null;
      });
      return;
    }
    setState(() {
      _firstPattern = null;
      _confirmedPattern = null;
      _error = 'Los patrones no coinciden. Vuelve a dibujarlo.';
    });
  }

  void _resetPattern() {
    setState(() {
      _firstPattern = null;
      _confirmedPattern = null;
      _error = null;
    });
  }

  // ------------------------------------------------------------------
  // Guardado
  // ------------------------------------------------------------------

  Future<void> _syncNativeNow() =>
      NativeBridge.instance.syncLockedAppsWithNative(_storage.exportForNative());

  Future<void> _save() async {
    if (!_isValidApp) {
      setState(() => _error = 'No se recibió una aplicación válida.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    // Caso 1: bloqueo desactivado -> se retira la configuración y su clave.
    if (!_locked) {
      await _storage.removeAppLock(_packageName);
      await _syncNativeNow();
      if (!mounted) return;
      _finish('$_appLabel ya no está bloqueada.');
      return;
    }

    // Caso 2: bloqueo activo -> validar y guardar la credencial del método.
    if (_type == LockType.pin) {
      final String pin = _pinController.text;
      if (!_pinRegExp.hasMatch(pin)) {
        setState(() {
          _saving = false;
          _error = 'El PIN debe tener entre 4 y 6 dígitos.';
        });
        return;
      }
      if (pin != _pinConfirmController.text) {
        setState(() {
          _saving = false;
          _error = 'Los PIN no coinciden.';
        });
        return;
      }
      await _storage.saveCredential(_packageName, pin);
    } else if (_type == LockType.pattern) {
      final List<int>? pattern = _confirmedPattern;
      if (pattern == null || pattern.length < 4) {
        setState(() {
          _saving = false;
          _error = 'Dibuja y confirma tu patrón antes de guardar.';
        });
        return;
      }
      await _storage.savePattern(_packageName, pattern);
    } else if (_type == LockType.biometric) {
      if (_checkingBiometrics) {
        setState(() {
          _saving = false;
          _error = 'Espera a que termine la comprobación de biometría.';
        });
        return;
      }
      if (!_biometricAvailable) {
        setState(() {
          _saving = false;
          _error = 'Este dispositivo no tiene biometría disponible.';
        });
        return;
      }
    } else {
      setState(() {
        _saving = false;
        _error = 'Selecciona un método de bloqueo.';
      });
      return;
    }

    // Modelo actualizado -> SharedPreferences (fuente de verdad en Dart)…
    final LockedAppModel model = LockedAppModel(
      packageName: _packageName,
      appName: widget.app.appName,
      isLocked: true,
      lockType: _type,
    );
    await _storage.setAppLock(model, syncWithNative: false);
    // …y empujón inmediato a Kotlin para que el servicio lo sepa ya.
    await _syncNativeNow();

    if (!mounted) return;
    _finish('Configuración guardada para $_appLabel.');
  }

  /// Cierra la pantalla con confirmación (el SnackBar vive en el
  /// `ScaffoldMessenger` raíz, así que sobrevive al `pop`).
  void _finish(String message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.home);
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_isValidApp) {
      return Scaffold(
        appBar: AppBar(title: const Text('Configurar bloqueo')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 44,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 12),
                const Text(
                  'No se recibió una aplicación válida para configurar.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: () => context.go(AppRoutes.home),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver a la lista'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Configurar bloqueo')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            _buildHeader(scheme),
            const SizedBox(height: 18),
            _buildLockSwitch(scheme),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _buildMethodSection(scheme),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 14),
              _buildError(scheme),
            ],
            const SizedBox(height: 24),
            _buildSaveButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    final Uint8List? bytes = _iconBytes;
    return Row(
      children: <Widget>[
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: bytes != null
              ? Image.memory(
                  bytes,
                  width: 54,
                  height: 54,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  errorBuilder:
                      (BuildContext context, Object error, StackTrace? stack) =>
                          Icon(Icons.android, color: scheme.onSurfaceVariant),
                )
              : Icon(Icons.android, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _appLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _packageName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (_hadCredential && _locked) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.key_outlined,
                      size: 14,
                      color: _kSuccess,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Clave configurada · al guardar se reemplaza',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: _kSuccess,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLockSwitch(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: SwitchListTile(
        value: _locked,
        onChanged: (bool value) => setState(() {
          _locked = value;
          _error = null;
        }),
        secondary: Icon(
          _locked ? Icons.lock_outline : Icons.lock_open_outlined,
          color: _locked ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: const Text('Bloquear esta aplicación'),
        subtitle: Text(
          _locked
              ? 'Se pedirá ${_type.displayName.toLowerCase()} al abrirla'
              : 'Sin protección: se abrirá sin pedir clave',
        ),
      ),
    );
  }

  Widget _buildMethodSection(ColorScheme scheme) {
    if (!_locked) {
      return _section(
        scheme,
        key: const ValueKey<String>('methods-off'),
        child: Row(
          children: <Widget>[
            Icon(Icons.touch_app_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Activa el interruptor de arriba para elegir el método de '
                'bloqueo y crear la clave de esta app.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      key: const ValueKey<String>('methods-on'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Método de bloqueo',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        SegmentedButton<LockType>(
          showSelectedIcon: false,
          segments: const <ButtonSegment<LockType>>[
            ButtonSegment<LockType>(
              value: LockType.pin,
              label: Text('PIN'),
              icon: Icon(Icons.pin_outlined),
            ),
            ButtonSegment<LockType>(
              value: LockType.pattern,
              label: Text('Patrón'),
              icon: Icon(Icons.pattern_outlined),
            ),
            ButtonSegment<LockType>(
              value: LockType.biometric,
              label: Text('Biometría'),
              icon: Icon(Icons.fingerprint),
            ),
          ],
          selected: <LockType>{_type},
          onSelectionChanged: _onTypeSelected,
        ),
        const SizedBox(height: 16),
        switch (_type) {
          LockType.pin => _buildPinSection(scheme),
          LockType.pattern => _buildPatternSection(scheme),
          LockType.biometric => _buildBiometricSection(scheme),
          LockType.none => const SizedBox.shrink(),
        },
      ],
    );
  }

  Widget _buildPinSection(ColorScheme scheme) {
    return _section(
      scheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'PIN exclusivo para esta app (4 a 6 dígitos)',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: const InputDecoration(
              labelText: 'PIN',
              counterText: '',
              prefixIcon: Icon(Icons.pin_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinConfirmController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: const InputDecoration(
              labelText: 'Confirmar PIN',
              counterText: '',
              prefixIcon: Icon(Icons.check_circle_outline),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatternSection(ColorScheme scheme) {
    final List<int>? first = _firstPattern;
    final String hint;
    if (_confirmedPattern != null) {
      hint = 'Patrón confirmado. Guarda la configuración para aplicarlo.';
    } else if (first != null) {
      hint = 'Repite el patrón para confirmarlo.';
    } else {
      hint = 'Dibuja tu patrón uniendo al menos 4 puntos.';
    }

    return _section(
      scheme,
      child: Column(
        children: <Widget>[
          Text(
            hint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _confirmedPattern != null
                  ? _kSuccess
                  : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: PatternPad(size: 280, onCompleted: _onPatternDrawn),
          ),
          if (first != null) ...<Widget>[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _resetPattern,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reiniciar patrón'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBiometricSection(ColorScheme scheme) {
    if (_checkingBiometrics) {
      return _section(
        scheme,
        child: const Row(
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Comprobando la biometría del dispositivo…')),
          ],
        ),
      );
    }

    final bool available = _biometricAvailable;
    return _section(
      scheme,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            available ? Icons.verified_user : Icons.warning_amber_rounded,
            color: available ? _kSuccess : scheme.error,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              available
                  ? 'Biometría disponible. Al abrir esta app se pedirá tu '
                      'huella o rostro. No se guarda ninguna clave local.'
                  : 'Este dispositivo no tiene biometría configurada. '
                      'Elige PIN o Patrón.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error ?? '',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _saving ? null : _save,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : const Icon(Icons.save_outlined),
        label: const Text('Guardar configuración'),
      ),
    );
  }

  /// Contenedor de sección con el estilo común de tarjeta.
  Widget _section(ColorScheme scheme, {Key? key, required Widget child}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}
