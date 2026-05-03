import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Full-screen line chart with a touch-tracking crosshair, opened
/// from `MetricTile.onExpand`. Reads a flat list of `(timestamp,
/// value)` samples — no charting dependency, just a CustomPainter.
class MetricChartScreen extends StatefulWidget {
  const MetricChartScreen({
    super.key,
    required this.title,
    required this.unit,
    required this.samples,
    this.yMax,
  });

  final String title;
  final String unit;
  final List<({DateTime t, double v})> samples;
  final double? yMax;

  @override
  State<MetricChartScreen> createState() => _MetricChartScreenState();
}

class _MetricChartScreenState extends State<MetricChartScreen> {
  Offset? _crosshair;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          widget.title.toUpperCase(),
          style: const TextStyle(
            letterSpacing: 1.6,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: AppColors.scaffoldBackground,
        foregroundColor: AppColors.textPrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summary(),
            const SizedBox(height: 12),
            Expanded(
              child: GestureDetector(
                onPanStart: (d) =>
                    setState(() => _crosshair = d.localPosition),
                onPanUpdate: (d) =>
                    setState(() => _crosshair = d.localPosition),
                onPanEnd: (_) => setState(() => _crosshair = null),
                onTapDown: (d) =>
                    setState(() => _crosshair = d.localPosition),
                onTapUp: (_) => setState(() => _crosshair = null),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    color: AppColors.surface,
                  ),
                  child: CustomPaint(
                    painter: _ChartPainter(
                      samples: widget.samples,
                      unit: widget.unit,
                      yMax: widget.yMax,
                      crosshair: _crosshair,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap and drag across the chart to read exact values.',
              style: const TextStyle(
                color: AppColors.textFaint,
                fontSize: 11,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary() {
    final s = widget.samples;
    if (s.isEmpty) {
      return const Text(
        'NO SAMPLES YET',
        style: TextStyle(
          color: AppColors.textMuted,
          letterSpacing: 1.4,
          fontFamily: AppColors.monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    final values = s.map((e) => e.v).toList();
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final avg = values.reduce((a, b) => a + b) / values.length;
    String fmt(double v) => v.toStringAsFixed(2);
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        _stat('MIN', '${fmt(min)} ${widget.unit}'),
        _stat('AVG', '${fmt(avg)} ${widget.unit}'),
        _stat('MAX', '${fmt(max)} ${widget.unit}'),
        _stat('SAMPLES', '${s.length}'),
        _stat(
          'WINDOW',
          '${s.last.t.difference(s.first.t).inSeconds}s',
        ),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: const TextStyle(
            color: AppColors.textFaint,
            fontSize: 10,
            letterSpacing: 1.3,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.samples,
    required this.unit,
    required this.yMax,
    required this.crosshair,
  });

  final List<({DateTime t, double v})> samples;
  final String unit;
  final double? yMax;
  final Offset? crosshair;

  static const _padL = 8.0;
  static const _padR = 8.0;
  static const _padT = 8.0;
  static const _padB = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final w = size.width - _padL - _padR;
    final h = size.height - _padT - _padB;
    if (w <= 0 || h <= 0) return;

    final values = samples.map((e) => e.v).toList();
    final maxObserved = values.reduce((a, b) => a > b ? a : b);
    final ceiling = (yMax ?? maxObserved).clamp(1e-9, double.infinity);
    final effective = ceiling < maxObserved ? maxObserved : ceiling;

    // Grid: 4 horizontal divisions.
    final gridPaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 0.5;
    for (var i = 0; i <= 4; i++) {
      final y = _padT + h * (i / 4);
      canvas.drawLine(Offset(_padL, y), Offset(_padL + w, y), gridPaint);
    }

    final dx = w / (samples.length - 1);
    Offset pointAt(int i) {
      final x = _padL + dx * i;
      final y = _padT + h - (samples[i].v / effective) * h;
      return Offset(x, y);
    }

    // Filled area below the line.
    final area = Path()..moveTo(_padL, _padT + h);
    for (var i = 0; i < samples.length; i++) {
      area.lineTo(pointAt(i).dx, pointAt(i).dy);
    }
    area
      ..lineTo(_padL + w, _padT + h)
      ..close();
    canvas.drawPath(
      area,
      Paint()..color = AppColors.textPrimary.withValues(alpha: 0.06),
    );

    // Stroke.
    final stroke = Paint()
      ..color = AppColors.textPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < samples.length; i++) {
      path.lineTo(pointAt(i).dx, pointAt(i).dy);
    }
    canvas.drawPath(path, stroke);

    // Axis labels (max + min on the right).
    _label(canvas, '${effective.toStringAsFixed(1)} $unit',
        Offset(_padL + w - 4, _padT + 2), AppColors.textFaint, end: true);
    _label(canvas, '0 $unit',
        Offset(_padL + w - 4, _padT + h - 14), AppColors.textFaint, end: true);

    // Crosshair: snap to nearest sample by x.
    final cross = crosshair;
    if (cross != null) {
      final relX = (cross.dx - _padL).clamp(0.0, w);
      final i = (relX / dx).round().clamp(0, samples.length - 1);
      final p = pointAt(i);
      final guide = Paint()
        ..color = AppColors.danger
        ..strokeWidth = 1;
      canvas.drawLine(Offset(p.dx, _padT), Offset(p.dx, _padT + h), guide);
      canvas.drawCircle(p, 3, Paint()..color = AppColors.danger);

      final s = samples[i];
      final ts = s.t.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      final label =
          '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}  '
          '${s.v.toStringAsFixed(2)} $unit';
      // Tooltip box.
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 11,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      const pad = 4.0;
      var boxX = p.dx + 8;
      if (boxX + tp.width + pad * 2 > _padL + w) {
        boxX = p.dx - tp.width - pad * 2 - 8;
      }
      final boxY = (_padT + 4).clamp(0.0, _padT + h - tp.height - pad * 2);
      final rect = Rect.fromLTWH(
        boxX,
        boxY,
        tp.width + pad * 2,
        tp.height + pad * 2,
      );
      canvas.drawRect(rect, Paint()..color = AppColors.scaffoldBackground);
      canvas.drawRect(
        rect,
        Paint()
          ..color = AppColors.danger
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      tp.paint(canvas, Offset(rect.left + pad, rect.top + pad));
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color,
      {bool end = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontFamily: AppColors.monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final origin = end ? Offset(at.dx - tp.width, at.dy) : at;
    tp.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.samples != samples ||
      old.crosshair != crosshair ||
      old.yMax != yMax ||
      old.unit != unit;
}
