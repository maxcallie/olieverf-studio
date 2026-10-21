import 'dart:typed_data';
import 'dart:ui' as ui;

import 'dart:ui';

import 'models.dart';

/// Builds the same geometry that the SVG exporter writes:
/// closed polygons are smoothed with quadratic curves through the mid-points
/// of their edges (fill + outline); lines are plain polylines; dots circles.
Path strokePath(BrushStroke s) {
  final p = s.points;
  final n = s.pointCount;
  final path = Path();
  if (s.kind == StrokeKind.dot) {
    if (n >= 1) {
      path.addOval(Rect.fromCircle(
          center: Offset(p[0], p[1]), radius: s.width / 2));
    }
    return path;
  }
  if (n < 2) return path;
  if (s.kind == StrokeKind.fill || s.kind == StrokeKind.outline) {
    path.moveTo((p[2 * (n - 1)] + p[0]) / 2, (p[2 * (n - 1) + 1] + p[1]) / 2);
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      path.quadraticBezierTo(
        p[2 * i],
        p[2 * i + 1],
        (p[2 * i] + p[2 * j]) / 2,
        (p[2 * i + 1] + p[2 * j + 1]) / 2,
      );
    }
    path.close();
  } else {
    path.moveTo(p[0], p[1]);
    for (var i = 1; i < n; i++) {
      path.lineTo(p[2 * i], p[2 * i + 1]);
    }
  }
  return path;
}

Color _color(int rgb, double opacity) {
  final a = (opacity.clamp(0.0, 1.0) * 255).round();
  return Color((a << 24) | (rgb & 0xFFFFFF));
}

void drawPaper(Canvas canvas, Painting painting) {
  canvas.drawRect(
    Rect.fromLTWH(0, 0, painting.width.toDouble(), painting.height.toDouble()),
    Paint()..color = _color(painting.paperColor, 1),
  );
}

/// Draws strokes [from, to) in painting coordinates.
void drawStrokes(Canvas canvas, Painting painting, int from, int to) {
  final fill = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.fill;
  final line = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final strokes = painting.strokes;
  for (var i = from; i < to && i < strokes.length; i++) {
    final s = strokes[i];
    if (s.kind == StrokeKind.dot) {
      if (s.pointCount < 1) continue;
      fill.color = _color(s.color, s.opacity);
      canvas.drawCircle(
          Offset(s.points[0], s.points[1]), s.width / 2, fill);
    } else if (s.kind == StrokeKind.fill) {
      fill.color = _color(s.color, s.opacity);
      canvas.drawPath(strokePath(s), fill);
    } else {
      line
        ..color = _color(s.color, s.opacity)
        ..strokeWidth = s.width;
      canvas.drawPath(strokePath(s), line);
    }
  }
}

/// Records the complete painting as a (vector) picture.
ui.Picture recordPainting(Painting painting, {double scale = 1}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  drawPaper(canvas, painting);
  drawStrokes(canvas, painting, 0, painting.strokes.length);
  return recorder.endRecording();
}

/// Renders the painting to PNG bytes with the long side at [longSide] px.
Future<Uint8List> renderPng(Painting painting, {int longSide = 4000}) async {
  final scale = longSide /
      (painting.width > painting.height ? painting.width : painting.height);
  final picture = recordPainting(painting, scale: scale);
  final image = await picture.toImage(
    (painting.width * scale).round(),
    (painting.height * scale).round(),
  );
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
