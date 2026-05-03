import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Brutalist single-line sparkline. Pure CustomPainter — no chart
/// dependency. Caller passes a flat list of values (oldest → newest);
/// we fit the y-axis to `[0, max(yMax, observed)]` so the line never
/// flat-clips against the top edge.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.height = 40,
    this.color = AppColors.textPrimary,
    this.anomalous = false,
    this.yMax,
  });

  final List<double> values;
  final double height;
  final Color color;
  final bool anomalous;

  /// Optional ceiling. For percent-scaled metrics pass 100.
  final double? yMax;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          color: anomalous ? AppColors.danger : color,
          yMax: yMax,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.yMax,
  });

  final List<double> values;
  final Color color;
  final double? yMax;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      baseline,
    );
    if (values.length < 2) return;

    final maxObserved = values.fold<double>(0, (a, b) => b > a ? b : a);
    final ceiling = (yMax ?? maxObserved).clamp(1e-9, double.infinity);
    final effective = ceiling < maxObserved ? maxObserved : ceiling;

    final dx = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = size.height - (values[i] / effective) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color || old.yMax != yMax;
}
