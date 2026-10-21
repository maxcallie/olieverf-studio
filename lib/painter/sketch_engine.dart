import 'dart:math' as math;
import 'dart:typed_data';

import 'color_map.dart';
import 'image_ops.dart';
import 'models.dart';

/// Pencil / pen drawing, the way an illustrator works:
///
///  1. find the **subject** around the focal point (GrabCut-like colour
///     models for subject vs. background) and give it fine detail + a clear
///     outline;
///  2. **lines** from an XDoG filter (fine near the focus, coarse far away),
///     cleaned of specks, thinned to centre lines and drawn as long strokes
///     whose width follows the band thickness;
///  3. **tone**: only real shadows get hatching (lights and mids stay paper),
///     fading out towards the edges of the picture.
///
/// Pure Dart, no Flutter imports.
List<BrushStroke> sketchPhoto(
  Float32List r,
  Float32List g,
  Float32List b,
  int w,
  int h,
  double fx,
  double fy,
  StyleSpec st,
  ColorMap cmap,
  PaintSettings s,
  math.Random rng,
) {
  final n = w * h;
  final longSide = math.max(w, h).toDouble();
  final sc = longSide / 700.0 * s.brushSize;
  final pencil = st.hatch == HatchKind.flow;
  final focus = s.focus;
  final detail = math.max(0.4, s.detail);

  // paper / ink
  final paper = [
    ((s.paperColor >> 16) & 0xFF) / 255.0,
    ((s.paperColor >> 8) & 0xFF) / 255.0,
    (s.paperColor & 0xFF) / 255.0,
  ];
  final darkPaper = lumOf(paper) < 0.4;
  final List<double> ink = darkPaper
      ? const [0.95, 0.95, 0.93]
      : (cmap.mode == ColorMode.kleur || cmap.mode == ColorMode.palet
          ? (pencil ? const [0.22, 0.21, 0.20] : const [0.06, 0.06, 0.07])
          : cmap.ink);
  final colored = !darkPaper &&
      (cmap.mode == ColorMode.kleur || cmap.mode == ColorMode.palet) &&
      s.colorJitter > 1.2; // "Kleurvariatie" up = coloured pencil

  // raw focus weight (1 at the focal point)
  final fRaw = Float32List(n);
  final sig2 = 2 * (0.3 * longSide) * (0.3 * longSide);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - fx, dy = y - fy;
      fRaw[y * w + x] = math.exp(-(dx * dx + dy * dy) / sig2);
    }
  }
  final near = Float32List(n);
  for (var i = 0; i < n; i++) {
    near[i] = focus > 0 ? fRaw[i] * fRaw[i] : 1.0;
  }

  // 1. subject
  Uint8List? subj;
  if (focus > 0) {
    subj = subjectMask(r, g, b, w, h, fx, fy, rng);
    final soft = Float32List(n);
    for (var i = 0; i < n; i++) {
      soft[i] = subj[i].toDouble();
    }
    final ss = gaussianBlur(soft, w, h, 2.0 * sc);
    for (var i = 0; i < n; i++) {
      near[i] = math.max(near[i], clamp01(ss[i] * 1.2));
      fRaw[i] = math.max(fRaw[i], ss[i]);
    }
  }

  // simplified background, real detail at the subject
  final k1 = kuwahara(r, g, b, w, h, math.max(1, (longSide * 0.005).round()));
  final k2 = kuwahara(
      k1.$1, k1.$2, k1.$3, w, h, math.max(2, (longSide * 0.012).round()));
  final simp = s.simplify;
  final src = Float32List(n);
  for (var i = 0; i < n; i++) {
    final bl = 0.299 * (k1.$1[i] + (k2.$1[i] - k1.$1[i]) * simp) +
        0.587 * (k1.$2[i] + (k2.$2[i] - k1.$2[i]) * simp) +
        0.114 * (k1.$3[i] + (k2.$3[i] - k1.$3[i]) * simp);
    final il = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
    src[i] = bl * (1 - near[i]) + il * near[i];
  }

  final strokes = <BrushStroke>[];
  int inkAt(double x, double y, double darken) {
    if (!colored) return _rgb(ink);
    final j = _idx(x, y, w, h);
    final m = cmap([r[j], g[j], b[j]]);
    return _rgb([m[0] * darken, m[1] * darken, m[2] * darken]);
  }

  void line(List<double> pts, double width, int color, double alpha,
      int layer) {
    strokes.add(BrushStroke(
      kind: StrokeKind.line,
      points: Float32List.fromList(pts),
      width: width,
      color: color,
      opacity: alpha,
      layer: layer,
    ));
  }

  // 3. tone hatching (drawn first, lines on top)
  final t = gaussianBlur(src, w, h, 1.2 * sc);
  for (var i = 0; i < n; i++) {
    t[i] = darkPaper ? t[i] : 1 - t[i];
  }
  final lo = percentile(t, 0.55), hi = percentile(t, 0.995);
  final tone = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = math.pow(clamp01((t[i] - lo) / (hi - lo + 1e-6)), 1.3).toDouble();
    final vig = _smoothstep(0.05, 0.65, fRaw[i]);
    tone[i] = v * (1 - focus * (1 - math.pow(vig, 1.3).toDouble()));
  }
  final fams = pencil
      ? const [
          [-0.96, 0.12, 1.0],
          [0.61, 0.45, 1.15],
          [-1.40, 0.72, 1.3],
        ]
      : const [
          [-0.785, 0.15, 1.0],
          [0.785, 0.42, 1.0],
          [0.0, 0.66, 1.0],
        ];
  final diag = math.sqrt((w * w + h * h).toDouble());
  final cx = w / 2, cy = h / 2;
  final stp = 1.2 * sc;
  for (final fam in fams) {
    final ang = fam[0], thr = fam[1], spf = fam[2];
    final dx = math.cos(ang), dy = math.sin(ang);
    final nx = -dy, ny = dx;
    final sp = (pencil ? 3.6 : 4.0) * sc * spf / math.sqrt(detail);
    for (var o = -diag / 2 + rng.nextDouble() * sp; o < diag / 2; o += sp) {
      final run = <double>[];
      for (var tt = -diag / 2; tt <= diag / 2 + stp; tt += stp) {
        final x = cx + nx * o + dx * tt, y = cy + ny * o + dy * tt;
        final last = tt + stp > diag / 2;
        final on = !last &&
            x >= 0 &&
            x < w &&
            y >= 0 &&
            y < h &&
            tone[_idx(x, y, w, h)] > thr + (rng.nextDouble() - 0.5) * 0.06;
        if (on) {
          run
            ..add(x)
            ..add(y);
        }
        if ((!on) && run.length >= 6) {
          final m = run.length ~/ 2;
          var i = 0;
          while (i < m - 2) {
            final len = pencil
                ? math.max(2, ((12 + rng.nextDouble() * 14) * sc / stp).toInt())
                : 1 << 30;
            final j = math.min(m - 1, i + len);
            if (j - i >= 3) {
              final ax = run[2 * i], ay = run[2 * i + 1];
              final bx = run[2 * j], by = run[2 * j + 1];
              final mid = (i + j) ~/ 2;
              final tv = tone[_idx(run[2 * mid], run[2 * mid + 1], w, h)];
              final col = inkAt(run[2 * mid], run[2 * mid + 1], 0.7);
              if (pencil) {
                final jit = (rng.nextDouble() - 0.5) * 0.8 * sc;
                final bend = (rng.nextDouble() - 0.5) * 1.2 * sc;
                final p0x = ax + nx * jit, p0y = ay + ny * jit;
                final p2x = bx + nx * jit * 0.5, p2y = by + ny * jit * 0.5;
                line([
                  p0x,
                  p0y,
                  (p0x + p2x) / 2 + nx * bend,
                  (p0y + p2y) / 2 + ny * bend,
                  p2x,
                  p2y,
                ], (0.45 + 0.3 * rng.nextDouble()) * sc, col, 0.2 + 0.45 * tv, 0);
              } else {
                line([ax, ay, bx, by], 0.6 * sc, col, 0.9, 0);
              }
            }
            i = j +
                (pencil ? ((2 + rng.nextDouble() * 3) * sc / stp).toInt() : 1);
          }
        }
        if (!on) run.clear();
      }
    }
  }

  // 2. lines: XDoG → cleaned mask → centre lines
  final gf1 = gaussianBlur(src, w, h, 1.5 * sc);
  final gf2 = gaussianBlur(src, w, h, 1.5 * sc * 1.6);
  final gc1 = gaussianBlur(src, w, h, 2.8 * sc);
  final gc2 = gaussianBlur(src, w, h, 2.8 * sc * 1.6);
  final dRaw = Float32List(n);
  for (var i = 0; i < n; i++) {
    final df = gf1[i] - 0.98 * gf2[i], dc = gc1[i] - 0.98 * gc2[i];
    dRaw[i] = darkPaper
        ? -(df * near[i] + dc * (1 - near[i]))
        : df * near[i] + dc * (1 - near[i]);
  }
  final dd = gaussianBlur(dRaw, w, h, 0.7 * sc);
  final mask = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final eps = -0.006 - 0.022 * (1 - fRaw[i]) * focus / detail;
    mask[i] = dd[i] < eps ? 1 : 0;
  }
  _cleanLineMask(mask, w, h, fRaw, src, focus, sc);
  final dist = chamferDistance(mask, w, h);
  final skel = thin(mask, w, h);
  for (final ch in pixelChains(skel, w, h, math.max(3, (3 * sc).toInt()))) {
    final sm = smoothChain(ch, 2);
    if (sm.length < 4) continue;
    final piece = math.max(6, (14 * sc).toInt());
    final np = sm.length ~/ 2;
    for (var k = 0; k < np - 1; k += piece) {
      final end = math.min(np - 1, k + piece);
      if (end - k < 1) continue;
      final seg = sm.sublist(2 * k, 2 * end + 2);
      final mid = (k + end) ~/ 2;
      final mx = sm[2 * mid], my = sm[2 * mid + 1];
      final j = _idx(mx, my, w, h);
      final th = dist[j];
      final fr = fRaw[j];
      final dk = darkPaper ? src[j] : 1 - src[j];
      final wdt = math.min(1.9 * sc,
          math.max(0.4 * sc, 0.35 * sc + th * 0.45 + 0.5 * dk * sc));
      final a = pencil ? 0.5 + 0.45 * fr : 0.95;
      final col = inkAt(mx, my, 0.6);
      line(seg, wdt, col, a, 1);
      if (pencil && rng.nextDouble() < 0.35) {
        final off = (rng.nextDouble() - 0.5) * 1.0 * sc;
        final seg2 = List<double>.generate(
            seg.length, (q) => seg[q] + (q.isEven ? off : off * 0.4));
        line(seg2, wdt * 0.5, col, a * 0.35, 1);
      }
    }
  }

  // 1b. subject outline, only where the photo has an edge as well
  if (subj != null) {
    final gm = Float32List(n);
    for (final ch in [r, g, b]) {
      final (gx, gy) = sobel(gaussianBlur(ch, w, h, 1.2 * sc), w, h);
      for (var i = 0; i < n; i++) {
        gm[i] += gx[i] * gx[i] + gy[i] * gy[i];
      }
    }
    for (var i = 0; i < n; i++) {
      gm[i] = math.sqrt(gm[i]);
    }
    final gnorm = percentile(gm, 0.95) + 1e-6;
    // 1-px boundary of the (smoothed) subject mask
    final edge = Uint8List(n);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        if (subj[i] == 0) continue;
        if (subj[i - 1] == 0 ||
            subj[i + 1] == 0 ||
            subj[i - w] == 0 ||
            subj[i + w] == 0) {
          if (gm[i] / gnorm > 0.12) edge[i] = 1;
        }
      }
    }
    for (final ch in pixelChains(edge, w, h, 4)) {
      final sm = smoothChain(ch, 1);
      final np = sm.length ~/ 2;
      final piece = math.max(6, (16 * sc).toInt());
      for (var k = 0; k < np - 1; k += piece) {
        final end = math.min(np - 1, k + piece);
        if (end - k < 1) continue;
        final seg = sm.sublist(2 * k, 2 * end + 2);
        final mid = (k + end) ~/ 2;
        final gv = gm[_idx(sm[2 * mid], sm[2 * mid + 1], w, h)] / gnorm;
        final wdt = math.min(2.0 * sc, math.max(0.8 * sc, (0.8 + 0.6 * gv) * sc));
        line(seg, wdt, inkAt(sm[2 * mid], sm[2 * mid + 1], 0.6),
            pencil ? 0.85 : 1.0, 2);
      }
    }
  }
  return strokes;
}

// ------------------------------------------------------------------ helpers

int _idx(double x, double y, int w, int h) {
  var xi = x.toInt(), yi = y.toInt();
  if (xi < 0) xi = 0;
  if (xi >= w) xi = w - 1;
  if (yi < 0) yi = 0;
  if (yi >= h) yi = h - 1;
  return yi * w + xi;
}

int _rgb(List<double> c) {
  int ch(double v) => (clamp01(v) * 255).round();
  return (ch(c[0]) << 16) | (ch(c[1]) << 8) | ch(c[2]);
}

double _smoothstep(double a, double b, double x) {
  final t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
}

/// 8-connected component labelling. Returns labels (0 = background) and the
/// size of every label.
(Int32List, List<int>) components(Uint8List mask, int w, int h) {
  final lab = Int32List(w * h);
  final sizes = <int>[0];
  final stack = <int>[];
  var cur = 0;
  for (var start = 0; start < w * h; start++) {
    if (mask[start] == 0 || lab[start] != 0) continue;
    cur++;
    var count = 0;
    lab[start] = cur;
    stack.add(start);
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      count++;
      final py = p ~/ w, px = p - py * w;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = py + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = px + dx;
          if (xx < 0 || xx >= w) continue;
          final q = yy * w + xx;
          if (mask[q] != 0 && lab[q] == 0) {
            lab[q] = cur;
            stack.add(q);
          }
        }
      }
    }
    sizes.add(count);
  }
  return (lab, sizes);
}

/// Keeps line-like components and dark spots; far from the focus only big
/// ones survive.
void _cleanLineMask(Uint8List mask, int w, int h, Float32List fRaw,
    Float32List src, double focus, double sc) {
  final (lab, sizes) = components(mask, w, h);
  final k = sizes.length;
  if (k <= 1) return;
  final fsum = Float64List(k), lsum = Float64List(k);
  final x0 = List<int>.filled(k, 1 << 30), x1 = List<int>.filled(k, -1);
  final y0 = List<int>.filled(k, 1 << 30), y1 = List<int>.filled(k, -1);
  for (var i = 0; i < w * h; i++) {
    final id = lab[i];
    if (id == 0) continue;
    final y = i ~/ w, x = i - y * w;
    fsum[id] += fRaw[i];
    lsum[id] += src[i];
    if (x < x0[id]) x0[id] = x;
    if (x > x1[id]) x1[id] = x;
    if (y < y0[id]) y0[id] = y;
    if (y > y1[id]) y1[id] = y;
  }
  final keep = List<bool>.filled(k, false);
  for (var id = 1; id < k; id++) {
    final sz = sizes[id];
    final fm = fsum[id] / sz, lm = lsum[id] / sz;
    final bw = x1[id] - x0[id] + 1, bh = y1[id] - y0[id] + 1;
    final elong = (bw * bw + bh * bh) / sz;
    final bigEnough = sz >= (6 + 100 * (1 - fm) * focus) * sc * sc;
    final lineLike = elong > 7;
    final darkSpot = lm < 0.28 && sz >= 4 * sc * sc;
    keep[id] = bigEnough && (lineLike || darkSpot || sz > 400 * sc * sc);
  }
  for (var i = 0; i < w * h; i++) {
    mask[i] = keep[lab[i]] ? 1 : 0;
  }
}

/// Two-pass chamfer distance (px) to the nearest background pixel.
Float32List chamferDistance(Uint8List mask, int w, int h) {
  const inf = 1e9;
  final d = Float32List(w * h);
  for (var i = 0; i < w * h; i++) {
    d[i] = mask[i] != 0 ? inf : 0;
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (d[i] == 0) continue;
      var v = d[i];
      if (y > 0) {
        v = math.min(v, d[i - w] + 1);
        if (x > 0) v = math.min(v, d[i - w - 1] + 1.414);
        if (x < w - 1) v = math.min(v, d[i - w + 1] + 1.414);
      }
      if (x > 0) v = math.min(v, d[i - 1] + 1);
      d[i] = v;
    }
  }
  for (var y = h - 1; y >= 0; y--) {
    for (var x = w - 1; x >= 0; x--) {
      final i = y * w + x;
      if (d[i] == 0) continue;
      var v = d[i];
      if (y < h - 1) {
        v = math.min(v, d[i + w] + 1);
        if (x > 0) v = math.min(v, d[i + w - 1] + 1.414);
        if (x < w - 1) v = math.min(v, d[i + w + 1] + 1.414);
      }
      if (x < w - 1) v = math.min(v, d[i + 1] + 1);
      d[i] = v;
    }
  }
  return d;
}

/// Zhang–Suen thinning to 1-px centre lines.
Uint8List thin(Uint8List mask, int w, int h) {
  final m = Uint8List.fromList(mask);
  final rem = <int>[];
  var changed = true;
  int at(int x, int y) =>
      (x < 0 || y < 0 || x >= w || y >= h) ? 0 : m[y * w + x];
  while (changed) {
    changed = false;
    for (var step = 0; step < 2; step++) {
      rem.clear();
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (m[y * w + x] == 0) continue;
          final p2 = at(x, y - 1), p3 = at(x + 1, y - 1), p4 = at(x + 1, y);
          final p5 = at(x + 1, y + 1), p6 = at(x, y + 1), p7 = at(x - 1, y + 1);
          final p8 = at(x - 1, y), p9 = at(x - 1, y - 1);
          final bsum = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
          if (bsum < 2 || bsum > 6) continue;
          final seq = [p2, p3, p4, p5, p6, p7, p8, p9, p2];
          var a = 0;
          for (var i = 0; i < 8; i++) {
            if (seq[i] == 0 && seq[i + 1] == 1) a++;
          }
          if (a != 1) continue;
          final ok = step == 0
              ? (p2 * p4 * p6 == 0 && p4 * p6 * p8 == 0)
              : (p2 * p4 * p8 == 0 && p2 * p6 * p8 == 0);
          if (ok) rem.add(y * w + x);
        }
      }
      if (rem.isNotEmpty) {
        changed = true;
        for (final i in rem) {
          m[i] = 0;
        }
      }
    }
  }
  return m;
}

const _nb = [
  [-1, -1], [-1, 0], [-1, 1], [0, 1], [1, 1], [1, 0], [1, -1], [0, -1], //
];

/// Follows 1-px lines into polylines (interleaved x,y), endpoints first.
List<List<double>> pixelChains(Uint8List edge, int w, int h, int minLen) {
  final left = Uint8List.fromList(edge);
  int deg(int x, int y) {
    var d = 0;
    for (final o in _nb) {
      final yy = y + o[0], xx = x + o[1];
      if (yy >= 0 && yy < h && xx >= 0 && xx < w && edge[yy * w + xx] != 0) d++;
    }
    return d;
  }

  final starts = <int>[], others = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (edge[i] == 0) continue;
    final y = i ~/ w, x = i - y * w;
    (deg(x, y) == 1 ? starts : others).add(i);
  }
  final out = <List<double>>[];
  for (final p in [...starts, ...others]) {
    if (left[p] == 0) continue;
    left[p] = 0;
    var cy = p ~/ w, cx = p - cy * w;
    final ch = <double>[cx + 0.5, cy + 0.5];
    var pdx = 0, pdy = 0;
    while (true) {
      var best = -1;
      var bestScore = -1e9;
      for (final o in _nb) {
        final yy = cy + o[0], xx = cx + o[1];
        if (yy < 0 || yy >= h || xx < 0 || xx >= w) continue;
        if (left[yy * w + xx] == 0) continue;
        final score = (o[1] * pdx + o[0] * pdy).toDouble();
        if (score > bestScore) {
          bestScore = score;
          best = yy * w + xx;
        }
      }
      if (best < 0) break;
      final ny = best ~/ w, nx = best - ny * w;
      pdx = nx - cx;
      pdy = ny - cy;
      cx = nx;
      cy = ny;
      left[best] = 0;
      ch
        ..add(cx + 0.5)
        ..add(cy + 0.5);
    }
    if (ch.length ~/ 2 >= minLen) out.add(ch);
  }
  return out;
}

/// Subsample every [step] points, then two Chaikin passes.
List<double> smoothChain(List<double> c, int step) {
  final n = c.length ~/ 2;
  var p = <double>[];
  for (var i = 0; i < n; i += step) {
    p
      ..add(c[2 * i])
      ..add(c[2 * i + 1]);
  }
  if ((n - 1) % step != 0) {
    p
      ..add(c[2 * (n - 1)])
      ..add(c[2 * (n - 1) + 1]);
  }
  for (var it = 0; it < 2; it++) {
    final m = p.length ~/ 2;
    if (m < 3) break;
    final q = <double>[p[0], p[1]];
    for (var i = 0; i < m - 1; i++) {
      final ax = p[2 * i], ay = p[2 * i + 1];
      final bx = p[2 * i + 2], by = p[2 * i + 3];
      q
        ..add(0.75 * ax + 0.25 * bx)
        ..add(0.75 * ay + 0.25 * by)
        ..add(0.25 * ax + 0.75 * bx)
        ..add(0.25 * ay + 0.75 * by);
    }
    q
      ..add(p[2 * (m - 1)])
      ..add(p[2 * (m - 1) + 1]);
    p = q;
  }
  return p;
}

// ------------------------------------------------------------------ subject

class _Gmm {
  _Gmm(this.c, this.v, this.wt);
  final List<List<double>> c;
  final List<double> v, wt;

  /// negative log-likelihood (isotropic Gaussians)
  double nll(double l, double a, double b) {
    var m = -double.infinity;
    final ll = List<double>.filled(c.length, 0);
    for (var k = 0; k < c.length; k++) {
      final d = (l - c[k][0]) * (l - c[k][0]) +
          (a - c[k][1]) * (a - c[k][1]) +
          (b - c[k][2]) * (b - c[k][2]);
      ll[k] = math.log(wt[k] + 1e-6) - 1.5 * math.log(v[k]) - d / (2 * v[k]);
      if (ll[k] > m) m = ll[k];
    }
    var s = 0.0;
    for (final x in ll) {
      s += math.exp(x - m);
    }
    return -(m + math.log(s));
  }
}

_Gmm _fit(List<List<double>> x, int k, math.Random rng) {
  final cent = List<List<double>>.generate(
      k, (_) => List<double>.of(x[rng.nextInt(x.length)]));
  final lab = List<int>.filled(x.length, 0);
  for (var it = 0; it < 8; it++) {
    for (var i = 0; i < x.length; i++) {
      var best = 0;
      var bd = double.infinity;
      for (var j = 0; j < k; j++) {
        final d = (x[i][0] - cent[j][0]) * (x[i][0] - cent[j][0]) +
            (x[i][1] - cent[j][1]) * (x[i][1] - cent[j][1]) +
            (x[i][2] - cent[j][2]) * (x[i][2] - cent[j][2]);
        if (d < bd) {
          bd = d;
          best = j;
        }
      }
      lab[i] = best;
    }
    for (var j = 0; j < k; j++) {
      var s0 = 0.0, s1 = 0.0, s2 = 0.0;
      var cnt = 0;
      for (var i = 0; i < x.length; i++) {
        if (lab[i] != j) continue;
        s0 += x[i][0];
        s1 += x[i][1];
        s2 += x[i][2];
        cnt++;
      }
      if (cnt > 0) cent[j] = [s0 / cnt, s1 / cnt, s2 / cnt];
    }
  }
  final v = List<double>.filled(k, 1.0), wt = List<double>.filled(k, 0.0);
  for (var j = 0; j < k; j++) {
    var s = 0.0;
    var cnt = 0;
    for (var i = 0; i < x.length; i++) {
      if (lab[i] != j) continue;
      s += (x[i][0] - cent[j][0]) * (x[i][0] - cent[j][0]) +
          (x[i][1] - cent[j][1]) * (x[i][1] - cent[j][1]) +
          (x[i][2] - cent[j][2]) * (x[i][2] - cent[j][2]);
      cnt++;
    }
    v[j] = cnt > 0 ? math.max(1e-3, s / cnt / 3) : 1.0;
    wt[j] = cnt / x.length;
  }
  return _Gmm(cent, v, wt);
}

/// Subject segmentation around the focal point: colour models for subject
/// and background (opponent colour space), compared and refined 3×, with a
/// spatial prior, thin-bridge removal and gap closing.
Uint8List subjectMask(Float32List r0, Float32List g0, Float32List b0, int w,
    int h, double fx, double fy, math.Random rng) {
  final n = w * h;
  final longSide = math.max(w, h).toDouble();
  final (r, g, b) =
      kuwahara(r0, g0, b0, w, h, math.max(1, (longSide * 0.005).round()));
  final cl = Float32List(n), ca = Float32List(n), cb = Float32List(n);
  final dsp = Float32List(n);
  for (var i = 0; i < n; i++) {
    cl[i] = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
    ca[i] = (r[i] - g[i]) * 1.6;
    cb[i] = (0.5 * (r[i] + g[i]) - b[i]) * 1.6;
    final y = i ~/ w, x = i - y * w;
    dsp[i] = math.sqrt((x - fx) * (x - fx) + (y - fy) * (y - fy)) / longSide;
  }
  var fg = Uint8List(n), bg = Uint8List(n);
  for (var i = 0; i < n; i++) {
    fg[i] = dsp[i] < 0.06 ? 1 : 0;
    bg[i] = dsp[i] > 0.38 ? 1 : 0;
  }
  final er = math.max(2.0, longSide * 0.005);
  final fi = _idx(fx, fy, w, h);

  Float32List blurMask(Uint8List m, double sig) {
    final f = Float32List(n);
    for (var i = 0; i < n; i++) {
      f[i] = m[i].toDouble();
    }
    return gaussianBlur(f, w, h, sig);
  }

  for (var it = 0; it < 3; it++) {
    final fs = <List<double>>[], bs = <List<double>>[];
    for (var y = 0; y < h; y += 3) {
      for (var x = 0; x < w; x += 3) {
        final i = y * w + x;
        if (fg[i] != 0) fs.add([cl[i], ca[i], cb[i]]);
        if (bg[i] != 0) bs.add([cl[i], ca[i], cb[i]]);
      }
    }
    if (fs.length < 8 || bs.length < 12) break;
    final mf = _fit(fs, 4, rng), mb = _fit(bs, 6, rng);
    final e = Float32List(n);
    for (var i = 0; i < n; i++) {
      final sp = math.max(0.0, dsp[i] - 0.2);
      e[i] = mf.nll(cl[i], ca[i], cb[i]) -
          mb.nll(cl[i], ca[i], cb[i]) +
          250 * sp * sp -
          0.5;
    }
    final es = gaussianBlur(e, w, h, 1.2);
    final m = Uint8List(n);
    for (var i = 0; i < n; i++) {
      m[i] = es[i] < 0 ? 1 : 0;
    }
    // erode (cut thin bridges)
    final eroded = blurMask(m, er);
    for (var i = 0; i < n; i++) {
      m[i] = eroded[i] > 0.6 ? 1 : 0;
    }
    final (lab, sizes) = components(m, w, h);
    final k = sizes.length;
    final dmin = List<double>.filled(k, 1e9);
    for (var i = 0; i < n; i++) {
      final id = lab[i];
      if (id != 0 && dsp[i] < dmin[id]) dmin[id] = dsp[i];
    }
    final keep = List<bool>.filled(k, false);
    var any = false;
    for (var id = 1; id < k; id++) {
      keep[id] = sizes[id] > 0.002 * n && dmin[id] < 0.25;
      any = any || keep[id];
    }
    if (lab[fi] != 0) {
      keep[lab[fi]] = true;
      any = true;
    }
    if (!any) break;
    for (var i = 0; i < n; i++) {
      m[i] = keep[lab[i]] ? 1 : 0;
    }
    // dilate + bridge small gaps, smooth
    var f = blurMask(m, er * 3);
    for (var i = 0; i < n; i++) {
      m[i] = f[i] > 0.3 ? 1 : 0;
    }
    f = blurMask(m, er * 1.5);
    for (var i = 0; i < n; i++) {
      m[i] = f[i] > 0.5 ? 1 : 0;
    }
    fg = m;
    final grown = blurMask(m, er * 4);
    bg = Uint8List(n);
    for (var i = 0; i < n; i++) {
      bg[i] = grown[i] > 0.02 ? 0 : 1;
    }
  }
  return fg;
}
