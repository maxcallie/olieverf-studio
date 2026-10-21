import 'dart:math' as math;
import 'dart:typed_data';

int _clamp(int i, int n) => i < 0 ? 0 : (i >= n ? n - 1 : i);

/// Gaussian blur approximated by three box-blur passes (O(n) per pass).
Float32List gaussianBlur(Float32List src, int w, int h, double sigma) {
  final r = math.max(0, ((math.sqrt(4 * sigma * sigma + 1) - 1) / 2).round());
  final a = Float32List.fromList(src);
  if (r < 1) return a;
  final tmp = Float32List(src.length);
  for (var k = 0; k < 3; k++) {
    _boxH(a, tmp, w, h, r);
    _boxV(tmp, a, w, h, r);
  }
  return a;
}

void _boxH(Float32List s, Float32List d, int w, int h, int r) {
  final inv = 1.0 / (2 * r + 1);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var acc = 0.0;
    for (var k = -r; k <= r; k++) {
      acc += s[row + _clamp(k, w)];
    }
    for (var x = 0; x < w; x++) {
      d[row + x] = acc * inv;
      acc += s[row + _clamp(x + r + 1, w)] - s[row + _clamp(x - r, w)];
    }
  }
}

void _boxV(Float32List s, Float32List d, int w, int h, int r) {
  final inv = 1.0 / (2 * r + 1);
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    for (var k = -r; k <= r; k++) {
      acc += s[_clamp(k, h) * w + x];
    }
    for (var y = 0; y < h; y++) {
      d[y * w + x] = acc * inv;
      acc += s[_clamp(y + r + 1, h) * w + x] - s[_clamp(y - r, h) * w + x];
    }
  }
}

/// Sobel gradients (gx, gy) with clamped borders.
(Float32List, Float32List) sobel(Float32List l, int w, int h) {
  final gx = Float32List(l.length);
  final gy = Float32List(l.length);
  for (var y = 0; y < h; y++) {
    final ym = _clamp(y - 1, h) * w;
    final y0 = y * w;
    final yp = _clamp(y + 1, h) * w;
    for (var x = 0; x < w; x++) {
      final xm = _clamp(x - 1, w);
      final xp = _clamp(x + 1, w);
      final tl = l[ym + xm], tc = l[ym + x], tr = l[ym + xp];
      final ml = l[y0 + xm], mr = l[y0 + xp];
      final bl = l[yp + xm], bc = l[yp + x], br = l[yp + xp];
      gx[y0 + x] = (tr + 2 * mr + br) - (tl + 2 * ml + bl);
      gy[y0 + x] = (bl + 2 * bc + br) - (tl + 2 * tc + tr);
    }
  }
  return (gx, gy);
}

/// Approximate percentile (p in 0..1) using a subsample.
double percentile(Float32List v, double p) {
  final stride = math.max(1, v.length ~/ 60000);
  final s = <double>[];
  for (var i = 0; i < v.length; i += stride) {
    s.add(v[i]);
  }
  s.sort();
  return s[((s.length - 1) * p).round()];
}

/// Kuwahara filter: per pixel, the mean colour of the least-varying of its
/// four (r+1)×(r+1) quadrants. Smooths texture but keeps edges sharp – the
/// way a painter simplifies. O(n) thanks to summed-area tables.
(Float32List, Float32List, Float32List) kuwahara(
    Float32List r, Float32List g, Float32List b, int w, int h, int rad) {
  final n = w * h;
  if (rad < 1) {
    return (Float32List.fromList(r), Float32List.fromList(g), Float32List.fromList(b));
  }
  final w1 = w + 1;
  Float64List sat(double Function(int i) f) {
    final s = Float64List(w1 * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0.0;
      for (var x = 0; x < w; x++) {
        row += f(y * w + x);
        s[(y + 1) * w1 + x + 1] = s[y * w1 + x + 1] + row;
      }
    }
    return s;
  }

  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    lum[i] = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
  }
  final sr = sat((i) => r[i]), sg = sat((i) => g[i]), sb = sat((i) => b[i]);
  final sl = sat((i) => lum[i]), sl2 = sat((i) => lum[i] * lum[i]);
  double box(Float64List s, int y0, int y1, int x0, int x1) =>
      s[y1 * w1 + x1] - s[y0 * w1 + x1] - s[y1 * w1 + x0] + s[y0 * w1 + x0];
  int cl(int v, int hi) => v < 0 ? 0 : (v > hi ? hi : v);

  final or = Float32List(n), og = Float32List(n), ob = Float32List(n);
  const quads = [
    [-1, 0, -1, 0],
    [-1, 0, 0, 1],
    [0, 1, -1, 0],
    [0, 1, 0, 1],
  ];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var best = double.infinity;
      for (final q in quads) {
        // quadrant [y0, y1) × [x0, x1)
        final y0 = cl(q[0] == -1 ? y - rad : y, h);
        final y1 = cl(q[1] == 0 ? y + 1 : y + rad + 1, h);
        final x0 = cl(q[2] == -1 ? x - rad : x, w);
        final x1 = cl(q[3] == 0 ? x + 1 : x + rad + 1, w);
        final area = ((y1 - y0) * (x1 - x0)).toDouble();
        if (area <= 0) continue;
        final ml = box(sl, y0, y1, x0, x1) / area;
        final v = box(sl2, y0, y1, x0, x1) / area - ml * ml;
        if (v < best) {
          best = v;
          final i = y * w + x;
          or[i] = box(sr, y0, y1, x0, x1) / area;
          og[i] = box(sg, y0, y1, x0, x1) / area;
          ob[i] = box(sb, y0, y1, x0, x1) / area;
        }
      }
    }
  }
  return (or, og, ob);
}

double _smoothstep(double a, double b, double x) {
  var t = (x - a) / (b - a);
  t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
  return t * t * (3 - 2 * t);
}

/// Groups luminance into a few soft value bands (keeps hue), in place.
/// [amount] per pixel: 0 = untouched, 1 = fully banded.
void valueMass(Float32List r, Float32List g, Float32List b, int levels,
    Float32List amount) {
  for (var i = 0; i < r.length; i++) {
    final l = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
    final t = l * levels;
    final f = t.floorToDouble();
    final q = (f + _smoothstep(0.3, 0.7, t - f)) / levels;
    final ratio = (q + 0.02) / (l + 0.02);
    final a = amount[i];
    double mix(double v) {
      var o = v * ratio;
      o = o < 0 ? 0.0 : (o > 1 ? 1.0 : o);
      return v + (o - v) * a;
    }

    r[i] = mix(r[i]);
    g[i] = mix(g[i]);
    b[i] = mix(b[i]);
  }
}
