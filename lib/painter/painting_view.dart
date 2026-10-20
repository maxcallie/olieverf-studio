import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'models.dart';
import 'stroke_render.dart';

/// Shows a [Painting] and (optionally) animates it stroke by stroke, coarse
/// brushes first – like the painter in the video.
///
/// While animating, finished strokes are baked into a bitmap cache so each
/// frame only draws the new strokes. When done, the view switches to a vector
/// [ui.Picture], so zooming stays sharp.
class PaintingView extends StatefulWidget {
  const PaintingView({
    super.key,
    required this.painting,
    this.animate = true,
    this.duration = const Duration(seconds: 6),
    this.onFinished,
  });

  final Painting painting;
  final bool animate;
  final Duration duration;
  final VoidCallback? onFinished;

  @override
  State<PaintingView> createState() => _PaintingViewState();
}

class _PaintingViewState extends State<PaintingView>
    with SingleTickerProviderStateMixin {
  static const double _cacheScale = 2.0;

  late final Ticker _ticker;
  ui.Image? _cache;
  ui.Picture? _full;
  int _drawn = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _restart();
  }

  @override
  void didUpdateWidget(PaintingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.painting.strokes, widget.painting.strokes)) {
      _restart();
    } else if (!identical(oldWidget.painting, widget.painting) &&
        _full != null) {
      // Same strokes, other paper colour: just re-record, no replay.
      _full!.dispose();
      _full = recordPainting(widget.painting);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _cache?.dispose();
    _full?.dispose();
    super.dispose();
  }

  /// Resets state. Never calls setState (it is used from initState too).
  void _restart() {
    if (_ticker.isActive) _ticker.stop();
    _cache?.dispose();
    _cache = null;
    _full?.dispose();
    _full = null;
    _drawn = 0;
    if (widget.animate && widget.painting.strokes.isNotEmpty) {
      _ticker.start();
    } else {
      _complete(notify: false);
    }
  }

  void _onTick(Duration elapsed) {
    final p = widget.painting;
    final total = p.strokes.length;
    final t = elapsed.inMicroseconds /
        math.max(1, widget.duration.inMicroseconds);
    // ease-in: big strokes go slowly, the many small strokes fly by
    final target = math.min(total, (total * t * t).ceil() + 1);
    if (target <= _drawn) return;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final cache = _cache;
    if (cache == null) {
      canvas.scale(_cacheScale);
      drawPaper(canvas, p);
    } else {
      canvas.drawImage(cache, ui.Offset.zero, ui.Paint());
      canvas.scale(_cacheScale);
    }
    drawStrokes(canvas, p, _drawn, target);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (p.width * _cacheScale).round(),
      (p.height * _cacheScale).round(),
    );
    picture.dispose();
    _cache?.dispose();
    _cache = image;
    _drawn = target;

    if (_drawn >= total) {
      _complete(notify: true);
    } else {
      setState(() {});
    }
  }

  void _complete({required bool notify}) {
    if (_ticker.isActive) _ticker.stop();
    _full = recordPainting(widget.painting);
    _drawn = widget.painting.strokes.length;
    if (notify) {
      setState(() {});
      widget.onFinished?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.painting;
    return AspectRatio(
      aspectRatio: p.width / p.height,
      child: CustomPaint(
        painter: _ViewPainter(p, _cache, _full),
        isComplex: true,
      ),
    );
  }
}

class _ViewPainter extends CustomPainter {
  _ViewPainter(this.painting, this.cache, this.full);

  final Painting painting;
  final ui.Image? cache;
  final ui.Picture? full;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.save();
    canvas.clipRect(ui.Offset.zero & size);
    canvas.scale(size.width / painting.width, size.height / painting.height);
    final f = full;
    final c = cache;
    if (f != null) {
      canvas.drawPicture(f);
    } else if (c != null) {
      canvas.drawImageRect(
        c,
        ui.Rect.fromLTWH(0, 0, c.width.toDouble(), c.height.toDouble()),
        ui.Rect.fromLTWH(
            0, 0, painting.width.toDouble(), painting.height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
    } else {
      drawPaper(canvas, painting);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ViewPainter old) =>
      !identical(old.painting, painting) ||
      !identical(old.cache, cache) ||
      !identical(old.full, full);
}
