import 'package:flutter/material.dart';

/// Contenedor común de las tres pantallas de bloqueo en tiempo real
/// (`/lock/pin`, `/lock/pattern` y `/lock/biometric`).
///
/// Centraliza los requisitos de seguridad y estilo:
///  - [PopScope] con `canPop: false`: el botón/gesto "Atrás" de Android NUNCA
///    cierra la pantalla de bloqueo (solo avisa con un SnackBar).
///  - Fondo oscuro casi opaco sobre la app protegida (que no se vea su
///    contenido de fondo).
///  - Cabecera con la app bloqueada y el método de desbloqueo.
///  - Área de mensajes estable (no salta el layout al mostrar errores).
///  - Escape "Salir al Inicio": la única alternativa a desbloquear.
class LockScreenShell extends StatelessWidget {
  const LockScreenShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.message,
    this.messageIsError = false,
    this.onExitToHome,
  });

  /// Etiqueta de la app bloqueada (nombre visible).
  final String title;

  /// Texto informativo: qué método se está usando ("Ingresa el PIN para
  /// desbloquear", "Dibuja tu patrón", etc.).
  final String subtitle;

  /// Área interactiva central (teclado numérico, pad de patrón, biometría…).
  final Widget child;

  /// Mensaje de estado/error/contador regresivo bajo el área central.
  final String? message;

  /// true pinta el mensaje en color de error.
  final bool messageIsError;

  /// "Salir al Inicio": abre el Launcher y retira el bloqueo.
  final VoidCallback? onExitToHome;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
            content: Text('Desbloquea la aplicación para continuar.'),
          ),
        );
      },
      child: Scaffold(
        // Casi opaco: la app bloqueada queda oculta detrás del bloqueo.
        backgroundColor: const Color(0xF00B0F17),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 40,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      _buildHeader(context, scheme),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: child,
                      ),
                      _buildFooter(context, scheme),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme scheme) {
    final String letter = title.isEmpty
        ? '?'
        : title.substring(0, 1).toUpperCase();
    return Column(
      children: <Widget>[
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Text(
            letter,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context, ColorScheme scheme) {
    final String? currentMessage = message;
    return Column(
      children: <Widget>[
        SizedBox(
          height: 44,
          child: Center(
            child: Text(
              currentMessage ?? '',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: messageIsError ? scheme.error : scheme.onSurfaceVariant,
                fontWeight: currentMessage == null
                    ? FontWeight.w400
                    : FontWeight.w600,
              ),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onExitToHome,
          icon: const Icon(Icons.home_outlined),
          label: const Text('Salir al Inicio'),
        ),
      ],
    );
  }
}
