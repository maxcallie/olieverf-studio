import 'dart:typed_data';

/// A filled brush stroke (closed polygon, drawn with smooth quadratic curves)
/// or a thin "bristle" line (open polyline, drawn with a stroke width).
enum StrokeKind { fill, line }

class BrushStroke {
  const BrushStroke({
    required this.kind,
    required this.points,
    required this.width,
    required this.color,
    required this.opacity,
    required this.layer,
  });

  final StrokeKind kind;

  /// Interleaved coordinates: x0, y0, x1, y1, ... in painting space.
  final Float32List points;

  /// Line width; only used for [StrokeKind.line].
  final double width;

  /// 0xRRGGBB
  final int color;
  final double opacity;

  /// Which pass (0 = coarsest brush) produced this stroke.
  final int layer;

  int get pointCount => points.length ~/ 2;
}

class Painting {
  const Painting({
    required this.width,
    required this.height,
    required this.paperColor,
    required this.strokes,
  });

  final int width;
  final int height;

  /// 0xRRGGBB
  final int paperColor;
  final List<BrushStroke> strokes;
}

/// Raw RGBA pixels that the engine works on.
class SourceImage {
  const SourceImage(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

class PaintSettings {
  const PaintSettings({
    this.workSize = 700,
    this.brushSize = 1.0,
    this.detail = 1.0,
    this.strokeLength = 1.0,
    this.vibrance = 1.3,
    this.colorJitter = 1.0,
    this.bristles = 1.0,
    this.seed = 7,
    this.paperColor = 0xECE4D4,
  });

  /// Long side (in px) of the image the engine analyses.
  final int workSize;

  /// Multiplier for every brush width.
  final double brushSize;

  /// Higher = more fine strokes on details.
  final double detail;

  /// Multiplier for maximum stroke length.
  final double strokeLength;

  /// Colour saturation boost (1 = as photo).
  final double vibrance;

  /// Random colour variation per stroke.
  final double colorJitter;

  /// Strength of the light/dark bristle lines inside strokes (0 = off).
  final double bristles;

  final int seed;
  final int paperColor;

  PaintSettings copyWith({
    int? workSize,
    double? brushSize,
    double? detail,
    double? strokeLength,
    double? vibrance,
    double? colorJitter,
    double? bristles,
    int? seed,
    int? paperColor,
  }) {
    return PaintSettings(
      workSize: workSize ?? this.workSize,
      brushSize: brushSize ?? this.brushSize,
      detail: detail ?? this.detail,
      strokeLength: strokeLength ?? this.strokeLength,
      vibrance: vibrance ?? this.vibrance,
      colorJitter: colorJitter ?? this.colorJitter,
      bristles: bristles ?? this.bristles,
      seed: seed ?? this.seed,
      paperColor: paperColor ?? this.paperColor,
    );
  }
}
