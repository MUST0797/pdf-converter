import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

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

// ---------- Helpers ----------

Future<Directory> pdfDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/PDFs');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<Uint8List> toPngBytes(Uint8List bytes) async {
  final image = await decodeImageFromList(bytes);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
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
      _Tool('TXT → PDF', Icons.text_snippet, false, null),
      _Tool('DOCX → PDF', Icons.description, false, null),
      _Tool('PDF → DOCX', Icons.picture_as_pdf, false, null),
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
        onTap: tool.ready
            ? tool.onTap
            : () => snack(context, 'Coming soon'),
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

// ---------- Image -> PDF ----------

class ImageToPdfScreen extends StatefulWidget {
  const ImageToPdfScreen({super.key});

  @override
  State<ImageToPdfScreen> createState() => _ImageToPdfScreenState();
}

class _ImageToPdfScreenState extends State<ImageToPdfScreen> {
  final List<String> _paths = [];
  bool _busy = false;

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
      allowMultiple: true,
    );
    if (res == null) return;
    setState(() {
      for (final f in res.files) {
        if (f.path != null) _paths.add(f.path!);
      }
    });
  }

  Future<void> _convert() async {
    setState(() => _busy = true);
    try {
      final file = await imagesToPdf(_paths);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ResultScreen(file: file)),
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
      appBar: AppBar(title: const Text('Image → PDF')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _pick,
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('Add images'),
      ),
      body: Column(
        children: [
          Expanded(
            child: _paths.isEmpty
                ? const Center(child: Text('Images select pannunga'))
                : ReorderableListView.builder(
                    itemCount: _paths.length,
                    onReorder: (o, n) {
                      setState(() {
                        if (n > o) n--;
                        _paths.insert(n, _paths.removeAt(o));
                      });
                    },
                    itemBuilder: (_, i) => ListTile(
                      key: ValueKey('${_paths[i]}_$i'),
                      leading: Image.file(File(_paths[i]),
                          width: 48, height: 48, fit: BoxFit.cover),
                      title: Text(_paths[i].split('/').last,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('Page ${i + 1}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _paths.removeAt(i)),
                      ),
                    ),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_paths.isEmpty || _busy) ? null : _convert,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(_busy ? 'Converting...' : 'Convert to PDF'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Result ----------

class ResultScreen extends StatelessWidget {
  final File file;
  const ResultScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Done')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 80, color: Colors.green),
            const SizedBox(height: 16),
            Text(file.path.split('/').last, textAlign: TextAlign.center),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => OpenFilex.open(file.path),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Share.shareXFiles([XFile(file.path)]),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const MyFilesScreen()),
                ),
                icon: const Icon(Icons.folder),
                label: const Text('My Files'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- My Files ----------

class MyFilesScreen extends StatefulWidget {
  const MyFilesScreen({super.key});

  @override
  State<MyFilesScreen> createState() => _MyFilesScreenState();
}

class _MyFilesScreenState extends State<MyFilesScreen> {
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await pdfDir();
    final list = dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.toLowerCase().endsWith('.pdf') ||
            f.path.toLowerCase().endsWith('.docx'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (!mounted) return;
    setState(() {
      _files = list;
      _loading = false;
    });
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete pannattuma?'),
        content: Text(f.path.split('/').last),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await f.delete();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Files')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('Innum files illa'))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (_, i) {
                    final f = _files[i];
                    final isPdf = f.path.toLowerCase().endsWith('.pdf');
                    final kb = (f.lengthSync() / 1024).toStringAsFixed(0);
                    return ListTile(
                      leading: Icon(
                          isPdf ? Icons.picture_as_pdf : Icons.description,
                          color: isPdf ? Colors.red : Colors.blue),
                      title: Text(f.path.split('/').last,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('$kb KB'),
                      onTap: () => OpenFilex.open(f.path),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.share),
                            onPressed: () => Share.shareXFiles([XFile(f.path)]),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(f),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
