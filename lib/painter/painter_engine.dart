import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';
import 'models.dart';

/// Painterly rendering with layered brush strokes (after Hertzmann 1998).
///
/// For every layer, from a big brush to a small one:
///  1. blur the photo to the scale of the brush (`col`);
///  2. build a smooth orientation field from the structure tensor, so strokes
///     run *along* edges and contours (`ang`);
///  3. measure where this layer adds information compared to the previous,
///     coarser layer (`err`) – the first layer covers the whole canvas;
///  4. scatter seeds on a jittered grid, keep them where `err` is high;
///  5. grow each seed into a curved stroke that follows the field and stops
///     when the colour underneath changes too much;
///  6. turn the centre line into a tapered polygon (+ a few bristle lines).
///
/// Everything is pure Dart (no Flutter imports) so it runs in an isolate.

class _Layer {
  const _Layer(this.width, this.length, this.threshold);

  /// Brush width as fraction of the long side.
  final double width;

  /// Maximum stroke length in brush widths.
  final double length;

  /// Minimum normalised error before a stroke is placed.
  final double threshold;
}

const List<_Layer> _layers = [
  _Layer(0.060, 3.5, 0.00),
  _Layer(0.034, 4.0, 0.30),
  _Layer(0.019, 4.5, 0.38),
  _Layer(0.010, 4.0, 0.50),
];

class _P {
  const _P(this.x, this.y);
  final double x;
  final double y;
}

Painting paintImage(SourceImage src, PaintSettings s) {
  final rng = math.Random(s.seed);
  final w = src.width, h = src.height, n = w * h;

  final r = Float32List(n), g = Float32List(n), b = Float32List(n);
  final lum = Float32List(n);
  final pr = ((s.paperColor >> 16) & 0xFF) / 255.0;
  final pg = ((s.paperColor >> 8) & 0xFF) / 255.0;
  final pb = (s.paperColor & 0xFF) / 255.0;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    // composite (straight) alpha over the paper colour
    final al = src.rgba[o + 3] / 255.0;
    final rr = src.rgba[o] / 255.0 * al + pr * (1 - al);
    final gg = src.rgba[o + 1] / 255.0 * al + pg * (1 - al);
    final bb = src.rgba[o + 2] / 255.0 * al + pb * (1 - al);
    r[i] = rr;
    g[i] = gg;
    b[i] = bb;
    lum[i] = 0.299 * rr + 0.587 * gg + 0.114 * bb;
  }

  final longSide = math.max(w, h).toDouble();
  final strokes = <BrushStroke>[];
  List<Float32List>? prev;

  int idx(double x, double y) {
    var xi = x.toInt();
    var yi = y.toInt();
    if (xi < 0) {
      xi = 0;
    } else if (xi >= w) {
      xi = w - 1;
    }
    if (yi < 0) {
      yi = 0;
    } else if (yi >= h) {
      yi = h - 1;
    }
    return yi * w + xi;
  }

  for (var li = 0; li < _layers.length; li++) {
    final layer = _layers[li];
    final bw = math.max(2.0, longSide * layer.width * s.brushSize);

    // 1. reference colours at this brush scale
    final col = <Float32List>[
      gaussianBlur(r, w, h, bw * 0.3),
      gaussianBlur(g, w, h, bw * 0.3),
      gaussianBlur(b, w, h, bw * 0.3),
    ];

    // 2. orientation field (structure tensor), +90° so strokes follow edges
    final (gx, gy) = sobel(gaussianBlur(lum, w, h, math.max(1.0, bw * 0.25)), w, h);
    final xx = Float32List(n), xy = Float32List(n), yy = Float32List(n);
    for (var i = 0; i < n; i++) {
      xx[i] = gx[i] * gx[i];
      xy[i] = gx[i] * gy[i];
      yy[i] = gy[i] * gy[i];
    }
    final jxx = gaussianBlur(xx, w, h, bw * 0.6);
    final jxy = gaussianBlur(xy, w, h, bw * 0.6);
    final jyy = gaussianBlur(yy, w, h, bw * 0.6);
    final ang = Float32List(n);
    for (var i = 0; i < n; i++) {
      ang[i] = 0.5 * math.atan2(2 * jxy[i], jxx[i] - jyy[i]) + math.pi / 2;
    }

    // 3. where does this layer differ from the previous one?
    Float32List? err;
    final p = prev;
    if (p != null) {
      final e = Float32List(n);
      for (var i = 0; i < n; i++) {
        e[i] = ((col[0][i] - p[0][i]).abs() +
                (col[1][i] - p[1][i]).abs() +
                (col[2][i] - p[2][i]).abs()) /
            3.0;
      }
      final norm = percentile(e, 0.92) + 1e-6;
      for (var i = 0; i < n; i++) {
        final v = e[i] / norm;
        e[i] = v > 1 ? 1.0 : v;
      }
      err = e;
    }
    prev = col;

    // 4. seeds on a jittered grid (slightly beyond the borders)
    final thr = layer.threshold / s.detail;
    final step = bw * 0.55;
    final seeds = <_P>[];
    for (var y = -rng.nextDouble() * step; y < h + step; y += step) {
      for (var x = -rng.nextDouble() * step; x < w + step; x += step) {
        final px = x + (rng.nextDouble() - 0.5) * step;
        final py = y + (rng.nextDouble() - 0.5) * step;
        if (err == null) {
          seeds.add(_P(px, py));
        } else {
          final e = err[idx(px, py)];
          if (e > thr && rng.nextDouble() < 0.35 + e) seeds.add(_P(px, py));
        }
      }
    }
    seeds.shuffle(rng);

    // 5 + 6. grow strokes
    for (final sd in seeds) {
      final j = idx(sd.x, sd.y);
      final base = [col[0][j], col[1][j], col[2][j]];
      final c = _paintColor(base, s, rng);

      final line = _trace(sd.x, sd.y, base, col, ang, bw,
          layer.length * s.strokeLength, w, h, rng, idx);

      strokes.add(BrushStroke(
        kind: StrokeKind.fill,
        points: _outline(line, bw, rng),
        width: 0,
        color: _rgb(c),
        opacity: 0.92,
        layer: li,
      ));

      if (s.bristles > 0 && bw >= 5) {
        for (var k = 0; k < 2; k++) {
          final off = (rng.nextDouble() - 0.5) * 0.6 * bw;
          final f = 1 +
              (k == 0 ? 0.15 : -0.15) * (0.5 + rng.nextDouble()) * s.bristles;
          strokes.add(BrushStroke(
            kind: StrokeKind.line,
            points: _offsetLine(line, off),
            width: bw * 0.14,
            color: _rgb([c[0] * f, c[1] * f, c[2] * f]),
            opacity: 0.6,
            layer: li,
          ));
        }
      }
    }
  }

  return Painting(
    width: w,
    height: h,
    paperColor: s.paperColor,
    strokes: strokes,
  );
}

List<double> _paintColor(List<double> base, PaintSettings s, math.Random rng) {
  final m = (base[0] + base[1] + base[2]) / 3;
  final c = List<double>.generate(3, (k) => m + (base[k] - m) * s.vibrance);
  for (var k = 0; k < 3; k++) {
    c[k] += (rng.nextDouble() - 0.5) * 0.07 * s.colorJitter;
  }
  final f = 1 + (rng.nextDouble() - 0.5) * 0.14 * s.colorJitter;
  for (var k = 0; k < 3; k++) {
    c[k] = _clamp01(c[k] * f);
  }
  return c;
}

double _clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

int _rgb(List<double> c) {
  int ch(double v) => (_clamp01(v) * 255).round();
  return (ch(c[0]) << 16) | (ch(c[1]) << 8) | ch(c[2]);
}

List<_P> _trace(
  double x,
  double y,
  List<double> c,
  List<Float32List> col,
  Float32List ang,
  double bw,
  double maxLen,
  int w,
  int h,
  math.Random rng,
  int Function(double, double) idx,
) {
  final step = bw * 0.5;
  final half = math.max(1, (maxLen * bw / step / 2).toInt());
  final a0 = ang[idx(x, y)] + (rng.nextDouble() - 0.5) * 0.3;
  final fwd = <_P>[];
  final bwd = <_P>[];

  for (final sgn in const [1.0, -1.0]) {
    final acc = sgn > 0 ? fwd : bwd;
    var cx = x, cy = y;
    var dx = math.cos(a0) * sgn, dy = math.sin(a0) * sgn;
    for (var i = 0; i < half; i++) {
      final a = ang[idx(cx, cy)];
      var nx = math.cos(a), ny = math.sin(a);
      if (nx * dx + ny * dy < 0) {
        nx = -nx;
        ny = -ny;
      }
      // inertia: turn smoothly instead of snapping to the field
      dx = dx * 0.6 + nx * 0.4;
      dy = dy * 0.6 + ny * 0.4;
      var d = math.sqrt(dx * dx + dy * dy);
      if (d == 0) d = 1;
      dx /= d;
      dy /= d;
      final nx2 = cx + dx * step, ny2 = cy + dy * step;
      if (nx2 < -bw || ny2 < -bw || nx2 > w + bw || ny2 > h + bw) break;
      if (i > 0) {
        final j = idx(nx2, ny2);
        final diff = ((col[0][j] - c[0]).abs() +
                (col[1][j] - c[1]).abs() +
                (col[2][j] - c[2]).abs()) /
            3.0;
        if (diff > 0.12) break;
      }
      cx = nx2;
      cy = ny2;
      acc.add(_P(cx, cy));
    }
  }

  final line = <_P>[...bwd.reversed, _P(x, y), ...fwd];
  if (line.length < 2) {
    final ox = math.cos(a0) * bw * 0.4, oy = math.sin(a0) * bw * 0.4;
    return [_P(x - ox, y - oy), _P(x + ox, y + oy)];
  }
  return line;
}

/// Unit normals (-ty, tx) along a polyline.
List<_P> _normals(List<_P> p) {
  final n = p.length;
  return List<_P>.generate(n, (i) {
    final a = p[math.max(0, i - 1)];
    final b = p[math.min(n - 1, i + 1)];
    final tx = b.x - a.x, ty = b.y - a.y;
    var d = math.sqrt(tx * tx + ty * ty);
    if (d == 0) d = 1;
    return _P(-ty / d, tx / d);
  });
}

Float32List _offsetLine(List<_P> p, double off) {
  final nm = _normals(p);
  final out = Float32List(p.length * 2);
  for (var i = 0; i < p.length; i++) {
    out[2 * i] = p[i].x + nm[i].x * off;
    out[2 * i + 1] = p[i].y + nm[i].y * off;
  }
  return out;
}

/// Tapered, slightly wobbly polygon around the centre line.
Float32List _outline(List<_P> p, double bw, math.Random rng) {
  final n = p.length;
  final nm = _normals(p);
  final half = bw * 0.5;

  final cum = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    final dx = p[i].x - p[i - 1].x, dy = p[i].y - p[i - 1].y;
    cum[i] = cum[i - 1] + math.sqrt(dx * dx + dy * dy);
  }
  final total = cum[n - 1] == 0 ? 1.0 : cum[n - 1];

  final left = <_P>[], right = <_P>[];
  for (var i = 0; i < n; i++) {
    final t = cum[i] / total;
    var taper = 1.0;
    if (t < 0.18) taper = math.pow(t / 0.18, 0.6).toDouble();
    if (t > 0.7) {
      taper = math.min(taper, math.pow((1 - t) / 0.3, 0.7).toDouble());
    }
    final r = half * (0.3 + 0.7 * taper);
    final wl = 1 + (rng.nextDouble() - 0.5) * 0.25;
    final wr = 1 + (rng.nextDouble() - 0.5) * 0.25;
    final nx = nm[i].x, ny = nm[i].y;
    left.add(_P(p[i].x + nx * r * wl, p[i].y + ny * r * wl));
    right.add(_P(p[i].x - nx * r * wr, p[i].y - ny * r * wr));
  }

  // rounded tips just beyond both ends (tangent = (ny, -nx))
  final tip0 = _P(p[0].x - nm[0].y * half * 0.45, p[0].y + nm[0].x * half * 0.45);
  final tip1 = _P(p[n - 1].x + nm[n - 1].y * half * 0.45,
      p[n - 1].y - nm[n - 1].x * half * 0.45);

  final poly = <_P>[tip0, ...left, tip1, ...right.reversed];
  final out = Float32List(poly.length * 2);
  for (var i = 0; i < poly.length; i++) {
    out[2 * i] = poly[i].x;
    out[2 * i + 1] = poly[i].y;
  }
  return out;
}
