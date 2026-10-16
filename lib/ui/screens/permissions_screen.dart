import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/bridges/native_bridge.dart';
import '../../core/routes/app_routes.dart';

/// Color de "estado correcto" compartido por las tarjetas de permiso.
const Color _kSuccess = Color(0xFF66BB6A);

/// `/permissions`
///
/// Pantalla guiada tipo checklist para conceder los tres ajustes críticos de
/// Android 10+ que necesita el bloqueador:
///   1. Servicio de Accesibilidad (detecta la app en primer plano).
///   2. Mostrar sobre otras apps (dibuja la pantalla de bloqueo encima).
///   3. Ignorar optimización de batería (evita que Android mate el servicio).
///
/// Implementa [WidgetsBindingObserver]: cuando el usuario regresa de la
/// pantalla de Ajustes de Android (estado `resumed`) el estado se vuelve a
/// consultar automáticamente a Kotlin vía `NativeBridge.getStatus()`.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  NativeStatus _status = NativeStatus.unknown;
  bool _refreshing = true;

  /// Clave del permiso cuya pantalla de Ajustes se acaba de abrir.
  String? _activating;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// El usuario vuelve de Ajustes: se reconsulta el estado real.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh(showSpinner: false);
    }
  }

  Future<void> _refresh({bool showSpinner = true}) async {
    if (mounted && showSpinner && !_refreshing) {
      setState(() => _refreshing = true);
    }
    final NativeStatus status = await NativeBridge.instance.getStatus();
    if (!mounted) return;
    setState(() {
      _status = status;
      _refreshing = false;
    });
  }

  Future<void> _request(String key, Future<void> action) async {
    setState(() => _activating = key);
    await action;
    if (!mounted) return;
    setState(() => _activating = null);
    // La Activity sigue visible hasta que Android pinta Ajustes: un sondeo
    // silencioso mantiene el estado fresco sin bloquear la UI.
    await _refresh(showSpinner: false);
  }

  Future<void> _continueToApp() async {
    // Con los permisos base concedidos: armar el servicio persistente y
    // pedir notificaciones (Android 13+), necesarias para su notificación
    // en primer plano.
    await NativeBridge.instance.startKeepAliveService();
    await NativeBridge.instance.requestNotificationPermission();
    if (!mounted) return;
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool core = _status.hasCorePermissions;
    final bool canContinue = core && !_refreshing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Permisos necesarios'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Verificar de nuevo',
            onPressed: _refreshing ? null : () => _refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_refreshing)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: <Widget>[
                _buildIntro(scheme),
                const SizedBox(height: 16),
                _buildSummary(scheme, core),
                const SizedBox(height: 16),
                _PermissionCard(
                  icon: Icons.accessibility_new,
                  title: 'Servicio de Accesibilidad',
                  description:
                      'Detecta al instante qué aplicación acabas de abrir. '
                      'Sin este permiso, el bloqueo no puede funcionar.',
                  granted: _status.accessibilityEnabled,
                  busy: _activating == 'accessibility',
                  onActivate: () => _request(
                    'accessibility',
                    NativeBridge.instance.requestAccessibilityPermission(),
                  ),
                ),
                _PermissionCard(
                  icon: Icons.layers_outlined,
                  title: 'Mostrar sobre otras apps',
                  description:
                      'Permite dibujar la pantalla de bloqueo por encima de '
                      'la aplicación protegida. Es el "overlay" del sistema.',
                  granted: _status.overlayGranted,
                  busy: _activating == 'overlay',
                  onActivate: () => _request(
                    'overlay',
                    NativeBridge.instance.requestOverlayPermission(),
                  ),
                ),
                _PermissionCard(
                  icon: Icons.battery_saver_outlined,
                  title: 'Ignorar optimización de batería',
                  description:
                      'Evita que Android cierre el bloqueador cuando el '
                      'teléfono lleva un rato inactivo o en reposo (Doze).',
                  granted: _status.batteryOptimizationIgnored,
                  busy: _activating == 'battery',
                  recommended: true,
                  onActivate: () => _request(
                    'battery',
                    NativeBridge.instance.requestIgnoreBatteryOptimization(),
                  ),
                ),
                const SizedBox(height: 4),
                _buildNotes(scheme),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: canContinue ? _continueToApp : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Continuar a la App'),
                ),
                if (!core && !_refreshing) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'Activa la Accesibilidad y la Superposición para continuar.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ] else if (!_status.batteryOptimizationIgnored && !_refreshing) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'Puedes continuar, pero excluir la batería evita que el '
                    'bloqueo se detenga en segundo plano.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntro(ColorScheme scheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.shield_outlined, size: 40, color: scheme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Prepara tu bloqueador',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'El bloqueo en tiempo real necesita estos ajustes de Android. '
                'Al pulsar "Activar" se abrirán los Ajustes del sistema: '
                'concede el permiso y vuelve aquí. El estado se actualiza solo.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(ColorScheme scheme, bool core) {
    final bool full = _status.isFullyConfigured;
    final Color color = full
        ? _kSuccess
        : (core ? const Color(0xFFFFB74D) : scheme.error);
    final IconData icon = full
        ? Icons.verified_user
        : (core ? Icons.battery_alert_outlined : Icons.gpp_maybe);
    final String message = full
        ? 'Todo listo: protección completa activada'
        : (core
              ? 'Falta un ajuste recomendado: la exclusión de batería'
              : 'Faltan permisos obligatorios: Accesibilidad y Superposición');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_status.keepAliveRunning)
            const Tooltip(
              message: 'Servicio persistente en ejecución',
              child: Icon(Icons.bolt, color: _kSuccess, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _buildNotes(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'En Android 13 o superior, al continuar se pedirá permiso de '
              'notificaciones: es el aviso del servicio en primer plano que '
              'mantiene el bloqueo siempre activo. Todo funciona 100% local.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta de un permiso: estado en tiempo real + botón "Activar".
class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
    required this.onActivate,
    this.busy = false,
    this.recommended = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool granted;
  final VoidCallback onActivate;
  final bool busy;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: granted
              ? _kSuccess.withValues(alpha: 0.55)
              : scheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 22,
            backgroundColor: granted
                ? _kSuccess.withValues(alpha: 0.16)
                : scheme.surfaceContainerHighest,
            child: Icon(
              icon,
              color: granted ? _kSuccess : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (recommended && !granted) ...<Widget>[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Recomendado',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onTertiaryContainer),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _buildAction(scheme),
        ],
      ),
    );
  }

  Widget _buildAction(ColorScheme scheme) {
    if (granted) {
      return const Tooltip(
        message: 'Concedido',
        child: Icon(Icons.check_circle, color: _kSuccess, size: 28),
      );
    }
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(6),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    return FilledButton.tonal(
      onPressed: onActivate,
      child: const Text('Activar'),
    );
  }
}
