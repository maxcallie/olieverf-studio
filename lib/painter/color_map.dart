import 'dart:math' as math;
import 'dart:typed_data';

import 'styles.dart';

double lumOf(List<double> c) => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

double clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

/// Maps stroke colours according to a [ColorMode] and provides the "ink"
/// colour for drawing styles / charcoal.
class ColorMap {
  ColorMap._(this.mode, this.ink,
      {List<double>? dark,
      List<double>? light,
      List<List<double>>? nearest,
      List<List<double>>? pigments})
      : _dark = dark,
        _light = light,
        _nearest = nearest,
        _pigments = pigments;

  factory ColorMap(ColorMode mode, Float32List r, Float32List g, Float32List b,
      math.Random rng) {
    switch (mode) {
      case ColorMode.kleur:
        return ColorMap._(mode, const [0.13, 0.11, 0.10]);
      case ColorMode.zwartwit:
        return ColorMap._(mode, const [0.08, 0.08, 0.08],
            dark: const [0.04, 0.04, 0.04], light: const [0.97, 0.97, 0.97]);
      case ColorMode.sepia:
        return ColorMap._(mode, const [0.24, 0.14, 0.07],
            dark: const [0.16, 0.09, 0.04], light: const [0.97, 0.91, 0.79]);
      case ColorMode.cyanotypie:
        return ColorMap._(mode, const [0.05, 0.16, 0.38],
            dark: const [0.03, 0.12, 0.32], light: const [0.88, 0.94, 1.0]);
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
        return ColorMap._(mode, darkest, nearest: pal);
      case ColorMode.zorn:
        return ColorMap._(mode, const [0.09, 0.09, 0.11],
            pigments: _mixes(const {
              'ochre': [0.78, 0.6, 0.26],
              'vermilion': [0.82, 0.24, 0.14],
            }, const [0.96, 0.94, 0.89], const [0.09, 0.09, 0.11]));
      case ColorMode.aarde:
        return ColorMap._(mode, const [0.18, 0.13, 0.09],
            pigments: _mixes(const {
              'umber': [0.39, 0.29, 0.2],
              'sienna': [0.6, 0.28, 0.13],
              'ochre': [0.78, 0.6, 0.26],
              'verte': [0.45, 0.52, 0.38],
            }, const [0.95, 0.92, 0.84], const [0.12, 0.1, 0.08]));
      case ColorMode.impressionist:
        return ColorMap._(mode, const [0.18, 0.16, 0.42]);
      case ColorMode.nocturne:
        return ColorMap._(mode, const [0.05, 0.08, 0.14]);
    }
  }

  final ColorMode mode;

  /// Line colour for pencil/pen/charcoal.
  final List<double> ink;
  final List<double>? _dark;
  final List<double>? _light;
  final List<List<double>>? _nearest;
  final List<List<double>>? _pigments;

  List<double> call(List<double> c) {
    switch (mode) {
      case ColorMode.kleur:
        return c;
      case ColorMode.palet:
        return List<double>.of(_closest(_nearest!, c));
      case ColorMode.zorn:
      case ColorMode.aarde:
        return _pigmentMix(_pigments!, c);
      case ColorMode.impressionist:
        return _impressionist(c);
      case ColorMode.nocturne:
        return _nocturne(c);
      case ColorMode.zwartwit:
      case ColorMode.sepia:
      case ColorMode.cyanotypie:
        final dark = _dark!, light = _light!;
        final t = clamp01(lumOf(c));
        return List<double>.generate(
            3, (k) => dark[k] + (light[k] - dark[k]) * t);
    }
  }
}

List<double> _closest(List<List<double>> pal, List<double> c) {
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
  return best;
}

/// All mixes a painter can make from a few pigments + white + black.
List<List<double>> _mixes(Map<String, List<double>> pigments,
    List<double> white, List<double> black) {
  final names = pigments.keys.toList();
  final cols = <List<double>>[];
  List<double> lerp(List<double> a, List<double> b, double t) =>
      List<double>.generate(3, (k) => a[k] + (b[k] - a[k]) * t);
  for (var i = 0; i < names.length; i++) {
    for (var j = i; j < names.length; j++) {
      final ratios = i == j ? const [0.0] : const [0.0, 0.33, 0.66];
      for (final ratio in ratios) {
        final base = lerp(pigments[names[i]]!, pigments[names[j]]!, ratio);
        for (final t in const [0.0, 0.25, 0.5, 0.75]) {
          cols.add(lerp(base, white, t));
        }
        for (final t in const [0.3, 0.55, 0.8]) {
          cols.add(lerp(base, black, t));
        }
      }
    }
  }
  for (var k = 0; k <= 6; k++) {
    cols.add(lerp(black, white, k / 6));
  }
  return cols;
}

/// Nearest pigment mix (value matters most), softened with the original.
List<double> _pigmentMix(List<List<double>> pal, List<double> c) {
  final l = lumOf(c);
  var best = pal.first;
  var bestD = double.infinity;
  for (final p in pal) {
    final dl = lumOf(p) - l;
    final d = (p[0] - c[0]) * (p[0] - c[0]) +
        (p[1] - c[1]) * (p[1] - c[1]) +
        (p[2] - c[2]) * (p[2] - c[2]) +
        2.0 * dl * dl;
    if (d < bestD) {
      bestD = d;
      best = p;
    }
  }
  final shift = (l - lumOf(best)) * 0.8;
  return List<double>.generate(3, (k) {
    final m = clamp01(best[k] + shift);
    final grey = c[k] + (l - c[k]) * 0.5;
    return clamp01(m * 0.7 + grey * 0.3);
  });
}

/// No black; violet-blue shadows, warm sunny lights.
List<double> _impressionist(List<double> c) {
  final l = lumOf(c);
  final m = (c[0] + c[1] + c[2]) / 3;
  var o = List<double>.generate(3, (k) => m + (c[k] - m) * 1.3);
  const blue = [0.32, 0.26, 0.6], warm = [1.0, 0.9, 0.62];
  final sh = math.pow(1 - l, 1.5).toDouble() * 0.55;
  final hl = math.max(0.0, l - 0.6) * 0.7;
  o = List<double>.generate(3, (k) {
    var v = o[k] + (blue[k] - o[k]) * sh;
    v = v + (warm[k] - v) * hl;
    return clamp01(0.15 + v * 0.85);
  });
  return o;
}

/// Whistler-like night: blue-grey tonal scale, warm lamps keep colour.
List<double> _nocturne(List<double> c) {
  final l = lumOf(c);
  const dark = [0.05, 0.08, 0.14], mid = [0.22, 0.32, 0.4], light = [0.78, 0.8, 0.7];
  final g = List<double>.generate(
      3,
      (k) => l < 0.5
          ? dark[k] + (mid[k] - dark[k]) * (l / 0.5)
          : mid[k] + (light[k] - mid[k]) * ((l - 0.5) / 0.5));
  var out = List<double>.generate(3, (k) => g[k] * 0.85 + c[k] * 0.15);
  final sat = c.reduce(math.max) - c.reduce(math.min);
  if (l > 0.7 && sat > 0.25) {
    out = List<double>.generate(3, (k) => out[k] + (c[k] * 1.05 - out[k]) * 0.6);
  }
  return List<double>.generate(3, (k) => clamp01(out[k]));
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
