import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart' as xml;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PdfConverterApp());
}

class PdfConverterApp extends StatelessWidget {
  const PdfConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Converter Team',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class ToolItem {
  final String title;
  final IconData icon;
  final Future<void> Function(BuildContext context) onTap;

  const ToolItem({
    required this.title,
    required this.icon,
    required this.onTap,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;
  String _statusText = '';

  Future<void> _runTask(
    BuildContext context,
    String status,
    Future<void> Function() task,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusText = status;
    });
    try {
      await task();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusText = '';
        });
      }
    }
  }

  Future<File> _saveOutputFile(Uint8List bytes, String fileName) async {
    Directory? baseDir;
    if (Platform.isAndroid) {
      baseDir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }
    final outDir = Directory('${baseDir.path}/PDFConverterTeam');
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final file = File('${outDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _openSavedFile(BuildContext context, File file) async {
    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Output file not found')),
        );
      }
      return;
    }
    final lower = file.path.toLowerCase();
    String? mimeType;
    if (lower.endsWith('.pdf')) {
      mimeType = 'application/pdf';
    } else if (lower.endsWith('.docx')) {
      mimeType =
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    } else if (lower.endsWith('.png')) {
      mimeType = 'image/png';
    }
    final result = await OpenFilex.open(file.path, type: mimeType);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot open file: ${result.message}')),
      );
    }
  }

  Future<void> _showResultDialog(
    BuildContext context,
    String title,
    File file, {
    String? extraInfo,
  }) async {
    if (!context.mounted) return;
    final sizeKb = (await file.length() / 1024).toStringAsFixed(1);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          'Saved: ${file.path.split('/').last}\n'
          'Size: $sizeKb KB'
          '${extraInfo != null ? '\n$extraInfo' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _openSavedFile(context, file);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }

  String _cleanText(String input) {
    final normalized = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\f', '\n');
    final buf = StringBuffer();
    for (final rune in normalized.runes) {
      if (rune == 0x09 ||
          rune == 0x0A ||
          rune == 0x0D ||
          (rune >= 0x20 && rune <= 0xD7FF) ||
          (rune >= 0xE000 && rune <= 0xFFFD) ||
          (rune >= 0x10000 && rune <= 0x10FFFF)) {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  String _escapeXml(String input) {
    return _cleanText(input)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  List<String> _splitForMultiPage(String text, {int maxChars = 400}) {
    final clean = _cleanText(text).trim();
    if (clean.isEmpty) return ['(Empty document)'];

    final out = <String>[];
    for (final rawLine in clean.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) {
        out.add(' ');
        continue;
      }
      if (line.length <= maxChars) {
        out.add(line);
      } else {
        int start = 0;
        while (start < line.length) {
          final end =
              (start + maxChars < line.length) ? start + maxChars : line.length;
          out.add(line.substring(start, end));
          start = end;
        }
      }
    }
    return out;
  }

  String _parseDocxXml(String xmlStr) {
    final cleaned = _cleanText(xmlStr);
    if (cleaned.trim().isEmpty) return '';
    try {
      final docXml = xml.XmlDocument.parse(cleaned);
      final lines = <String>[];
      for (final p in docXml.findAllElements('w:p')) {
        final t = p.findAllElements('w:t').map((e) => e.innerText).join().trim();
        if (t.isNotEmpty) {
          lines.add(t);
        }
      }
      return lines.join('\n');
    } catch (_) {
      final matches =
          RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true).allMatches(cleaned);
      return matches.map((m) => m.group(1) ?? '').join(' ').trim();
    }
  }

  // 1) Image -> PDF
  Future<void> _imageToPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return;

    await _runTask(context, 'Creating PDF from images...', () async {
      final doc = pw.Document();
      for (final pf in res.files) {
        if (pf.path == null) continue;
        final imgBytes = await File(pf.path!).readAsBytes();
        final decodedImg = pw.MemoryImage(imgBytes);
        doc.addPage(
          pw.Page(
            pageFormat: pw_pdf.PdfPageFormat.a4,
            build: (_) => pw.Center(
              child: pw.Image(decodedImg, fit: pw.BoxFit.contain),
            ),
          ),
        );
      }
      final bytes = await doc.save();
      final out = await _saveOutputFile(
        bytes,
        'images_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await _showResultDialog(context, 'Image → PDF Done', out);
    });
  }

  // 2) PDF -> Image
  Future<void> _pdfToImage(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Exporting PDF pages as images...', () async {
      final bytes = await File(res.files.single.path!).readAsBytes();
      int count = 0;
      File? lastFile;
      await for (final page in Printing.raster(bytes, dpi: 150)) {
        count++;
        final pngBytes = await page.toPng();
        lastFile = await _saveOutputFile(
          pngBytes,
          'page_${count}_${DateTime.now().millisecondsSinceEpoch}.png',
        );
      }
      if (lastFile != null && context.mounted) {
        await _showResultDialog(
          context,
          'PDF → Image Done',
          lastFile,
          extraInfo: 'Total pages exported: $count',
        );
      }
    });
  }

  // 3) TXT -> PDF
  Future<void> _txtToPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Converting TXT to PDF...', () async {
      final content = await File(res.files.single.path!).readAsString();
      final chunks = _splitForMultiPage(content, maxChars: 550);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (_) => chunks
              .map(
                (line) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 3),
                  child: pw.Text(line, style: const pw.TextStyle(fontSize: 11)),
                ),
              )
              .toList(),
        ),
      );
      final bytes = await doc.save();
      final out = await _saveOutputFile(
        bytes,
        'text_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await _showResultDialog(context, 'TXT → PDF Done', out);
    });
  }

  // 4) DOCX -> PDF (Header -> Body -> Footer order)
  Future<void> _docxToPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Converting DOCX to PDF...', () async {
      final docxBytes = await File(res.files.single.path!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(docxBytes);

      String readPart(String name) {
        final f = archive.findFile(name);
        if (f == null) return '';
        final raw = f.content;
        final bytes = raw is List<int> ? raw : (raw as Uint8List).toList();
        return _parseDocxXml(String.fromCharCodes(bytes));
      }

      final headers = archive.files
          .where((f) =>
              f.isFile &&
              f.name.startsWith('word/header') &&
              f.name.endsWith('.xml'))
          .map((f) => readPart(f.name))
          .where((s) => s.isNotEmpty)
          .toList();

      final body = readPart('word/document.xml');

      final footers = archive.files
          .where((f) =>
              f.isFile &&
              f.name.startsWith('word/footer') &&
              f.name.endsWith('.xml'))
          .map((f) => readPart(f.name))
          .where((s) => s.isNotEmpty)
          .toList();

      final combined = [
        ...headers,
        if (body.isNotEmpty) body,
        ...footers,
      ].join('\n\n');

      final finalText =
          combined.trim().isEmpty ? '(No text found in DOCX)' : combined;
      final chunks = _splitForMultiPage(finalText, maxChars: 400);

      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (_) => chunks
              .map(
                (line) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Text(line, style: const pw.TextStyle(fontSize: 11)),
                ),
              )
              .toList(),
        ),
      );

      final bytes = await doc.save();
      final out = await _saveOutputFile(
        bytes,
        'docx_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await _showResultDialog(context, 'DOCX → PDF Done', out);
    });
  }

  // 5) PDF -> DOCX
  Future<void> _pdfToDocx(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Extracting text to DOCX...', () async {
      final pdfBytes = await File(res.files.single.path!).readAsBytes();
      final sfDoc = sf.PdfDocument(inputBytes: pdfBytes);
      final extracted = sf.PdfTextExtractor(sfDoc).extractText();
      sfDoc.dispose();

      final cleanedLines = _cleanText(extracted)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      final bodyXml = cleanedLines.isEmpty
          ? '<w:p><w:r><w:t xml:space="preserve">(No selectable text found in PDF)</w:t></w:r></w:p>'
          : cleanedLines
              .map(
                (line) =>
                    '<w:p><w:r><w:t xml:space="preserve">${_escapeXml(line)}</w:t></w:r></w:p>',
              )
              .join();

      final documentXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>$bodyXml</w:body>
</w:document>''';

      const contentTypesXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';

      const relsXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

      final archive = Archive()
        ..addFile(
          ArchiveFile(
            '[Content_Types].xml',
            contentTypesXml.length,
            contentTypesXml.codeUnits,
          ),
        )
        ..addFile(
          ArchiveFile(
            '_rels/.rels',
            relsXml.length,
            relsXml.codeUnits,
          ),
        )
        ..addFile(
          ArchiveFile(
            'word/document.xml',
            documentXml.length,
            documentXml.codeUnits,
          ),
        );

      final zipBytes = ZipEncoder().encode(archive) ?? <int>[];
      final out = await _saveOutputFile(
        Uint8List.fromList(zipBytes),
        'converted_${DateTime.now().millisecondsSinceEpoch}.docx',
      );
      await _showResultDialog(context, 'PDF → DOCX Done', out);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tools = <ToolItem>[
      ToolItem(
        title: 'Image → PDF',
        icon: Icons.image,
        onTap: _imageToPdf,
      ),
      ToolItem(
        title: 'PDF → Image',
        icon: Icons.photo_library,
        onTap: _pdfToImage,
      ),
      ToolItem(
        title: 'TXT → PDF',
        icon: Icons.description,
        onTap: _txtToPdf,
      ),
      ToolItem(
        title: 'DOCX → PDF',
        icon: Icons.article,
        onTap: _docxToPdf,
      ),
      ToolItem(
        title: 'PDF → DOCX',
        icon: Icons.picture_as_pdf,
        onTap: _pdfToDocx,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Converter Team'),
      ),
      body: Stack(
        children: [
          GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              childAspectRatio: 1.0,
            ),
            itemCount: tools.length,
            itemBuilder: (ctx, index) {
              final item = tools[index];
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => item.onTap(ctx),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF6DFDC),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icon, size: 42, color: Colors.black87),
                      const SizedBox(height: 12),
                      Text(
                        item.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (_busy)
            Container(
              color: Colors.black38,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 14),
                        Text(_statusText),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
