import 'package:flutter/material.dart';

/// Draws the waveform with detected speech behind it.
///
/// A painter rather than a few thousand widgets: the buckets as individual
/// views would cost more in layout than the analysis pass did.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({
    required this.pairs,
    required this.trace,
    required this.speech,
    this.speechSpans = const [],
    this.duration = Duration.zero,
  });

  /// Min/max per bucket, in `-1...1`, as the engine downsampled them.
  final List<(double, double)> pairs;

  final Color trace;
  final Color speech;

  /// Where speech was detected, in seconds. Empty until silence detection has
  /// run, in which case nothing is shaded.
  final List<(double start, double end)> speechSpans;

  /// The recording's length, for placing the spans.
  final Duration duration;

  @override
  void paint(Canvas canvas, Size size) {
    if (pairs.isEmpty || size.width <= 0) return;
    final midline = size.height / 2;

    // Behind the trace, so quiet stretches read as gaps rather than as a
    // block at one end. The first version shaded `fraction * width` from the
    // left, which looked like a finding — "the first 71% is speech" — and was
    // not one.
    final seconds = duration.inMicroseconds / 1e6;
    if (seconds > 0) {
      final paint = Paint()..color = speech;
      for (final (start, end) in speechSpans) {
        final x0 = (start / seconds).clamp(0.0, 1.0) * size.width;
        final x1 = (end / seconds).clamp(0.0, 1.0) * size.width;
        canvas.drawRect(
          Rect.fromLTWH(x0, 0, (x1 - x0) < 1 ? 1 : x1 - x0, size.height),
          paint,
        );
      }
    }

    final step = size.width / pairs.length;
    final paint = Paint()
      ..color = trace
      ..strokeWidth = step < 0.6 ? 0.6 : step
      ..strokeCap = StrokeCap.butt;

    for (var index = 0; index < pairs.length; index += 1) {
      final (low, high) = pairs[index];
      final x = index * step;
      final top = midline - high.clamp(-1.0, 1.0) * midline;
      final bottom = midline - low.clamp(-1.0, 1.0) * midline;
      canvas.drawLine(
        Offset(x, top),
        // Always at least a hairline, so silence reads as a flat line rather
        // than as a gap in the drawing.
        Offset(x, bottom < top + 0.5 ? top + 0.5 : bottom),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.pairs != pairs ||
      old.trace != trace ||
      old.speech != speech ||
      old.speechSpans != speechSpans ||
      old.duration != duration;
}
