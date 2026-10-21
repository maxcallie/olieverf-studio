/// Painting / drawing styles and colour modes.
///
/// Painterly styles share one engine (layered brush strokes) and differ only
/// in the numbers in their [StyleSpec]. The two drawing styles (pencil, pen)
/// use a line-based generator.

enum PaintStyle {
  olieverf('Olieverf', 'Gladde, lange penseelstreken'),
  oliepastel('Oliepastel', 'Korte, krijterige toetsen'),
  impressionisme('Impressionisme', 'Losse toetsen, levendige kleuren'),
  aquarel('Aquarel', 'Transparante washes op wit papier'),
  pointillisme('Pointillisme', 'Alleen stippen'),
  houtskool('Houtskool', 'Donkere, vegerige streken'),
  potlood('Potlood', 'Schets met arceringen'),
  pen('Pen & inkt', 'Kruisarcering en contouren');

  const PaintStyle(this.label, this.description);
  final String label;
  final String description;

  StyleSpec get spec => styleSpecs[this]!;
}

enum ColorMode {
  kleur('Kleur'),
  zwartwit('Zwart-wit'),
  sepia('Sepia'),
  cyanotypie('Cyanotypie'),
  palet('Beperkt palet');

  const ColorMode(this.label);
  final String label;
}

enum StyleKind { paint, sketch }

enum StrokeShape { stroke, dot }

enum HatchKind { flow, cross }

class LayerSpec {
  const LayerSpec(this.width, this.length, this.threshold);

  /// Brush width as fraction of the long side.
  final double width;

  /// Maximum stroke length in brush widths.
  final double length;

  /// Minimum normalised error before a stroke is placed (0 = cover all).
  final double threshold;
}

class StyleSpec {
  const StyleSpec({
    this.kind = StyleKind.paint,
    this.layers = const [
      LayerSpec(0.060, 3.5, 0.00),
      LayerSpec(0.034, 4.0, 0.30),
      LayerSpec(0.019, 4.5, 0.38),
      LayerSpec(0.010, 4.0, 0.50),
    ],
    this.angleNoise = 0.3,
    this.opacity = 0.92,
    this.baseOpacity,
    this.bristles = 2,
    this.bristleWidth = 0.14,
    this.bristleContrast = 0.15,
    this.bristleAlpha = 0.6,
    this.wobble = 0.25,
    this.taperMin = 0.3,
    this.jitter = 1.0,
    this.vibrance = 1.3,
    this.lighten = 0.0,
    this.outline = 0.0,
    this.skipLight = 1.1,
    this.spacing,
    this.mono = false,
    this.shape = StrokeShape.stroke,
    this.hatch = HatchKind.flow,
    this.paper = 0xECE4D4,
  });

  final StyleKind kind;
  final List<LayerSpec> layers;

  /// Random deviation (radians) from the flow direction.
  final double angleNoise;
  final double opacity;

  /// Opacity of the first layer (defaults to [opacity]).
  final double? baseOpacity;

  /// Bristle lines per stroke, their width (× brush), contrast and alpha.
  final int bristles;
  final double bristleWidth;
  final double bristleContrast;
  final double bristleAlpha;

  /// Edge irregularity and how thin stroke ends get (1 = no taper).
  final double wobble;
  final double taperMin;

  final double jitter;
  final double vibrance;

  /// Mix stroke colour towards the paper (watercolour).
  final double lighten;

  /// Darker edge line width (× brush) on the finest layer; 0 = none.
  final double outline;

  /// Skip strokes whose colour is lighter than this (leave paper).
  final double skipLight;

  /// Seed grid spacing (× brush).
  final double? spacing;

  /// Monochrome tone mapping between ink and paper (charcoal).
  final bool mono;
  final StrokeShape shape;
  final HatchKind hatch;

  /// Default paper colour for this style.
  final int paper;

  bool get isSketch => kind == StyleKind.sketch;
}

const Map<PaintStyle, StyleSpec> styleSpecs = {
  PaintStyle.olieverf: StyleSpec(),
  PaintStyle.oliepastel: StyleSpec(
    layers: [
      LayerSpec(0.055, 2.6, 0.00),
      LayerSpec(0.032, 2.8, 0.30),
      LayerSpec(0.018, 3.0, 0.40),
      LayerSpec(0.011, 2.6, 0.55),
    ],
    angleNoise: 0.45,
    opacity: 0.96,
    bristles: 3,
    bristleWidth: 0.09,
    bristleContrast: 0.17,
    bristleAlpha: 0.7,
    wobble: 0.35,
    taperMin: 0.45,
    jitter: 1.4,
    vibrance: 1.45,
  ),
  PaintStyle.impressionisme: StyleSpec(
    layers: [
      LayerSpec(0.040, 2.2, 0.00),
      LayerSpec(0.026, 2.2, 0.20),
      LayerSpec(0.016, 2.0, 0.40),
    ],
    angleNoise: 0.7,
    opacity: 0.92,
    bristles: 0,
    wobble: 0.25,
    taperMin: 0.55,
    jitter: 1.9,
    vibrance: 1.55,
  ),
  PaintStyle.aquarel: StyleSpec(
    layers: [
      LayerSpec(0.085, 1.7, 0.00),
      LayerSpec(0.048, 1.9, 0.25),
      LayerSpec(0.026, 1.9, 0.40),
      LayerSpec(0.014, 1.7, 0.55),
    ],
    angleNoise: 0.8,
    opacity: 0.3,
    baseOpacity: 0.6,
    bristles: 0,
    wobble: 0.55,
    taperMin: 0.65,
    jitter: 0.9,
    vibrance: 1.4,
    lighten: 0.05,
    outline: 0.03,
    skipLight: 0.9,
    spacing: 0.5,
    paper: 0xFAF8F3,
  ),
  PaintStyle.pointillisme: StyleSpec(
    layers: [
      LayerSpec(0.016, 0, 0.00),
      LayerSpec(0.011, 0, 0.00),
      LayerSpec(0.0075, 0, 0.30),
    ],
    shape: StrokeShape.dot,
    opacity: 0.95,
    bristles: 0,
    jitter: 2.6,
    vibrance: 1.7,
    spacing: 0.6,
    paper: 0xFAF8F3,
  ),
  PaintStyle.houtskool: StyleSpec(
    layers: [
      LayerSpec(0.050, 4.0, 0.00),
      LayerSpec(0.028, 4.5, 0.30),
      LayerSpec(0.015, 5.0, 0.40),
    ],
    mono: true,
    angleNoise: 0.35,
    opacity: 0.7,
    bristles: 3,
    bristleWidth: 0.07,
    bristleContrast: 0.35,
    bristleAlpha: 0.55,
    wobble: 0.5,
    taperMin: 0.25,
    jitter: 0.6,
    vibrance: 1.0,
    skipLight: 0.86,
    paper: 0xECE4D4,
  ),
  PaintStyle.potlood: StyleSpec(
    kind: StyleKind.sketch,
    hatch: HatchKind.flow,
    paper: 0xFAF8F3,
  ),
  PaintStyle.pen: StyleSpec(
    kind: StyleKind.sketch,
    hatch: HatchKind.cross,
    paper: 0xFAF8F3,
  ),
};
