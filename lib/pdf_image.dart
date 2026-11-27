import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:printing/printing.dart' show Printing;
import 'package:share_plus/share_plus.dart';

import 'main.dart';

// ---------- PDF -> Image (Normal / High quality) ----------

class PdfToImageScreen extends StatefulWidget {
  const PdfToImageScreen({super.key});

  @override
  State<PdfToImageScreen> createState() => _PdfToImageScreenState();
}

class _PdfToImageScreenState extends State<PdfToImageScreen> {
  String? _path;
  String? _name;
  bool _high = false;
  bool _busy = false;
  String _status = '';

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (res == null || res.files.single.path == null) return;
    setState(() {
      _path = res.files.single.path;
      _name = res.files.single.name;
    });
  }

  Future<void> _convert() async {
    setState(() {
      _busy = true;
      _status = 'Starting...';
    });
    try {
      final bytes = await File(_path!).readAsBytes();
      final dir = await pdfDir();
      final base = _name!.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final dpi = _high ? 220.0 : 110.0;
      final files = <File>[];
      var n = 0;
      await for (final page in Printing.raster(bytes, dpi: dpi)) {
        n++;
        if (mounted) setState(() => _status = 'Page $n converting...');
        final png = await page.toPng();
        final f = File('${dir.path}/${base}_${stamp}_p$n.png');
        await f.writeAsBytes(png, flush: true);
        files.add(f);
      }
      if (files.isEmpty) throw Exception('PDF-la pages kidaikkala');
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ImagesResultScreen(files: files)),
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
        onPressed: _busy ? null : _pick,
        icon: const Icon(Icons.folder_open),
        label: const Text('Select PDF'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _name == null
                  ? const Text('PDF file select pannunga')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.picture_as_pdf,
                            size: 64, color: Colors.red),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(_name!, textAlign: TextAlign.center),
                        ),
                        const SizedBox(height: 24),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                                value: false,
                                label: Text('Normal'),
                                icon: Icon(Icons.speed)),
                            ButtonSegment(
                                value: true,
                                label: Text('High'),
                                icon: Icon(Icons.high_quality)),
                          ],
                          selected: {_high},
                          onSelectionChanged: _busy
                              ? null
                              : (s) => setState(() => _high = s.first),
                        ),
                        const SizedBox(height: 8),
                        Text(_high
                            ? 'High: clear, bigger size (print / zoom)'
                            : 'Normal: smaller size (share panna nalladhu)'),
                        if (_busy) ...[
                          const SizedBox(height: 16),
                          Text(_status),
                        ],
                      ],
                    ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_path == null || _busy) ? null : _convert,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.photo_library),
                  label: Text(_busy ? 'Converting...' : 'Convert to Images'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ImagesResultScreen extends StatelessWidget {
  final List<File> files;
  const ImagesResultScreen({super.key, required this.files});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${files.length} image(s) ready')),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: files.length,
        itemBuilder: (_, i) {
          final f = files[i];
          final kb = (f.lengthSync() / 1024).toStringAsFixed(0);
          return Card(
            child: ListTile(
              leading: SizedBox(
                width: 56,
                height: 56,
                child: Image.file(f, fit: BoxFit.cover, cacheWidth: 150),
              ),
              title: Text('Page ${i + 1}'),
              subtitle: Text('$kb KB'),
              onTap: () => OpenFilex.open(f.path),
              trailing: IconButton(
                icon: const Icon(Icons.share),
                onPressed: () => Share.shareXFiles([XFile(f.path)]),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: () =>
                Share.shareXFiles([for (final f in files) XFile(f.path)]),
            icon: const Icon(Icons.share),
            label: const Text('Share all'),
          ),
        ),
      ),
    );
  }
}
