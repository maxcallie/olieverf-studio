import 'dart:convert';
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
        final canvas = _buildCanvasArea();
        final panel = _buildPanel();
        if (wide) {
          return Row(children: [
            Expanded(child: canvas),
            SizedBox(width: 340, child: panel),
          ]);
        }
        return Column(children: [
          Expanded(child: canvas),
          SizedBox(height: c.maxHeight * 0.42, child: panel),
        ]);
      }),
    );
  }

  Widget _buildCanvasArea() {
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
      content = InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: RepaintBoundary(
            child: PaintingView(painting: painting, animate: _animate),
          ),
        ),
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
              if (_source != null)
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
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
          _slider('Penseelgrootte', s.brushSize, 0.5, 2.0,
              (v) => s.copyWith(brushSize: v)),
          _slider('Detail', s.detail, 0.5, 2.5, (v) => s.copyWith(detail: v)),
          _slider('Streeklengte', s.strokeLength, 0.4, 2.0,
              (v) => s.copyWith(strokeLength: v)),
          _slider('Kleurintensiteit', s.vibrance, 0.7, 2.0,
              (v) => s.copyWith(vibrance: v)),
          _slider('Kleurvariatie', s.colorJitter, 0.0, 2.5,
              (v) => s.copyWith(colorJitter: v)),
          _slider('Penseelharen', s.bristles, 0.0, 2.0,
              (v) => s.copyWith(bristles: v)),
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
            Text('${_painting!.strokes.length} penseelstreken',
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

  Widget _slider(String label, double value, double min, double max,
      PaintSettings Function(double) apply) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const Spacer(),
        Text(value.toStringAsFixed(2),
            style: Theme.of(context).textTheme.labelSmall),
      ]),
      Slider(
        value: value < min ? min : (value > max ? max : value),
        min: min,
        max: max,
        onChanged: (v) => _update(apply(v)),
        onChangeEnd: (v) => _update(apply(v), rerender: true),
      ),
    ]);
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
