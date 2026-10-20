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
