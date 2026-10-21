import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'painter/image_loader.dart';
import 'painter/models.dart';
import 'painter/painter_engine.dart';
import 'painter/painting_view.dart';
import 'painter/stroke_render.dart';
import 'painter/svg_export.dart';
import 'save/save.dart';

void main() => runApp(const OlieverfApp());

// Top-level functions so they can run in a background isolate via compute().
Painting _paintJob((SourceImage, PaintSettings) job) =>
    paintPhoto(job.$1, job.$2);
String _svgJob(Painting p) => paintingToSvg(p);

class OlieverfApp extends StatelessWidget {
  const OlieverfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Olieverf Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB4532A),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4EFE6),
      ),
      home: const StudioPage(),
    );
  }
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  PaintSettings _settings = const PaintSettings();
  SourceImage? _source;
  ui.Image? _original;
  Painting? _painting;
  bool _busy = false;
  bool _exporting = false;
  bool _animate = true;
  bool _showOriginal = false;
  int _generation = 0;

  static const _papers = <int, String>{
    0xECE4D4: 'Crème',
    0xFAF8F3: 'Wit',
    0x9C978E: 'Grijs',
    0x23201C: 'Zwart',
  };

  @override
  void dispose() {
    _original?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- actions

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    try {
      final (src, original) =
          await loadSourceImage(bytes, maxSide: _settings.workSize);
      if (!mounted) return;
      _original?.dispose();
      setState(() {
        _source = src;
        _original = original;
        _painting = null;
      });
      await _render();
    } catch (e) {
      _toast('Kon de afbeelding niet openen: $e');
    }
  }

  Future<void> _render() async {
    final src = _source;
    if (src == null) return;
    final gen = ++_generation;
    setState(() => _busy = true);
    // On the web compute() runs on the main thread: give the spinner a frame.
    if (kIsWeb) await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted || gen != _generation) return;
    try {
      final painting = await compute(_paintJob, (src, _settings));
      if (!mounted || gen != _generation) return;
      setState(() {
        _painting = painting;
        _busy = false;
        _showOriginal = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() => _busy = false);
      _toast('Schilderen mislukt: $e');
    }
  }

  /// Changing the paper does not need a new set of strokes.
  void _setPaper(int color) {
    final p = _painting;
    setState(() {
      _settings = _settings.copyWith(paperColor: color);
      if (p != null) {
        _painting = Painting(
          width: p.width,
          height: p.height,
          paperColor: color,
          strokes: p.strokes,
        );
      }
    });
  }

  void _update(PaintSettings s, {bool rerender = false}) {
    setState(() => _settings = s);
    if (rerender) _render();
  }

  Future<void> _exportSvg() async {
    final p = _painting;
    if (p == null) return;
    setState(() => _exporting = true);
    try {
      final svg = await compute(_svgJob, p);
      await _save(Uint8List.fromList(utf8.encode(svg)), 'svg', 'image/svg+xml');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportPng() async {
    final p = _painting;
    if (p == null) return;
    setState(() => _exporting = true);
    try {
      // Mobile browsers limit canvas size, so stay a bit smaller on the web.
      final png = await renderPng(p, longSide: kIsWeb ? 3000 : 4000);
      await _save(png, 'png', 'image/png');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _save(Uint8List bytes, String ext, String mime) async {
    final name = 'schilderij_${DateTime.now().millisecondsSinceEpoch}.$ext';
    try {
      final saved = await saveBytes(bytes, name, mime);
      if (saved != null) _toast('Opgeslagen als $saved');
    } catch (e) {
      _toast('Opslaan mislukt: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Olieverf Studio',
            style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        actions: [
          if (_painting != null) ...[
            IconButton(
              tooltip: 'Exporteer SVG (vector)',
              onPressed: _exporting ? null : _exportSvg,
              icon: const Icon(Icons.timeline),
            ),
            IconButton(
              tooltip: 'Exporteer PNG',
              onPressed: _exporting ? null : _exportPng,
              icon: const Icon(Icons.image_outlined),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 900;
        if (wide) {
          return Row(children: [
            Expanded(child: _buildCanvasArea(zoomable: true)),
            SizedBox(width: 340, child: _buildPanel()),
          ]);
        }
        // Phone: the picture only takes the room it needs (max 45%), and the
        // settings get the rest. No pan/zoom here so swipes never get stuck;
        // tap the picture to open a full-screen zoom view instead.
        final aspect = _aspect;
        final maxH = c.maxHeight * 0.45;
        final h = aspect == null
            ? maxH
            : math.min(maxH, (c.maxWidth - 32) / aspect + 32);
        return Column(children: [
          SizedBox(height: h, child: _buildCanvasArea(zoomable: false)),
          Expanded(child: _buildPanel()),
        ]);
      }),
    );
  }

  double? get _aspect {
    final p = _painting;
    if (p != null) return p.width / p.height;
    final src = _source;
    if (src != null) return src.width / src.height;
    return null;
  }

  void _openZoom() {
    final p = _painting;
    if (p == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => Scaffold(
        backgroundColor: const Color(0xFF1C1A17),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: const Text('Knijp om te zoomen'),
        ),
        body: InteractiveViewer(
          maxScale: 10,
          child: Center(child: PaintingView(painting: p, animate: false)),
        ),
      ),
    ));
  }

  Widget _buildCanvasArea({required bool zoomable}) {
    Widget content;
    final painting = _painting;
    final original = _original;
    if (_source == null) {
      content = _EmptyState(onPick: _pickImage);
    } else if (_showOriginal && original != null) {
      content = AspectRatio(
        aspectRatio: original.width / original.height,
        child: RawImage(image: original, fit: BoxFit.contain),
      );
    } else if (painting != null) {
      final view = RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(40),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ]),
          child: PaintingView(painting: painting, animate: _animate),
        ),
      );
      content = zoomable
          ? InteractiveViewer(maxScale: 8, child: Center(child: view))
          : GestureDetector(
              onTap: _openZoom,
              child: Stack(children: [
                view,
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(110),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.zoom_out_map,
                        size: 18, color: Colors.white),
                  ),
                ),
              ]),
            );
    } else {
      content = const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Stack(alignment: Alignment.center, children: [
        Center(
          child: DecoratedBox(
            decoration: BoxDecoration(boxShadow: [
              if (_source != null && _showOriginal)
                BoxShadow(
                  color: Colors.black.withAlpha(40),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
            ]),
            child: content,
          ),
        ),
        if (_busy)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(170),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              SizedBox(width: 12),
              Text('Penselen worden klaargezet…',
                  style: TextStyle(color: Colors.white)),
            ]),
          ),
      ]),
    );
  }

  Widget _buildPanel() {
    final s = _settings;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(_source == null ? 'Kies een foto' : 'Andere foto'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Opnieuw schilderen (andere streken)',
              onPressed: _source == null || _busy
                  ? null
                  : () => _update(s.copyWith(seed: s.seed + 1), rerender: true),
              icon: const Icon(Icons.casino_outlined),
            ),
          ]),
          if (_source != null) ...[
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Schilderij'), icon: Icon(Icons.brush_outlined)),
                ButtonSegment(value: true, label: Text('Origineel'), icon: Icon(Icons.photo_outlined)),
              ],
              selected: {_showOriginal},
              onSelectionChanged: (v) => setState(() => _showOriginal = v.first),
            ),
          ],
          const SizedBox(height: 16),
          Text('Stijl', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final st in PaintStyle.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: Icon(_styleIcon(st), size: 18),
                    label: Text(st.label),
                    tooltip: st.description,
                    selected: s.style == st,
                    onSelected: (_) => _setStyle(st),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          Text(s.style.description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Text('Kleur', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final cm in ColorMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: _ModeSwatch(mode: cm),
                    label: Text(cm.label),
                    selected: s.colorMode == cm,
                    onSelected: (_) =>
                        _update(s.copyWith(colorMode: cm), rerender: true),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          ..._sliders(s),
          const SizedBox(height: 8),
          Text('Ondergrond', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final e in _papers.entries)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: Color(0xFF000000 | e.key)),
                label: Text(e.value),
                selected: s.paperColor == e.key,
                onSelected: (_) => _setPaper(e.key),
              ),
          ]),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Animeer het schilderen'),
            value: _animate,
            onChanged: (v) => setState(() => _animate = v),
          ),
          if (_painting != null) ...[
            const Divider(height: 24),
            Text(
                '${_painting!.strokes.length} '
                '${s.style.spec.isSketch ? 'lijnen' : 'penseelstreken'}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _exporting ? null : _exportSvg,
                  icon: const Icon(Icons.timeline),
                  label: const Text('SVG'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : _exportPng,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('PNG'),
                ),
              ),
            ]),
            if (_exporting)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ],
      ),
    );
  }

  void _setStyle(PaintStyle st) {
    if (st == _settings.style) return;
    _update(_settings.copyWith(style: st, paperColor: st.spec.paper),
        rerender: true);
  }

  static IconData _styleIcon(PaintStyle st) => switch (st) {
        PaintStyle.olieverf => Icons.brush,
        PaintStyle.oliepastel => Icons.gesture,
        PaintStyle.impressionisme => Icons.blur_on,
        PaintStyle.aquarel => Icons.water_drop_outlined,
        PaintStyle.pointillisme => Icons.grain,
        PaintStyle.houtskool => Icons.whatshot_outlined,
        PaintStyle.potlood => Icons.edit_outlined,
        PaintStyle.pen => Icons.border_color_outlined,
      };

  /// Only the sliders that do something for the current style.
  List<Widget> _sliders(PaintSettings s) {
    final spec = s.style.spec;
    if (spec.isSketch) {
      return [
        _slider('Lijndikte', s.brushSize, 0.5, 2.0,
            (v) => s.copyWith(brushSize: v)),
        _slider('Dichtheid', s.detail, 0.5, 2.5, (v) => s.copyWith(detail: v)),
        _slider('Lijnlengte', s.strokeLength, 0.4, 2.0,
            (v) => s.copyWith(strokeLength: v)),
      ];
    }
    final dots = spec.shape == StrokeShape.dot;
    return [
      _slider(dots ? 'Stipgrootte' : 'Penseelgrootte', s.brushSize, 0.5, 2.0,
          (v) => s.copyWith(brushSize: v)),
      _slider('Detail', s.detail, 0.5, 2.5, (v) => s.copyWith(detail: v)),
      if (!dots)
        _slider('Streeklengte', s.strokeLength, 0.4, 2.0,
            (v) => s.copyWith(strokeLength: v)),
      if (!spec.mono && s.colorMode == ColorMode.kleur)
        _slider('Kleurintensiteit', s.vibrance, 0.5, 1.6,
            (v) => s.copyWith(vibrance: v)),
      _slider('Kleurvariatie', s.colorJitter, 0.0, 2.5,
          (v) => s.copyWith(colorJitter: v)),
      if (spec.bristles > 0 || spec.brush == BrushModel.flat)
        _slider('Penseelharen', s.bristles, 0.0, 2.0,
            (v) => s.copyWith(bristles: v)),
    ];
  }

  Widget _slider(String label, double value, double min, double max,
      PaintSettings Function(double) apply) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: Row(children: [
        SizedBox(
          width: 116,
          child: Text(label, style: theme.textTheme.labelLarge),
        ),
        Expanded(
          child: Slider(
            value: value < min ? min : (value > max ? max : value),
            min: min,
            max: max,
            onChanged: (v) => _update(apply(v)),
            onChangeEnd: (v) => _update(apply(v), rerender: true),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(value.toStringAsFixed(2),
              textAlign: TextAlign.right, style: theme.textTheme.labelSmall),
        ),
      ]),
    );
  }
}

class _ModeSwatch extends StatelessWidget {
  const _ModeSwatch({required this.mode});
  final ColorMode mode;

  @override
  Widget build(BuildContext context) {
    final colors = switch (mode) {
      ColorMode.kleur => const [Color(0xFFD9502B), Color(0xFF3C8D5A), Color(0xFF3F6FD1)],
      ColorMode.zwartwit => const [Color(0xFF111111), Color(0xFF888888), Color(0xFFEEEEEE)],
      ColorMode.sepia => const [Color(0xFF3D2410), Color(0xFF9C7A55), Color(0xFFF5E8CA)],
      ColorMode.cyanotypie => const [Color(0xFF0A2463), Color(0xFF4A78B5), Color(0xFFE0EEFF)],
      ColorMode.palet => const [Color(0xFFE07A5F), Color(0xFF81B29A), Color(0xFFF2CC8F)],
    };
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(colors: [...colors, colors.first]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.colorScheme.outlineVariant, width: 2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.palette_outlined, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Kies een foto', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Hij wordt opnieuw opgebouwd uit penseelstreken: eerst grote, '
            'daarna steeds fijnere. Exporteer het resultaat als SVG.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ]),
      ),
    );
  }
}
