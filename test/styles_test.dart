import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:olieverf_studio/painter/models.dart';
import 'package:olieverf_studio/painter/painter_engine.dart';
import 'package:olieverf_studio/painter/svg_export.dart';

SourceImage _load(String path, int maxSide) {
  var im = img.decodeImage(File(path).readAsBytesSync())!;
  if (im.width > maxSide || im.height > maxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: maxSide)
        : img.copyResize(im, height: maxSide);
  }
  final rgba = Uint8List(im.width * im.height * 4);
  var o = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      rgba[o++] = p.r.toInt();
      rgba[o++] = p.g.toInt();
      rgba[o++] = p.b.toInt();
      rgba[o++] = 255;
    }
  }
  return SourceImage(im.width, im.height, rgba);
}

void main() {
  final photo = _load('ci/test_photo.jpg', 160);

  for (final style in PaintStyle.values) {
    for (final mode in ColorMode.values) {
      test('${style.name} / ${mode.name}', () {
        final p = paintPhoto(
          photo,
          PaintSettings(
              style: style, colorMode: mode, paperColor: style.spec.paper),
        );
        expect(p.strokes, isNotEmpty);
        for (final s in p.strokes) {
          expect(s.pointCount,
              greaterThanOrEqualTo(s.kind == StrokeKind.dot ? 1 : 2));
          for (final v in s.points) {
            expect(v.isFinite, isTrue);
          }
          expect(s.width.isFinite, isTrue);
        }
        final svg = paintingToSvg(p);
        expect(svg.trim(), endsWith('</svg>'));
      });
    }
  }

  test('dark paper flips pencil to light ink', () {
    final p = paintPhoto(
        photo,
        const PaintSettings(
            style: PaintStyle.potlood, paperColor: 0x23201C));
    expect(p.strokes.first.color, greaterThan(0xC00000));
  });

  // Writes one SVG per style (+ some colour modes) when GALLERY_OUT is set,
  // so CI can show what the real Dart engine produces.
  final out = Platform.environment['GALLERY_OUT'];
  test('gallery', () {
    final big = _load('ci/test_photo.jpg', 500);
    Directory(out!).createSync(recursive: true);
    final combos = <(PaintStyle, ColorMode)>[
      for (final s in PaintStyle.values) (s, ColorMode.kleur),
      (PaintStyle.olieverf, ColorMode.zwartwit),
      (PaintStyle.olieverf, ColorMode.sepia),
      (PaintStyle.olieverf, ColorMode.cyanotypie),
      (PaintStyle.olieverf, ColorMode.palet),
      (PaintStyle.potlood, ColorMode.zwartwit),
      (PaintStyle.pen, ColorMode.sepia),
    ];
    for (final (style, mode) in combos) {
      final p = paintPhoto(
        big,
        PaintSettings(
            style: style,
            colorMode: mode,
            workSize: 500,
            paperColor: style.spec.paper),
      );
      File('$out/${style.name}_${mode.name}.svg')
          .writeAsStringSync(paintingToSvg(p, outputScale: 1));
    }
  }, skip: out == null ? 'GALLERY_OUT not set' : false);
}
