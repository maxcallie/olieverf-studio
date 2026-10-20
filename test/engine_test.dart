import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:olieverf_studio/painter/models.dart';
import 'package:olieverf_studio/painter/painter_engine.dart';
import 'package:olieverf_studio/painter/svg_export.dart';

SourceImage _testImage(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final inCircle = (x - w / 2) * (x - w / 2) + (y - h / 2) * (y - h / 2) <
          (w / 4) * (w / 4);
      rgba[o] = inCircle ? 220 : (x * 255 ~/ w);
      rgba[o + 1] = inCircle ? 60 : 120;
      rgba[o + 2] = inCircle ? 40 : (y * 255 ~/ h);
      rgba[o + 3] = 255;
    }
  }
  return SourceImage(w, h, rgba);
}

void main() {
  test('engine produces strokes inside a sane range', () {
    final p = paintPhoto(_testImage(200, 150), const PaintSettings());
    expect(p.width, 200);
    expect(p.height, 150);
    expect(p.strokes, isNotEmpty);
    for (final s in p.strokes) {
      expect(s.pointCount, greaterThanOrEqualTo(2));
      for (final v in s.points) {
        expect(v.isFinite, isTrue);
      }
    }
  });

  test('same seed gives the same painting', () {
    final a = paintPhoto(_testImage(120, 120), const PaintSettings(seed: 3));
    final b = paintPhoto(_testImage(120, 120), const PaintSettings(seed: 3));
    expect(a.strokes.length, b.strokes.length);
    expect(a.strokes.first.points, b.strokes.first.points);
  });

  test('svg export is well formed', () {
    final p = paintPhoto(_testImage(100, 80), const PaintSettings());
    final svg = paintingToSvg(p);
    expect(svg, startsWith('<?xml'));
    expect(svg, contains('viewBox="0 0 100 80"'));
    expect(svg.trim(), endsWith('</svg>'));
    expect('<path'.allMatches(svg).length, p.strokes.length);
  });
}
