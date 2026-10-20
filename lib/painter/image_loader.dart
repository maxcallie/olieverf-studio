import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'models.dart';

/// Decodes an encoded image (jpg/png/heic/webp…) and scales it down so the
/// long side is at most [maxSide]. Returns raw RGBA for the engine plus a
/// [ui.Image] for showing the original.
Future<(SourceImage, ui.Image)> loadSourceImage(
  Uint8List bytes, {
  required int maxSide,
}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final full = frame.image;

  final scale = math.min(1.0, maxSide / math.max(full.width, full.height));
  final tw = math.max(1, (full.width * scale).round());
  final th = math.max(1, (full.height * scale).round());

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    full,
    ui.Rect.fromLTWH(0, 0, full.width.toDouble(), full.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final small = await picture.toImage(tw, th);
  picture.dispose();
  full.dispose();

  final data = await small.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return (SourceImage(tw, th, data!.buffer.asUint8List()), small);
}
