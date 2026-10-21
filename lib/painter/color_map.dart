import 'dart:math' as math;
import 'dart:typed_data';

import 'styles.dart';

double lumOf(List<double> c) => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

double clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

/// Maps stroke colours according to a [ColorMode] and provides the "ink"
/// colour for drawing styles.
class ColorMap {
  ColorMap._(this.mode, this.ink, this._dark, this._light, this._palette);

  factory ColorMap(ColorMode mode, Float32List r, Float32List g, Float32List b,
      math.Random rng) {
    switch (mode) {
      case ColorMode.kleur:
        return ColorMap._(mode, const [0.13, 0.11, 0.10], null, null, null);
      case ColorMode.zwartwit:
        return ColorMap._(mode, const [0.08, 0.08, 0.08],
            const [0.04, 0.04, 0.04], const [0.97, 0.97, 0.97], null);
      case ColorMode.sepia:
        return ColorMap._(mode, const [0.24, 0.14, 0.07],
            const [0.16, 0.09, 0.04], const [0.97, 0.91, 0.79], null);
      case ColorMode.cyanotypie:
        return ColorMap._(mode, const [0.05, 0.16, 0.38],
            const [0.03, 0.12, 0.32], const [0.88, 0.94, 1.0], null);
      case ColorMode.palet:
        final pal = _kmeans(r, g, b, 8, rng);
        // a little extra saturation so the palette feels "painted"
        for (final p in pal) {
          final m = (p[0] + p[1] + p[2]) / 3;
          for (var k = 0; k < 3; k++) {
            p[k] = clamp01(m + (p[k] - m) * 1.25);
          }
        }
        var darkest = pal.first;
        for (final p in pal) {
          if (lumOf(p) < lumOf(darkest)) darkest = p;
        }
        return ColorMap._(mode, darkest, null, null, pal);
    }
  }

  final ColorMode mode;

  /// Line colour for pencil/pen/charcoal.
  final List<double> ink;
  final List<double>? _dark;
  final List<double>? _light;
  final List<List<double>>? _palette;

  List<double> call(List<double> c) {
    final pal = _palette;
    if (pal != null) {
      var best = pal.first;
      var bestD = double.infinity;
      for (final p in pal) {
        final d = (p[0] - c[0]) * (p[0] - c[0]) +
            (p[1] - c[1]) * (p[1] - c[1]) +
            (p[2] - c[2]) * (p[2] - c[2]);
        if (d < bestD) {
          bestD = d;
          best = p;
        }
      }
      return List<double>.of(best);
    }
    final dark = _dark, light = _light;
    if (dark == null || light == null) return c;
    final t = clamp01(lumOf(c));
    return List<double>.generate(3, (k) => dark[k] + (light[k] - dark[k]) * t);
  }
}

List<List<double>> _kmeans(
    Float32List r, Float32List g, Float32List b, int k, math.Random rng,
    {int iterations = 8}) {
  final n = r.length;
  final stride = math.max(1, n ~/ 6000);
  final px = <List<double>>[];
  for (var i = 0; i < n; i += stride) {
    px.add([r[i], g[i], b[i]]);
  }
  final cent = List<List<double>>.generate(
      k, (_) => List<double>.of(px[rng.nextInt(px.length)]));
  final label = List<int>.filled(px.length, 0);
  for (var it = 0; it < iterations; it++) {
    for (var i = 0; i < px.length; i++) {
      var best = 0;
      var bestD = double.infinity;
      for (var j = 0; j < k; j++) {
        final c = cent[j];
        final d = (px[i][0] - c[0]) * (px[i][0] - c[0]) +
            (px[i][1] - c[1]) * (px[i][1] - c[1]) +
            (px[i][2] - c[2]) * (px[i][2] - c[2]);
        if (d < bestD) {
          bestD = d;
          best = j;
        }
      }
      label[i] = best;
    }
    for (var j = 0; j < k; j++) {
      var sr = 0.0, sg = 0.0, sb = 0.0;
      var cnt = 0;
      for (var i = 0; i < px.length; i++) {
        if (label[i] != j) continue;
        sr += px[i][0];
        sg += px[i][1];
        sb += px[i][2];
        cnt++;
      }
      if (cnt > 0) cent[j] = [sr / cnt, sg / cnt, sb / cnt];
    }
  }
  return cent;
}
