import 'dart:math' as math;
import 'dart:typed_data';

import 'color_map.dart';
import 'image_ops.dart';
import 'models.dart';

/// Turns a photo into a list of vector strokes in one of the [PaintStyle]s.
///
/// Painterly styles (after Hertzmann 1998), per layer from big to small brush:
///  1. blur the photo to the scale of the brush (`col`);
///  2. orientation field from the structure tensor, so strokes follow edges;
///  3. where does this layer add information vs. the previous one (`err`);
///  4. seeds on a jittered grid, kept where `err` is high;
///  5. grow each seed along the field until the colour changes too much;
///  6. centre line → tapered polygon (+ bristles / dots / outlines per style).
///
/// Drawing styles (pencil, pen) build hatching from the tone of the image
/// plus contour lines that follow strong edges.
///
/// Pure Dart (no Flutter imports) so it can run in an isolate.

class _P {
  const _P(this.x, this.y);
  final double x;
  final double y;
}

/// Shared per-image data.
class _Ctx {
  _Ctx(this.w, this.h, this.r, this.g, this.b, this.lum, this.paper);
  final int w, h;
  final Float32List r, g, b, lum;
  final List<double> paper;

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
}

Painting paintPhoto(SourceImage src, PaintSettings s) {
  final rng = math.Random(s.seed);
  final w = src.width, h = src.height, n = w * h;

  final paper = [
    ((s.paperColor >> 16) & 0xFF) / 255.0,
    ((s.paperColor >> 8) & 0xFF) / 255.0,
    (s.paperColor & 0xFF) / 255.0,
  ];
  final r = Float32List(n), g = Float32List(n), b = Float32List(n);
  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    // composite (straight) alpha over the paper colour
    final al = src.rgba[o + 3] / 255.0;
    final rr = src.rgba[o] / 255.0 * al + paper[0] * (1 - al);
    final gg = src.rgba[o + 1] / 255.0 * al + paper[1] * (1 - al);
    final bb = src.rgba[o + 2] / 255.0 * al + paper[2] * (1 - al);
    r[i] = rr;
    g[i] = gg;
    b[i] = bb;
    lum[i] = 0.299 * rr + 0.587 * gg + 0.114 * bb;
  }

  final ctx = _Ctx(w, h, r, g, b, lum, paper);
  final cmap = ColorMap(s.colorMode, r, g, b, rng);
  final spec = s.style.spec;
  final strokes = spec.isSketch
      ? _sketch(ctx, spec, cmap, s, rng)
      : _paint(ctx, spec, cmap, s, rng);

  return Painting(
    width: w,
    height: h,
    paperColor: s.paperColor,
    strokes: strokes,
  );
}

// ---------------------------------------------------------------- shared

/// Smooth orientation field along edges (structure tensor + 90°).
Float32List _flow(_Ctx c, double scale) {
  final n = c.w * c.h;
  final (gx, gy) =
      sobel(gaussianBlur(c.lum, c.w, c.h, math.max(1.0, scale * 0.25)), c.w, c.h);
  final xx = Float32List(n), xy = Float32List(n), yy = Float32List(n);
  for (var i = 0; i < n; i++) {
    xx[i] = gx[i] * gx[i];
    xy[i] = gx[i] * gy[i];
    yy[i] = gy[i] * gy[i];
  }
  final jxx = gaussianBlur(xx, c.w, c.h, scale * 0.6);
  final jxy = gaussianBlur(xy, c.w, c.h, scale * 0.6);
  final jyy = gaussianBlur(yy, c.w, c.h, scale * 0.6);
  final ang = Float32List(n);
  for (var i = 0; i < n; i++) {
    ang[i] = 0.5 * math.atan2(2 * jxy[i], jxx[i] - jyy[i]) + math.pi / 2;
  }
  return ang;
}

int _rgb(List<double> c) {
  int ch(double v) => (clamp01(v) * 255).round();
  return (ch(c[0]) << 16) | (ch(c[1]) << 8) | ch(c[2]);
}

Float32List _flat(List<_P> pts) {
  final out = Float32List(pts.length * 2);
  for (var i = 0; i < pts.length; i++) {
    out[2 * i] = pts[i].x;
    out[2 * i + 1] = pts[i].y;
  }
  return out;
}

// ---------------------------------------------------------------- painting

List<BrushStroke> _paint(
    _Ctx c, StyleSpec st, ColorMap cmap, PaintSettings s, math.Random rng) {
  final w = c.w, h = c.h, n = w * h;
  final longSide = math.max(w, h).toDouble();
  final strokes = <BrushStroke>[];
  List<Float32List>? prev;

  // charcoal: tone range of the photo + ink colour
  final ink = cmap.mode == ColorMode.kleur ? const [0.10, 0.09, 0.09] : cmap.ink;
  final lumLo = percentile(c.lum, 0.03), lumHi = percentile(c.lum, 0.97);
  final flat = st.brush == BrushModel.flat;
  final drift = _Noise2(rng, w, h, 5);

  for (var li = 0; li < st.layers.length; li++) {
    final layer = st.layers[li];
    final bw = math.max(2.0, longSide * layer.width * s.brushSize);

    final col = <Float32List>[
      gaussianBlur(c.r, w, h, bw * 0.3),
      gaussianBlur(c.g, w, h, bw * 0.3),
      gaussianBlur(c.b, w, h, bw * 0.3),
    ];
    final ang = _flow(c, bw);

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

    final thr = layer.threshold / s.detail;
    final step =
        bw * (st.spacing ?? (st.shape == StrokeShape.dot ? 0.6 : 0.55));
    final seeds = <_P>[];
    for (var y = -rng.nextDouble() * step; y < h + step; y += step) {
      for (var x = -rng.nextDouble() * step; x < w + step; x += step) {
        final px = x + (rng.nextDouble() - 0.5) * step;
        final py = y + (rng.nextDouble() - 0.5) * step;
        if (err == null || layer.threshold == 0) {
          seeds.add(_P(px, py));
        } else {
          final e = err[c.idx(px, py)];
          if (e > thr && rng.nextDouble() < 0.35 + e) seeds.add(_P(px, py));
        }
      }
    }
    seeds.shuffle(rng);

    final isLast = li == st.layers.length - 1;
    final opacity = li == 0 ? (st.baseOpacity ?? st.opacity) : st.opacity;

    for (final sd in seeds) {
      final j = c.idx(sd.x, sd.y);
      final base = [col[0][j], col[1][j], col[2][j]];
      if (lumOf(base) > st.skipLight) continue;

      // colour: vibrance + jitter, then the colour mode / charcoal tone
      final m = (base[0] + base[1] + base[2]) / 3;
      final vib = st.vibrance * s.vibrance;
      var col3 = List<double>.generate(3, (k) => m + (base[k] - m) * vib);
      final jit = st.jitter * s.colorJitter;
      if (flat) {
        // smooth warm/cool + value drift over the canvas, little noise
        final d = drift.sample(sd.x, sd.y);
        final dr = st.drift * s.colorJitter;
        col3[0] += d[0] * dr + d[1] * dr * 0.5;
        col3[1] += d[0] * 0.3 * dr + d[1] * dr * 0.5;
        col3[2] += -d[0] * dr + d[1] * dr * 0.5;
        for (var k = 0; k < 3; k++) {
          col3[k] = clamp01(col3[k] + _gauss(rng) * 0.02 * jit);
        }
      } else {
        for (var k = 0; k < 3; k++) {
          col3[k] += (rng.nextDouble() - 0.5) * 0.07 * jit;
        }
        final f = 1 + (rng.nextDouble() - 0.5) * 0.14 * jit;
        for (var k = 0; k < 3; k++) {
          col3[k] = clamp01(col3[k] * f);
        }
      }
      if (st.mono) {
        final t = math
            .pow(clamp01((lumOf(col3) - lumLo) / (lumHi - lumLo + 1e-6)), 1.4)
            .toDouble();
        if (t > 0.8) continue; // leave the paper showing in highlights
        col3 = List<double>.generate(
            3, (k) => ink[k] + (c.paper[k] - ink[k]) * t);
      } else {
        col3 = cmap(col3);
      }
      if (st.lighten > 0) {
        col3 = List<double>.generate(
            3, (k) => col3[k] + (c.paper[k] - col3[k]) * st.lighten);
      }

      if (st.shape == StrokeShape.dot) {
        final rad = bw * 0.45 * (0.8 + rng.nextDouble() * 0.4);
        strokes.add(BrushStroke(
          kind: StrokeKind.dot,
          points: Float32List.fromList([sd.x, sd.y]),
          width: rad * 2,
          color: _rgb(col3),
          opacity: st.opacity,
          layer: li,
        ));
        continue;
      }

      final line = _trace(c, sd.x, sd.y, base, col, ang, bw,
          layer.length * s.strokeLength, rng, st.angleNoise);
      if (flat) {
        _flatStroke(line, bw, col3, rng, st, s.bristles, li, strokes);
        continue;
      }
      final poly = _outline(line, bw, rng, st.wobble, st.taperMin);
      strokes.add(BrushStroke(
        kind: StrokeKind.fill,
        points: poly,
        width: 0,
        color: _rgb(col3),
        opacity: opacity,
        layer: li,
      ));

      if (st.outline > 0 && isLast) {
        strokes.add(BrushStroke(
          kind: StrokeKind.outline,
          points: poly,
          width: math.max(0.4, bw * st.outline),
          color: _rgb([col3[0] * 0.7, col3[1] * 0.7, col3[2] * 0.7]),
          opacity: 0.3,
          layer: li,
        ));
      }

      if (st.bristles > 0 && s.bristles > 0 && bw >= 5) {
        for (var k = 0; k < st.bristles; k++) {
          final off = (rng.nextDouble() - 0.5) * 0.7 * bw;
          final sgn = k.isEven ? 1.0 : -1.0;
          final bf = 1 +
              sgn *
                  st.bristleContrast *
                  (0.5 + rng.nextDouble()) *
                  s.bristles;
          strokes.add(BrushStroke(
            kind: StrokeKind.line,
            points: _offsetLine(line, off),
            width: bw * st.bristleWidth,
            color: _rgb([col3[0] * bf, col3[1] * bf, col3[2] * bf]),
            opacity: st.bristleAlpha,
            layer: li,
          ));
        }
      }
    }
  }
  return strokes;
}

List<_P> _trace(
  _Ctx c,
  double x,
  double y,
  List<double> base,
  List<Float32List> col,
  Float32List ang,
  double bw,
  double maxLen,
  math.Random rng,
  double angleNoise,
) {
  final step = bw * 0.5;
  final half = math.max(1, (maxLen * bw / step / 2).toInt());
  final a0 = ang[c.idx(x, y)] + (rng.nextDouble() - 0.5) * angleNoise;
  final fwd = <_P>[];
  final bwd = <_P>[];

  for (final sgn in const [1.0, -1.0]) {
    final acc = sgn > 0 ? fwd : bwd;
    var cx = x, cy = y;
    var dx = math.cos(a0) * sgn, dy = math.sin(a0) * sgn;
    for (var i = 0; i < half; i++) {
      final a = ang[c.idx(cx, cy)];
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
      if (nx2 < -bw || ny2 < -bw || nx2 > c.w + bw || ny2 > c.h + bw) break;
      if (i > 0) {
        final j = c.idx(nx2, ny2);
        final diff = ((col[0][j] - base[0]).abs() +
                (col[1][j] - base[1]).abs() +
                (col[2][j] - base[2]).abs()) /
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
Float32List _outline(
    List<_P> p, double bw, math.Random rng, double wobble, double taperMin) {
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
    final r = half * (taperMin + (1 - taperMin) * taper);
    final wl = 1 + (rng.nextDouble() - 0.5) * wobble;
    final wr = 1 + (rng.nextDouble() - 0.5) * wobble;
    final nx = nm[i].x, ny = nm[i].y;
    left.add(_P(p[i].x + nx * r * wl, p[i].y + ny * r * wl));
    right.add(_P(p[i].x - nx * r * wr, p[i].y - ny * r * wr));
  }

  // rounded tips just beyond both ends (tangent = (ny, -nx))
  final k = half * (0.45 + wobble * 0.3);
  final tip0 = _P(p[0].x - nm[0].y * k, p[0].y + nm[0].x * k);
  final tip1 = _P(p[n - 1].x + nm[n - 1].y * k, p[n - 1].y - nm[n - 1].x * k);

  return _flat(<_P>[tip0, ...left, tip1, ...right.reversed]);
}

// ---------------------------------------------------------------- flat brush

double _gauss(math.Random r) {
  final u1 = 1.0 - r.nextDouble();
  final u2 = r.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

/// Smooth value noise on a coarse grid (smoothstep-bilinear), 3 channels.
class _Noise2 {
  _Noise2(math.Random rng, this.w, this.h, int cells)
      : gw = cells + 2,
        gh = math.max(2, (cells * h / w).round()) + 2 {
    v = List.generate(gh * gw * 3, (_) => rng.nextDouble() * 2 - 1);
  }

  final int w, h, gw, gh;
  late final List<double> v;

  List<double> sample(double x, double y) {
    final gx = clamp01(x / w) * (gw - 2);
    final gy = clamp01(y / h) * (gh - 2);
    final i = gx.toInt(), j = gy.toInt();
    var fx = gx - i, fy = gy - j;
    fx = fx * fx * (3 - 2 * fx);
    fy = fy * fy * (3 - 2 * fy);
    double at(int jj, int ii, int k) => v[(jj * gw + ii) * 3 + k];
    return List<double>.generate(3, (k) {
      final top = at(j, i, k) * (1 - fx) + at(j, i + 1, k) * fx;
      final bot = at(j + 1, i, k) * (1 - fx) + at(j + 1, i + 1, k) * fx;
      return top * (1 - fy) + bot * fy;
    });
  }
}

/// One Chaikin corner-cutting pass (keeps the end points).
List<_P> _chaikin(List<_P> p) {
  if (p.length < 3) return p;
  final q = <_P>[p.first];
  for (var i = 0; i < p.length - 1; i++) {
    final a = p[i], b = p[i + 1];
    q.add(_P(0.75 * a.x + 0.25 * b.x, 0.75 * a.y + 0.25 * b.y));
    q.add(_P(0.25 * a.x + 0.75 * b.x, 0.25 * a.y + 0.75 * b.y));
  }
  q.add(p.last);
  return q;
}

double _polyLength(List<_P> p) {
  var total = 0.0;
  for (var i = 1; i < p.length; i++) {
    final dx = p[i].x - p[i - 1].x, dy = p[i].y - p[i - 1].y;
    total += math.sqrt(dx * dx + dy * dy);
  }
  return total;
}

/// n points evenly spaced along the polyline.
List<_P> _resample(List<_P> p, int n) {
  final cum = List<double>.filled(p.length, 0);
  for (var i = 1; i < p.length; i++) {
    final dx = p[i].x - p[i - 1].x, dy = p[i].y - p[i - 1].y;
    cum[i] = cum[i - 1] + math.sqrt(dx * dx + dy * dy);
  }
  final total = cum.last == 0 ? 1e-6 : cum.last;
  final out = <_P>[];
  var j = 0;
  for (var i = 0; i < n; i++) {
    final s = total * i / (n - 1);
    while (j < p.length - 2 && cum[j + 1] < s) {
      j++;
    }
    var seg = cum[j + 1] - cum[j];
    if (seg == 0) seg = 1e-6;
    final t = (s - cum[j]) / seg;
    out.add(_P(p[j].x + (p[j + 1].x - p[j].x) * t,
        p[j].y + (p[j + 1].y - p[j].y) * t));
  }
  return out;
}

/// Smooth random width profile (two sines) instead of per-vertex noise.
List<double> _smoothWobble(math.Random rng, int n, double amp) {
  final f1 = 0.6 + rng.nextDouble(), f2 = 2.0 + rng.nextDouble() * 1.5;
  final p1 = rng.nextDouble() * 6.3, p2 = rng.nextDouble() * 6.3;
  final d = math.max(1, n - 1);
  return List<double>.generate(
      n,
      (i) =>
          1 +
          amp *
              (0.65 * math.sin(f1 * math.pi * i / d * 2 + p1) +
                  0.35 * math.sin(f2 * math.pi * i / d * 2 + p2)));
}

double _uniform(math.Random r, double a, double b) => a + (b - a) * r.nextDouble();

/// A flat-brush stroke: blunt head, solid body, dry fingered tail, faint
/// broken bristle tracks and (optionally) impasto ridge highlight + shadow.
void _flatStroke(List<_P> line, double w, List<double> c, math.Random rng,
    StyleSpec st, double bristleAmount, int layer, List<BrushStroke> out) {
  // minimum length: short stubs read as pixels
  final minLen = st.minLength * w;
  final l0 = _polyLength(line);
  if (l0 < minLen) {
    final a = line.first, b = line.last;
    var dx = b.x - a.x, dy = b.y - a.y;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < 1e-6) {
      final ang = rng.nextDouble() * math.pi;
      dx = math.cos(ang);
      dy = math.sin(ang);
    } else {
      dx /= d;
      dy /= d;
    }
    final ext = (minLen - l0) / 2;
    line = [_P(a.x - dx * ext, a.y - dy * ext), ...line,
      _P(b.x + dx * ext, b.y + dy * ext)];
  }
  line = _chaikin(line);
  final length = _polyLength(line);
  final n = math.max(6, math.min(32, (length / (w * 0.25)).toInt() + 2));
  final pts = _resample(line, n);
  final nm = _normals(pts);
  final half = w * 0.5;

  List<double> lighter(double f) =>
      List<double>.generate(3, (k) => clamp01(c[k] + (1 - c[k]) * f));
  List<double> darker(double f) =>
      List<double>.generate(3, (k) => clamp01(c[k] * (1 - f)));

  // point at fraction t along the stroke, lateral u in [-1, 1] × half width
  _P at(double t, double u) {
    final f = (t < 0 ? 0.0 : (t > 1 ? 1.0 : t)) * (n - 1);
    final i = math.min(f.toInt(), n - 2);
    final a = f - i;
    final x = pts[i].x * (1 - a) + pts[i + 1].x * a;
    final y = pts[i].y * (1 - a) + pts[i + 1].y * a;
    final nx = nm[i].x * (1 - a) + nm[i + 1].x * a;
    final ny = nm[i].y * (1 - a) + nm[i + 1].y * a;
    return _P(x + nx * u * half, y + ny * u * half);
  }

  // --- body with a dry, fingered tail
  final bodyEnd = _uniform(rng, st.bodyEnd.$1, st.bodyEnd.$2);
  final m = math.max(3, (bodyEnd * (n - 1)).toInt() + 1);
  final wl = _smoothWobble(rng, m, st.wobble);
  final wr = _smoothWobble(rng, m, st.wobble);
  final hr = st.headRound;
  final left = <_P>[], right = <_P>[];
  for (var i = 0; i < m; i++) {
    final t = i / (n - 1);
    final head = (1 - 3 * hr) +
        3 * hr * math.sqrt(math.min(1.0, t / (0.06 + hr)));
    left.add(at(t, head * wl[i]));
    right.add(at(t, -head * wr[i]));
  }
  final tb = (m - 1) / (n - 1);

  final nf = math.max(3, math.min(st.fingers, (w / st.fingerPx).round()));
  final cuts = List<double>.generate(nf - 1, (_) => _uniform(rng, -0.95, 0.95))
    ..sort();
  final bounds = <double>[1.0, ...cuts.reversed, -1.0];
  final tail = <_P>[];
  for (var f = 0; f < nf; f++) {
    final uHi = bounds[f], uLo = bounds[f + 1];
    final uMid = (uHi + uLo) / 2;
    final reach =
        tb + (1 - tb) * math.pow(rng.nextDouble(), 1.3).toDouble();
    final valley = tb - _uniform(rng, 0.0, 0.08);
    tail.add(at(valley, uHi * 0.97));
    tail.add(at((valley + reach) / 2, uHi - (uHi - uLo) * 0.2));
    tail.add(at(reach, uMid));
    tail.add(at((valley + reach) / 2, uLo + (uHi - uLo) * 0.2));
  }
  tail.add(at(tb - _uniform(rng, 0, 0.04), -0.97));
  final body = <_P>[
    at(-hr * 0.7, 0.6),
    ...left,
    ...tail,
    ...right.reversed,
    at(-hr * 0.7, -0.6),
  ];
  out.add(BrushStroke(
    kind: StrokeKind.fill,
    points: _flat(body),
    width: 0,
    color: _rgb(c),
    opacity: st.opacity,
    layer: layer,
  ));

  if (w < 4) return;

  // --- faint, broken bristle tracks
  if (bristleAmount > 0) {
    final k = math.max(3, math.min(st.streaks, (w / st.streakPx).round()));
    for (var s = 0; s < k; s++) {
      final u = ((s + 0.5) / k * 2 - 1) * 0.85 + _uniform(rng, -0.05, 0.05);
      final t0 = _uniform(rng, 0.02, 0.45);
      final t1 = math.min(0.98, t0 + _uniform(rng, 0.25, 0.7));
      final seg = [for (var q = 0; q < 6; q++) at(t0 + (t1 - t0) * q / 5, u)];
      final v = _gauss(rng) * st.streakContrast * bristleAmount;
      out.add(BrushStroke(
        kind: StrokeKind.line,
        points: _flat(seg),
        width: w / k * _uniform(rng, 0.3, 0.6),
        color: _rgb(v > 0 ? lighter(v) : darker(-v)),
        opacity: _uniform(rng, 0.25, 0.55),
        layer: layer,
      ));
    }
  }

  // --- impasto: short broken ridge highlights + a soft shadow
  if (st.impasto > 0 && w >= 7) {
    const lx = -0.6, ly = -0.8; // light from top-left
    final mid = n ~/ 2;
    final side = nm[mid].x * lx + nm[mid].y * ly > 0 ? 1.0 : -1.0;
    final count = 1 + rng.nextInt(2);
    for (var q = 0; q < count; q++) {
      final t0 = _uniform(rng, 0.05, 0.55);
      final t1 = t0 + _uniform(rng, 0.12, 0.3);
      final u = side * _uniform(rng, 0.45, 0.75);
      out.add(BrushStroke(
        kind: StrokeKind.line,
        points: _flat([for (var r = 0; r < 5; r++) at(t0 + (t1 - t0) * r / 4, u)]),
        width: w * 0.06,
        color: _rgb(lighter(0.4)),
        opacity: 0.38 * st.impasto,
        layer: layer,
      ));
    }
    final t0 = _uniform(rng, 0.1, 0.4);
    final t1 = math.min(tb, t0 + _uniform(rng, 0.25, 0.45));
    out.add(BrushStroke(
      kind: StrokeKind.line,
      points: _flat(
          [for (var r = 0; r < 5; r++) at(t0 + (t1 - t0) * r / 4, -side * 0.8)]),
      width: w * 0.08,
      color: _rgb(darker(0.3)),
      opacity: 0.22 * st.impasto,
      layer: layer,
    ));
  }
}

// ---------------------------------------------------------------- drawing

List<BrushStroke> _sketch(
    _Ctx c, StyleSpec st, ColorMap cmap, PaintSettings s, math.Random rng) {
  final w = c.w, h = c.h, n = w * h;
  final strokes = <BrushStroke>[];
  final darkPaper = lumOf(c.paper) < 0.4;
  final ink = darkPaper ? const [0.95, 0.95, 0.93] : cmap.ink;
  final colored = !darkPaper &&
      (cmap.mode == ColorMode.kleur || cmap.mode == ColorMode.palet);
  final sc = math.max(w, h) / 700.0 * s.brushSize;
  final densityScale = math.sqrt(math.max(0.4, s.detail));

  // tone = how much ink a spot needs (0..1), contrast-stretched
  final toneL = gaussianBlur(c.lum, w, h, 1.5 * sc);
  final tone = Float32List(n);
  for (var i = 0; i < n; i++) {
    tone[i] = darkPaper ? toneL[i] : 1 - toneL[i];
  }
  final lo = percentile(tone, 0.02), hi = percentile(tone, 0.98);
  for (var i = 0; i < n; i++) {
    tone[i] = clamp01((tone[i] - lo) / (hi - lo + 1e-6));
  }
  final col = <Float32List>[
    gaussianBlur(c.r, w, h, 2 * sc),
    gaussianBlur(c.g, w, h, 2 * sc),
    gaussianBlur(c.b, w, h, 2 * sc),
  ];
  final ang = _flow(c, 6 * sc);

  int inkAt(double x, double y, double darken) {
    if (!colored) return _rgb(ink);
    final j = c.idx(x, y);
    final m = cmap([col[0][j], col[1][j], col[2][j]]);
    return _rgb([m[0] * darken, m[1] * darken, m[2] * darken]);
  }

  void addLine(List<_P> pts, double width, int color, double alpha,
      {int layer = 0}) {
    strokes.add(BrushStroke(
      kind: StrokeKind.line,
      points: _flat(pts),
      width: width,
      color: color,
      opacity: alpha,
      layer: layer,
    ));
  }

  double contourAlpha, contourWidth;
  if (st.hatch == HatchKind.cross) {
    // pen & ink: families of parallel lines, more families in darker tones
    final spacing = 4.2 * sc / densityScale;
    const fams = [
      [math.pi / 4, 0.18],
      [-math.pi / 4, 0.38],
      [0.0, 0.58],
      [math.pi / 2, 0.78],
    ];
    final diag = math.sqrt(w * w + h * h.toDouble());
    final cx = w / 2, cy = h / 2;
    final stepL = 1.5 * sc;
    for (final fam in fams) {
      final a = fam[0], thr = fam[1];
      final dx = math.cos(a), dy = math.sin(a);
      final nx = -dy, ny = dx;
      for (var o = -diag / 2 + rng.nextDouble() * spacing;
          o < diag / 2;
          o += spacing) {
        final seg = <_P>[];
        void flush() {
          if (seg.length >= 3) {
            final mid = seg[seg.length ~/ 2];
            addLine([seg.first, seg.last], 0.7 * sc, inkAt(mid.x, mid.y, 0.75),
                0.9);
          }
          seg.clear();
        }

        for (var t = -diag / 2; t < diag / 2; t += stepL) {
          final x = cx + nx * o + dx * t, y = cy + ny * o + dy * t;
          final inside = x >= 0 && x < w && y >= 0 && y < h;
          final on = inside &&
              tone[c.idx(x, y)] > thr + (rng.nextDouble() - 0.5) * 0.04;
          if (on) {
            seg.add(_P(x, y));
          } else if (seg.isNotEmpty) {
            flush();
          }
        }
        flush();
      }
    }
    contourAlpha = 0.9;
    contourWidth = 0.9;
  } else {
    // pencil: short diagonal hatch strokes, density follows tone
    const levels = [
      [0.12, -0.75],
      [0.38, -0.25],
      [0.62, 0.55],
    ];
    final step = 3.6 * sc / densityScale;
    for (final lv in levels) {
      final thr = lv[0], baseA = lv[1];
      for (var y = -rng.nextDouble() * step; y < h; y += step) {
        for (var x = -rng.nextDouble() * step; x < w; x += step) {
          final px = x + (rng.nextDouble() - 0.5) * step;
          final py = y + (rng.nextDouble() - 0.5) * step;
          final t = tone[c.idx(px, py)];
          if (t > thr && rng.nextDouble() < (t - thr) * 2.2) {
            final a = baseA + (rng.nextDouble() - 0.5) * 0.25;
            final ln = (8 + rng.nextDouble() * 10) * sc * s.strokeLength;
            final ddx = math.cos(a) * ln / 2, ddy = math.sin(a) * ln / 2;
            final bend = (rng.nextDouble() - 0.5) * 0.8 * sc;
            addLine(
              [
                _P(px - ddx, py - ddy),
                _P(px - math.sin(a) * bend, py + math.cos(a) * bend),
                _P(px + ddx, py + ddy),
              ],
              (0.55 + rng.nextDouble() * 0.4) * sc,
              inkAt(px, py, 0.7),
              0.22 + 0.3 * t,
            );
          }
        }
      }
    }
    contourAlpha = 0.55;
    contourWidth = 0.8;
  }

  // contour lines along strong edges (both drawing styles)
  final (gx, gy) = sobel(gaussianBlur(c.lum, w, h, 1.0 * sc), w, h);
  final edge = Float32List(n);
  for (var i = 0; i < n; i++) {
    edge[i] = math.sqrt(gx[i] * gx[i] + gy[i] * gy[i]);
  }
  final eNorm = percentile(edge, 0.96) + 1e-6;
  for (var i = 0; i < n; i++) {
    edge[i] = clamp01(edge[i] / eNorm);
  }
  final cStep = 3.0 * sc / densityScale;
  for (var y = -rng.nextDouble() * cStep; y < h; y += cStep) {
    for (var x = -rng.nextDouble() * cStep; x < w; x += cStep) {
      final px = x + (rng.nextDouble() - 0.5) * cStep;
      final py = y + (rng.nextDouble() - 0.5) * cStep;
      final e = edge[c.idx(px, py)];
      if (e > 0.35 && rng.nextDouble() < e) {
        final line = _traceEdge(c, px, py, ang, edge, sc, s.strokeLength);
        if (line.length >= 2) {
          addLine(line, contourWidth * sc * (0.7 + 0.5 * e), inkAt(px, py, 0.6),
              contourAlpha * (0.5 + 0.5 * e),
              layer: 1);
        }
      }
    }
  }
  return strokes;
}

List<_P> _traceEdge(_Ctx c, double x, double y, Float32List ang,
    Float32List edge, double sc, double length) {
  final step = 2.0 * sc;
  final n = (8 * length).toInt() + 2;
  final a0 = ang[c.idx(x, y)];
  final fwd = <_P>[], bwd = <_P>[];
  for (final sgn in const [1.0, -1.0]) {
    final acc = sgn > 0 ? fwd : bwd;
    var cx = x, cy = y;
    var dx = math.cos(a0) * sgn, dy = math.sin(a0) * sgn;
    for (var i = 0; i < n; i++) {
      final a = ang[c.idx(cx, cy)];
      var nx = math.cos(a), ny = math.sin(a);
      if (nx * dx + ny * dy < 0) {
        nx = -nx;
        ny = -ny;
      }
      dx = dx * 0.5 + nx * 0.5;
      dy = dy * 0.5 + ny * 0.5;
      var d = math.sqrt(dx * dx + dy * dy);
      if (d == 0) d = 1;
      dx /= d;
      dy /= d;
      cx += dx * step;
      cy += dy * step;
      if (cx < 0 || cy < 0 || cx >= c.w || cy >= c.h) break;
      if (edge[c.idx(cx, cy)] < 0.2) break;
      acc.add(_P(cx, cy));
    }
  }
  return <_P>[...bwd.reversed, _P(x, y), ...fwd];
}
