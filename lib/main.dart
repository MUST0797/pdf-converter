import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import 'office_tools.dart';
import 'pdf_to_docx.dart';

void main() => runApp(const PdfApp());

class PdfApp extends StatelessWidget {
  const PdfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Converter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.red,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------- Enums & Helpers ----------

enum ImageFormatChoice { png, jpeg, jpg }

enum QualityChoice { normal, high }

extension ImageFormatChoiceExt on ImageFormatChoice {
  String get label {
    switch (this) {
      case ImageFormatChoice.png:
        return 'PNG';
      case ImageFormatChoice.jpeg:
        return 'JPEG';
      case ImageFormatChoice.jpg:
        return 'JPG';
    }
  }

  String get ext {
    switch (this) {
      case ImageFormatChoice.png:
        return 'png';
      case ImageFormatChoice.jpeg:
        return 'jpeg';
      case ImageFormatChoice.jpg:
        return 'jpg';
    }
  }
}

extension QualityChoiceExt on QualityChoice {
  String get label =>
      this == QualityChoice.high ? 'High Quality' : 'Normal Quality';

  String get subtitle => this == QualityChoice.high
      ? '300 DPI • Sharp & clear (larger size)'
      : '150 DPI • Fast & balanced size';

  double get dpi => this == QualityChoice.high ? 300.0 : 150.0;
}

Future<Directory> pdfDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/PDFs');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<Uint8List> toPngBytes(Uint8List bytes) async {
  final image = await decodeImageFromList(bytes);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<File> imagesToPdf(List<String> paths) async {
  final doc = pw.Document();
  for (final p in paths) {
    var bytes = await File(p).readAsBytes();
    final ext = p.toLowerCase().split('.').last;
    if (ext != 'jpg' && ext != 'jpeg' && ext != 'png') {
      bytes = await toPngBytes(bytes);
    }
    final img = pw.MemoryImage(bytes);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(16),
        build: (_) => pw.Center(
          child: pw.Image(img, fit: pw.BoxFit.contain),
        ),
      ),
    );
  }
  final dir = await pdfDir();
  final file =
      File('${dir.path}/Images_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

Future<File> textToPdf(String text, String baseName) async {
  final doc = pw.Document();
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      maxPages: 2000,
      build: (_) => lines
          .map((l) => pw.Text(l.isEmpty ? ' ' : l,
              style: const pw.TextStyle(fontSize: 12)))
          .toList(),
    ),
  );
  final dir = await pdfDir();
  final file = File(
      '${dir.path}/${baseName}_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

Future<List<File>> pdfToImages(
  String pdfPath, {
  required ImageFormatChoice format,
  required QualityChoice quality,
  void Function(int pageCount)? onPageConverted,
}) async {
  final pdfBytes = await File(pdfPath).readAsBytes();
  final dir = await pdfDir();
  final safeBase = pdfPath
      .split('/')
      .last
      .split('\\')
      .last
      .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^\w\-]+'), '_');
  final stamp = DateTime.now().millisecondsSinceEpoch;

  final List<File> saved = [];
  int index = 0;

  await for (final page in Printing.raster(pdfBytes, dpi: quality.dpi)) {
    index++;
    final Uint8List pngBytes = await page.toPng();
    final ui.Image rawImg = await decodeImageFromList(pngBytes);

    final int w = rawImg.width;
    final int h = rawImg.height;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Colors.white,
    );
    canvas.drawImage(rawImg, Offset.zero, Paint());

    final ui.Image whiteBgImg = await recorder.endRecording().toImage(w, h);
    final byteData =
        await whiteBgImg.toByteData(format: ui.ImageByteFormat.png);

    rawImg.dispose();
    whiteBgImg.dispose();

    if (byteData != null) {
      final outFile = File(
          '${dir.path}/${safeBase}_${stamp}_p$index.${format.ext}');
      await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      saved.add(outFile);
      onPageConverted?.call(index);
    }
  }

  return saved;
}

void snack(BuildContext c, String msg) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));
}

// ---------- Home ----------

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <_Tool>[
      _Tool('Image → PDF', Icons.image, true,
          () => _go(context, const ImageToPdfScreen())),
      _Tool('PDF → Image', Icons.collections, true,
          () => _go(context, const PdfToImageScreen())),
      _Tool('TXT → PDF', Icons.text_snippet, true,
          () => _go(context, const TxtToPdfScreen())),
      _Tool(
          'DOCX → PDF',
          Icons.description,
          true,
          () => _go(
              context,
              SinglePickScreen(
                  title: 'DOCX → PDF',
                  extension: 'docx',
                  icon: Icons.description,
                  onConvert: docxToPdf))),
      _Tool(
          'PDF → DOCX',
          Icons.picture_as_pdf,
          true,
          () => _go(
              context,
              SinglePickScreen(
                  title: 'PDF → DOCX',
                  extension: 'pdf',
                  icon: Icons.picture_as_pdf,
                  onConvert: pdfToDocx))),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Converter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'My Files',
            onPressed: () => _go(context, const MyFilesScreen()),
          ),
        ],
      ),
      body: GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        children: items.map((t) => _ToolCard(t)).toList(),
      ),
    );
  }

  void _go(BuildContext c, Widget w) =>
      Navigator.push(c, MaterialPageRoute(builder: (_) => w));
}

class _Tool {
  final String title;
  final IconData icon;
  final bool ready;
  final VoidCallback? onTap;
  _Tool(this.title, this.icon, this.ready, this.onTap);
}

class _ToolCard extends StatelessWidget {
  final _Tool tool;
  const _ToolCard(this.tool);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: tool.ready ? cs.primaryContainer : cs.surfaceContainerHighest,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tool.ready ? tool.onTap : () => snack(context, 'Coming soon'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tool.icon, size: 48),
            const SizedBox(height: 12),
            Text(tool.title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (!tool.ready)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Coming soon', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- PDF -> Image ----------

class PdfToImageScreen extends StatefulWidget {
  const PdfToImageScreen({super.key});

  @override
  State<PdfToImageScreen> createState() => _PdfToImageScreenState();
}

class _PdfToImageScreenState extends State<PdfToImageScreen> {
  String? _pdfPath;
  String? _pdfName;
  ImageFormatChoice _format = ImageFormatChoice.png;
  QualityChoice _quality = QualityChoice.normal;
  bool _busy = false;
  int _convertedPages = 0;

  Future<void> _pickPdf() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (res == null || res.files.single.path == null) return;
    setState(() {
      _pdfPath = res.files.single.path!;
      _pdfName = res.files.single.name;
    });
  }

  Future<void> _openOptionsAndConvert() async {
    if (_pdfPath == null || _busy) return;

    final selected =
        await showModalBottomSheet<(ImageFormatChoice, QualityChoice)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        var tempFormat = _format;
        var tempQuality = _quality;
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Image Format & Quality',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 14),
                  const Text('Format select pannunga:',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SegmentedButton<ImageFormatChoice>(
                    segments: ImageFormatChoice.values
                        .map((f) => ButtonSegment<ImageFormatChoice>(
                              value: f,
                              label: Text(f.label),
                            ))
                        .toList(),
                    selected: {tempFormat},
                    onSelectionChanged: (set) {
                      setModalState(() => tempFormat = set.first);
                    },
                  ),
                  const SizedBox(height: 18),
                  const Text('Quality select pannunga:',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...QualityChoice.values.map(
                    (q) => RadioListTile<QualityChoice>(
                      contentPadding: EdgeInsets.zero,
                      title: Text(q.label),
                      subtitle: Text(q.subtitle),
                      value: q,
                      groupValue: tempQuality,
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => tempQuality = val);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.pop(ctx, (tempFormat, tempQuality)),
                      icon: const Icon(Icons.image),
                      label: const Text('Start Convert'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (selected == null) return;

    setState(() {
      _format = selected.$1;
      _quality = selected.$2;
      _busy = true;
      _convertedPages = 0;
    });

    try {
      final files = await pdfToImages(
        _pdfPath!,
        format: _format,
        quality: _quality,
        onPageConverted: (count) {
          if (mounted) setState(() => _convertedPages = count);
        },
      );
      if (!mounted) return;
      if (files.isEmpty) {
        snack(context, 'Pages convert panna mudiyala');
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ImageResultScreen(
            files: files,
            formatLabel: _format.label,
            qualityLabel: _quality.label,
          ),
        ),
      );
    } catch (e) {
      if (mounted) snack(context, 'Convert aagala: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF → Image')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _pickPdf,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Select PDF'),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        child: Column(
          children: [
            Expanded(
              child: _pdfPath == null
                  ? const Center(child: Text('PDF file select pannunga'))
                  : Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.picture_as_pdf,
                                size: 64, color: Colors.red),
                            const SizedBox(height: 12),
                            Text(
                              _pdfName ?? '',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 16),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                Chip(label: Text('Format: ${_format.label}')),
                                Chip(label: Text('Quality: ${_quality.label}')),
                              ],
                            ),
                            if (_busy) ...[
                              const SizedBox(height: 24),
                              const CircularProgressIndicator(),
                              const SizedBox(height: 10),
                              Text(
                                _convertedPages > 0
                                    
