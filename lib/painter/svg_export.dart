import 'models.dart';

/// Writes the painting as an SVG file.
///
/// Each brush stroke becomes one `<path>` (dots: `<circle>`); grouped per layer
/// (`laag-1` = coarsest brush) so you can toggle or recolour them in
/// Illustrator, Inkscape, Figma, etc. The geometry is identical to what the
/// app draws on screen (see `strokePath`).
String paintingToSvg(Painting p, {double outputScale = 2}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="0 0 ${p.width} ${p.height}" '
        'width="${(p.width * outputScale).round()}" '
        'height="${(p.height * outputScale).round()}">')
    ..writeln('<rect id="papier" width="${p.width}" height="${p.height}" '
        'fill="${_hex(p.paperColor)}"/>');

  var currentLayer = -1000;
  var open = false;
  for (final s in p.strokes) {
    if (s.layer != currentLayer) {
      if (open) b.writeln('</g>');
      open = true;
      currentLayer = s.layer;
      final name = currentLayer < 0
          ? 'onderschildering'
          : (currentLayer >= 99 ? 'accenten' : 'laag-${currentLayer + 1}');
      b.writeln('<g id="$name" '
          'stroke-linecap="round" stroke-linejoin="round">');
    }
    final pts = s.points;
    final n = s.pointCount;
    if (s.kind == StrokeKind.dot) {
      if (n < 1) continue;
      b.writeln('<circle cx="${_f(pts[0])}" cy="${_f(pts[1])}" '
          'r="${_f(s.width / 2)}" fill="${_hex(s.color)}" '
          'fill-opacity="${s.opacity.toStringAsFixed(2)}"/>');
      continue;
    }
    if (n < 2) continue;
    if (s.kind == StrokeKind.fill || s.kind == StrokeKind.outline) {
      b.write('<path d="M${_f((pts[2 * (n - 1)] + pts[0]) / 2)} '
          '${_f((pts[2 * (n - 1) + 1] + pts[1]) / 2)}');
      for (var i = 0; i < n; i++) {
        final j = (i + 1) % n;
        b.write('Q${_f(pts[2 * i])} ${_f(pts[2 * i + 1])} '
            '${_f((pts[2 * i] + pts[2 * j]) / 2)} '
            '${_f((pts[2 * i + 1] + pts[2 * j + 1]) / 2)}');
      }
      if (s.kind == StrokeKind.fill) {
        b.writeln('Z" fill="${_hex(s.color)}" '
            'fill-opacity="${s.opacity.toStringAsFixed(2)}"/>');
      } else {
        b.writeln('Z" fill="none" stroke="${_hex(s.color)}" '
            'stroke-width="${_f(s.width)}" '
            'stroke-opacity="${s.opacity.toStringAsFixed(2)}"/>');
      }
    } else {
      b.write('<path d="M${_f(pts[0])} ${_f(pts[1])}');
      for (var i = 1; i < n; i++) {
        b.write('L${_f(pts[2 * i])} ${_f(pts[2 * i + 1])}');
      }
      b.writeln('" fill="none" stroke="${_hex(s.color)}" '
          'stroke-width="${_f(s.width)}" '
          'stroke-opacity="${s.opacity.toStringAsFixed(2)}"/>');
    }
  }
  if (open) b.writeln('</g>');
  b.writeln('</svg>');
  return b.toString();
}

String _hex(int rgb) =>
    '#${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String _f(double v) {
  final s = v.toStringAsFixed(1);
  if (s == '-0.0') return '0';
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
