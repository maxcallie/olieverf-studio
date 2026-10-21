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

  test('focus point is respected and reported', () {
    final p = paintPhoto(
        photo, const PaintSettings(focusX: 0.25, focusY: 0.75));
    expect(p.focusX, closeTo(0.25, 0.01));
    expect(p.focusY, closeTo(0.75, 0.01));
    final auto = paintPhoto(photo, const PaintSettings());
    expect(auto.focusX, inInclusiveRange(0, 1));
  });

  test('artist features off still paints', () {
    final p = paintPhoto(
        photo, const PaintSettings(focus: 0, simplify: 0, temperature: 0));
    expect(p.strokes, isNotEmpty);
  });

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
      (PaintStyle.olieverf, ColorMode.zorn),
      (PaintStyle.olieverf, ColorMode.impressionist),
      (PaintStyle.olieverf, ColorMode.aarde),
      (PaintStyle.olieverf, ColorMode.nocturne),
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
    final plain = paintPhoto(
      big,
      PaintSettings(
          workSize: 500,
          focus: 0,
          simplify: 0,
          temperature: 0,
          paperColor: 0xECE4D4),
    );
    File('$out/olieverf_zonder_kunstenaar.svg')
        .writeAsStringSync(paintingToSvg(plain, outputScale: 1));
    final tapped = paintPhoto(
      big,
      PaintSettings(
          workSize: 500, focusX: 0.62, focusY: 0.42, paperColor: 0xA86A45),
    );
    File('$out/olieverf_focus_rechteroog.svg')
        .writeAsStringSync(paintingToSvg(tapped, outputScale: 1));
  }, skip: out == null ? 'GALLERY_OUT not set' : false);
}
