import 'dart:typed_data';

import 'styles.dart';

export 'styles.dart';

/// How a stroke is drawn (on screen and in the SVG):
/// * [fill]    closed polygon, smoothed with quadratic curves
/// * [outline] same smoothed polygon, but only its edge is stroked
/// * [line]    open polyline with a stroke width
/// * [dot]     circle; `points` = [cx, cy], `width` = diameter
enum StrokeKind { fill, outline, line, dot }

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

  /// Line width ([line]/[outline]) or diameter ([dot]).
  final double width;

  /// 0xRRGGBB
  final int color;
  final double opacity;

  /// Which pass produced this stroke (0 = first/coarsest).
  final int layer;

  int get pointCount => points.length ~/ 2;
}

class Painting {
  const Painting({
    required this.width,
    required this.height,
    required this.paperColor,
    required this.strokes,
    this.focusX = 0.5,
    this.focusY = 0.5,
  });

  final int width;
  final int height;

  /// Focal point that was used (0..1, relative to width/height).
  final double focusX;
  final double focusY;

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
    this.style = PaintStyle.olieverf,
    this.colorMode = ColorMode.kleur,
    this.workSize = 700,
    this.brushSize = 1.0,
    this.detail = 1.0,
    this.strokeLength = 1.0,
    this.vibrance = 1.0,
    this.colorJitter = 1.0,
    this.bristles = 1.0,
    this.seed = 7,
    this.paperColor = 0xA86A45,
    this.focus = 0.7,
    this.simplify = 0.6,
    this.temperature = 1.0,
    this.focusX,
    this.focusY,
  });

  final PaintStyle style;
  final ColorMode colorMode;

  /// Long side (in px) of the image the engine analyses.
  final int workSize;

  /// Multiplier for every brush width / line thickness.
  final double brushSize;

  /// Higher = more fine strokes on details.
  final double detail;

  /// Multiplier for maximum stroke length.
  final double strokeLength;

  /// Multiplier on the style's own colour saturation boost.
  final double vibrance;

  /// Multiplier on the style's random colour variation.
  final double colorJitter;

  /// Multiplier on the style's bristle lines (0 = off).
  final double bristles;

  final int seed;
  final int paperColor;

  /// How strongly detail and sharpness concentrate around the focal point
  /// (0 = everything equally detailed).
  final double focus;

  /// Simplify the photo into masses of light/mid/dark before painting.
  final double simplify;

  /// Multiplier on the style's warm-light / cool-shadow shift.
  final double temperature;

  /// Focal point chosen by the user (0..1); null = automatic.
  final double? focusX;
  final double? focusY;

  PaintSettings copyWith({
    PaintStyle? style,
    ColorMode? colorMode,
    int? workSize,
    double? brushSize,
    double? detail,
    double? strokeLength,
    double? vibrance,
    double? colorJitter,
    double? bristles,
    int? seed,
    int? paperColor,
    double? focus,
    double? simplify,
    double? temperature,
    double? focusX,
    double? focusY,
    bool clearFocusPoint = false,
  }) {
    return PaintSettings(
      style: style ?? this.style,
      colorMode: colorMode ?? this.colorMode,
      workSize: workSize ?? this.workSize,
      brushSize: brushSize ?? this.brushSize,
      detail: detail ?? this.detail,
      strokeLength: strokeLength ?? this.strokeLength,
      vibrance: vibrance ?? this.vibrance,
      colorJitter: colorJitter ?? this.colorJitter,
      bristles: bristles ?? this.bristles,
      seed: seed ?? this.seed,
      paperColor: paperColor ?? this.paperColor,
      focus: focus ?? this.focus,
      simplify: simplify ?? this.simplify,
      temperature: temperature ?? this.temperature,
      focusX: clearFocusPoint ? null : (focusX ?? this.focusX),
      focusY: clearFocusPoint ? null : (focusY ?? this.focusY),
    );
  }
}
