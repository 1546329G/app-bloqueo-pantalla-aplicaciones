import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/locked_app_model.dart';

/// Fila reutilizable de la lista de aplicaciones (`/home`).
///
/// Muestra el icono real (cargado de forma progresiva desde Kotlin con
/// `NativeBridge.getAppIcon`), el nombre, el `packageName` y, cuando la app
/// está protegida, un chip con el tipo de bloqueo (PIN / Patrón / Biometría).
///
/// Toda la fila es táctil ([onTap]) y el [Switch] también es interactivo
/// ([onToggle]): activarlo lleva a la pantalla de configuración para elegir
/// el método y crear la clave; desactivarlo retira el bloqueo al instante.
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.appName,
    required this.packageName,
    this.iconBytes,
    this.isLocked = false,
    this.lockType = LockType.none,
    this.isBusy = false,
    this.onTap,
    this.onToggle,
  });

  final String appName;
  final String packageName;

  /// PNG del icono real devuelto por Kotlin (null mientras no ha cargado).
  final Uint8List? iconBytes;

  final bool isLocked;
  final LockType lockType;

  /// Deshabilita la interacción mientras se aplica un cambio.
  final bool isBusy;

  final VoidCallback? onTap;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String title = appName.isEmpty ? packageName : appName;
    final bool showChip = isLocked && lockType.isActive;

    return ListTile(
      onTap: isBusy ? null : onTap,
      enabled: !isBusy,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _AppIcon(appName: title, iconBytes: iconBytes),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 2),
          Text(
            packageName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (showChip) ...<Widget>[
            const SizedBox(height: 6),
            _LockTypeChip(lockType: lockType),
          ],
        ],
      ),
      trailing: isBusy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Switch(
              value: isLocked,
              onChanged: onToggle,
            ),
    );
  }
}

/// Icono real de la app con respaldo degradado mientras carga.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.appName, this.iconBytes});

  final String appName;
  final Uint8List? iconBytes;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Uint8List? bytes = iconBytes;

    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes != null
          ? Image.memory(
              bytes,
              width: 46,
              height: 46,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stackTrace) =>
                      _fallback(context, scheme),
            )
          : _fallback(context, scheme),
    );
  }

  Widget _fallback(BuildContext context, ColorScheme scheme) {
    final String letter =
        appName.isEmpty ? '?' : appName.substring(0, 1).toUpperCase();
    return Center(
      child: Text(
        letter,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Chip compacto con el método de bloqueo activo de la app.
class _LockTypeChip extends StatelessWidget {
  const _LockTypeChip({required this.lockType});

  final LockType lockType;

  IconData get _icon => switch (lockType) {
    LockType.pin => Icons.pin_outlined,
    LockType.pattern => Icons.pattern_outlined,
    LockType.biometric => Icons.fingerprint,
    LockType.none => Icons.lock_open_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(_icon, size: 13, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            lockType.displayName,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
