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

/// How a single brush stroke is built.
/// * [tapered] – smooth leaf-like polygon (used for watercolour washes)
/// * [flat]    – flat brush: blunt head, bristle texture, impasto ridges and
///               a dry, fingered tail where the paint runs out
enum BrushModel { tapered, flat }

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
    this.brush = BrushModel.tapered,
    this.bodyEnd = const (0.62, 0.82),
    this.headRound = 0.05,
    this.minLength = 1.2,
    this.fingers = 9,
    this.fingerPx = 4.5,
    this.streaks = 14,
    this.streakPx = 2.6,
    this.streakContrast = 0.09,
    this.impasto = 1.0,
    this.drift = 0.06,
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

  // ---- flat brush model ----
  final BrushModel brush;

  /// Where the solid paint stops (fraction of length, random in range);
  /// beyond it only dry "fingers" remain.
  final (double, double) bodyEnd;

  /// 0 = square landing, ~0.2 = round dab.
  final double headRound;

  /// Minimum stroke length in brush widths.
  final double minLength;

  /// Max number of dry fingers in the tail / brush px per finger.
  final int fingers;
  final double fingerPx;

  /// Max bristle tracks / brush px per track / their lightness spread.
  final int streaks;
  final double streakPx;
  final double streakContrast;

  /// Strength of the ridge highlight + shadow (0 = flat paint).
  final double impasto;

  /// Smooth warm/cool + value drift over the canvas.
  final double drift;

  bool get isSketch => kind == StyleKind.sketch;
}

const Map<PaintStyle, StyleSpec> styleSpecs = {
  PaintStyle.olieverf: StyleSpec(
    brush: BrushModel.flat,
    layers: [
      LayerSpec(0.062, 3.2, 0.00),
      LayerSpec(0.036, 3.4, 0.32),
      LayerSpec(0.020, 3.6, 0.42),
      LayerSpec(0.011, 3.2, 0.55),
    ],
    spacing: 0.6,
    opacity: 0.97,
    wobble: 0.05,
    jitter: 0.5,
    vibrance: 1.25,
  ),
  PaintStyle.oliepastel: StyleSpec(
    brush: BrushModel.flat,
    layers: [
      LayerSpec(0.055, 2.6, 0.00),
      LayerSpec(0.032, 2.8, 0.30),
      LayerSpec(0.018, 3.0, 0.40),
      LayerSpec(0.011, 2.6, 0.55),
    ],
    spacing: 0.6,
    angleNoise: 0.45,
    opacity: 0.97,
    wobble: 0.07,
    jitter: 1.0,
    vibrance: 1.45,
    bodyEnd: (0.45, 0.72),
    fingers: 11,
    fingerPx: 3.5,
    streaks: 16,
    streakPx: 2.0,
    streakContrast: 0.15,
    impasto: 0.5,
    drift: 0.08,
  ),
  PaintStyle.impressionisme: StyleSpec(
    brush: BrushModel.flat,
    layers: [
      LayerSpec(0.040, 2.2, 0.00),
      LayerSpec(0.026, 2.2, 0.20),
      LayerSpec(0.016, 2.0, 0.40),
    ],
    spacing: 0.6,
    angleNoise: 0.7,
    opacity: 0.95,
    wobble: 0.05,
    jitter: 1.6,
    vibrance: 1.55,
    bodyEnd: (0.72, 0.92),
    headRound: 0.22,
    minLength: 1.8,
    fingers: 5,
    fingerPx: 6,
    streakContrast: 0.06,
    impasto: 0.6,
    drift: 0.12,
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
    brush: BrushModel.flat,
    layers: [
      LayerSpec(0.050, 4.0, 0.00),
      LayerSpec(0.028, 4.5, 0.30),
      LayerSpec(0.015, 5.0, 0.40),
    ],
    spacing: 0.6,
    mono: true,
    angleNoise: 0.35,
    opacity: 0.72,
    wobble: 0.1,
    jitter: 0.4,
    vibrance: 1.0,
    skipLight: 0.86,
    bodyEnd: (0.4, 0.7),
    fingers: 12,
    fingerPx: 3.0,
    streaks: 16,
    streakPx: 2.0,
    streakContrast: 0.22,
    impasto: 0.0,
    drift: 0.03,
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
