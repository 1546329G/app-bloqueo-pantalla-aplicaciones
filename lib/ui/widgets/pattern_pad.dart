import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Área interactiva de patrón 3x3, reutilizable en toda la app.
///
/// Se usa tanto en la configuración por app (`/config-app`, donde el usuario
/// dibuja y repite su patrón) como en la pantalla de desbloqueo real
/// (`/lock/pattern`). El usuario dibuja arrastrando el dedo; el pad traduce
/// la posición del puntero al punto más cercano (índices 0..8 en orden
/// fila por fila) y notifica el trazo completo en [onCompleted]. Después de
/// cada trazo el pad se limpia solo, por lo que puede reutilizarse
/// inmediatamente para "dibuja" / "repite el patrón".
class PatternPad extends StatefulWidget {
  const PatternPad({
    super.key,
    this.size = 300,
    this.enabled = true,
    this.onCompleted,
    this.accentColor,
    this.holdLastStroke = false,
  });

  /// Lado del cuadrado del pad (se dibuja un cuadrado perfecto).
  final double size;

  /// false desactiva la interacción (p. ej. mientras se guarda o verifica).
  final bool enabled;

  /// Trazo terminado, con los índices tocados en orden de dibujo.
  /// Ej.: [0, 3, 6, 7].
  final ValueChanged<List<int>>? onCompleted;

  /// Color del trazo. Por defecto, el `primary` del tema.
  final Color? accentColor;

  /// true conserva pintado el último trazo (feedback verde/rojo de éxito o
  /// error en la pantalla de desbloqueo). El padre lo limpia recreando el
  /// widget con otra `Key`.
  final bool holdLastStroke;

  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  final List<int> _selected = <int>[];
  Offset? _cursor;
  bool _drawing = false;

  /// Lado real del pad ya aplicadas las restricciones del layout: se usa
  /// tanto para pintar como para el hit-testing, de modo que los centros de
  /// los puntos coincidan exactamente en cualquier tamaño de pantalla.
  double _side = 300;

  double get _cell => _side / 3;

  Offset _centerFor(int index) {
    final int row = index ~/ 3;
    final int col = index % 3;
    return Offset(_cell * (col + 0.5), _cell * (row + 0.5));
  }

  /// Índice del punto más cercano dentro del radio de acierto, o -1.
  int _indexFor(Offset local) {
    final double radius = _cell * 0.32;
    final double radiusSquared = radius * radius;
    int best = -1;
    double bestDistance = double.infinity;
    for (int i = 0; i < 9; i++) {
      final double distance = (local - _centerFor(i)).distanceSquared;
      if (distance <= radiusSquared && distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;
  }

  void _handlePointer(Offset local) {
    if (!widget.enabled) return;
    final int index = _indexFor(local);
    if (index < 0) {
      // Fuera de todo punto: solo se estira la línea guía hasta el dedo.
      if (_selected.isNotEmpty && _cursor != local) {
        setState(() => _cursor = local);
      }
      return;
    }
    if (_selected.contains(index)) return;
    setState(() {
      _selected.add(index);
      _cursor = _centerFor(index);
    });
    HapticFeedback.selectionClick();
  }

  void _finishStroke() {
    if (!widget.enabled) return;
    final List<int> stroke = List<int>.unmodifiable(_selected);
    setState(() {
      // Con holdLastStroke el trazo queda pintado (feedback de resultado);
      // el padre lo retira recreando el widget con otra Key.
      if (!widget.holdLastStroke) {
        _selected.clear();
      }
      _cursor = null;
      _drawing = false;
    });
    if (stroke.isNotEmpty) {
      widget.onCompleted?.call(stroke);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = widget.accentColor ?? scheme.primary;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side = constraints.maxWidth.isFinite
            ? math.min(widget.size, constraints.maxWidth)
            : widget.size;
        _side = side;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (PointerDownEvent event) {
            if (!widget.enabled) return;
            _drawing = true;
            _handlePointer(event.localPosition);
          },
          onPointerMove: (PointerMoveEvent event) {
            if (_drawing) _handlePointer(event.localPosition);
          },
          onPointerUp: (PointerUpEvent event) => _finishStroke(),
          onPointerCancel: (PointerCancelEvent event) => _finishStroke(),
          child: CustomPaint(
            size: Size.square(side),
            painter: _PatternPadPainter(
              selected: List<int>.unmodifiable(_selected),
              cursor: _cursor,
              accent: accent,
              idle: scheme.outlineVariant,
              background: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            ),
          ),
        );
      },
    );
  }
}

class _PatternPadPainter extends CustomPainter {
  const _PatternPadPainter({
    required this.selected,
    required this.cursor,
    required this.accent,
    required this.idle,
    required this.background,
  });

  final List<int> selected;
  final Offset? cursor;
  final Color accent;
  final Color idle;
  final Color background;

  Offset _centerFor(int index, double cell) {
    final int row = index ~/ 3;
    final int col = index % 3;
    return Offset(cell * (col + 0.5), cell * (row + 0.5));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double cell = size.shortestSide / 3;

    // Fondo redondeado del pad.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.shortestSide * 0.07),
      ),
      Paint()..color = background,
    );

    // Puntos base (siempre visibles).
    final Paint idlePaint = Paint()..color = idle;
    for (int i = 0; i < 9; i++) {
      canvas.drawCircle(_centerFor(i, cell), cell * 0.09, idlePaint);
    }

    if (selected.isEmpty) return;

    // Líneas del trazo.
    final Path path = Path()
      ..moveTo(_centerFor(selected.first, cell).dx, _centerFor(selected.first, cell).dy);
    for (final int index in selected.skip(1)) {
      final Offset center = _centerFor(index, cell);
      path.lineTo(center.dx, center.dy);
    }
    final Offset? cursorOffset = cursor;
    if (cursorOffset != null) {
      path.lineTo(cursorOffset.dx, cursorOffset.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Puntos activos por encima del trazo.
    final Paint activeHalo = Paint()..color = accent.withValues(alpha: 0.30);
    final Paint activeDot = Paint()..color = accent;
    for (final int index in selected) {
      final Offset center = _centerFor(index, cell);
      canvas.drawCircle(center, cell * 0.20, activeHalo);
      canvas.drawCircle(center, cell * 0.10, activeDot);
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPadPainter oldDelegate) =>
      !listEquals(oldDelegate.selected, selected) ||
      oldDelegate.cursor != cursor ||
      oldDelegate.accent != accent ||
      oldDelegate.idle != idle ||
      oldDelegate.background != background;
}
