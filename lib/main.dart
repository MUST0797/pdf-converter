import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img_lib;
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

enum CompressQuality { high, normal, low }

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

  String _sanitizeXmlText(String input) {
    final normalized = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\f', '\n');
    final buf = StringBuffer();
    for (final rune in normalized.runes) {
      // Valid XML 1.0 characters: 0x9, 0xA, 0xD, 0x20..0xD7FF, 0xE000..0xFFFD, 0x10000..0x10FFFF
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
    return _sanitizeXmlText(input)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  List<String> _splitIntoSafeChunks(String text, {int maxChars = 450}) {
    final clean = _sanitizeXmlText(text).trim();
    if (clean.isEmpty) return ['(Empty document)'];

    final chunks = <String>[];
    final lines = clean.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.isEmpty) {
        chunks.add(' ');
        continue;
      }
      if (line.length <= maxChars) {
        chunks.add(line);
      } else {
        int start = 0;
        while (start < line.length) {
          final end = (start + maxChars < line.length)
              ? start + maxChars
              : line.length;
          chunks.add(line.substring(start, end));
          start = end;
        }
      }
    }
    return chunks.isEmpty ? ['(Empty document)'] : chunks;
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
      final chunks = _splitIntoSafeChunks(content, maxChars: 600);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (_) => chunks
              .map(
                (line) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 3),
                  child: pw.Text(
                    line,
                    style: const pw.TextStyle(fontSize: 11),
                  ),
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

  // 4) DOCX -> PDF (Safe multi-page chunking so tall text never overflows a single page)
  Future<void> _docxToPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Converting DOCX to PDF...', () async {
      final docxBytes = await File(res.files.single.path!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(docxBytes);

      final parts = <String>[];
      // Extract header, main document, and footer text in logical order
      final targetEntries = archive.files
          .where((f) =>
              f.isFile &&
              (f.name.startsWith('word/header') ||
                  f.name == 'word/document.xml' ||
                  f.name.startsWith('word/footer')) &&
              f.name.endsWith('.xml'))
          .toList()
        ..sort((a, b) {
          int rank(String name) {
            if (name.startsWith('word/header')) return 0;
            if (name == 'word/document.xml') return 1;
            return 2;
          }

          final r = rank(a.name).compareTo(rank(b.name));
          return r != 0 ? r : a.name.compareTo(b.name);
        });

      for (final entry in targetEntries) {
        final rawContent = entry.content;
        final bytesList = rawContent is List<int>
            ? rawContent
            : (rawContent as Uint8List).toList();
        final xmlStr = _sanitizeXmlText(String.fromCharCodes(bytesList));
        if (xmlStr.trim().isEmpty) continue;

        try {
          final documentXml = xml.XmlDocument.parse(xmlStr);
          final paragraphs = documentXml.findAllElements('w:p');
          for (final p in paragraphs) {
            final line = p
                .findAllElements('w:t')
                .map((t) => t.innerText)
                .join()
                .trim();
            if (line.isNotEmpty) {
              parts.add(line);
            }
          }
        } catch (_) {
          // Fallback tag extraction if XML has custom attributes
          final matches = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true)
              .allMatches(xmlStr);
          final fallbackLine = matches.map((m) => m.group(1) ?? '').join().trim();
          if (fallbackLine.isNotEmpty) {
            parts.add(fallbackLine);
          }
        }
      }

      final combinedText =
          parts.isEmpty ? '(No readable text found in DOCX)' : parts.join('\n');
      final chunks = _splitIntoSafeChunks(combinedText, maxChars: 420);

      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (_) => chunks
              .map(
                (line) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Text(
                    line,
                    style: const pw.TextStyle(fontSize: 11),
                  ),
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
      await _showResultDialog(
        context,
        'DOCX → PDF Done',
        out,
        extraInfo: 'Paragraphs extracted: ${parts.length}',
      );
    });
  }

  // 5) PDF -> DOCX (Clean XML escaping & valid OOXML archive)
  Future<void> _pdfToDocx(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Extracting text to DOCX...', () async {
      final pdfBytes = await File(res.files.single.path!).readAsBytes();
      final sfDoc = sf.PdfDocument(inputBytes: pdfBytes);
      final pageCount = sfDoc.pages.count;

      final pageSections = <String>[];
      for (int i = 0; i < pageCount; i++) {
        final pageText =
            sf.PdfTextExtractor(sfDoc).extractText(startPageIndex: i, endPageIndex: i);
        final lines = _sanitizeXmlText(pageText).split('\n');
        for (final rawLine in lines) {
          final cleaned = rawLine.trim();
          if (cleaned.isEmpty) continue;
          final safeLine = _escapeXml(cleaned);
          pageSections.add(
            '<w:p><w:r><w:t xml:space="preserve">$safeLine</w:t></w:r></w:p>',
          );
        }
        if (i < pageCount - 1) {
          pageSections.add('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
        }
      }
      sfDoc.dispose();

      if (pageSections.isEmpty) {
        pageSections.add(
          '<w:p><w:r><w:t xml:space="preserve">(No selectable text found in PDF)</w:t></w:r></w:p>',
        );
      }

      final bodyXml = pageSections.join();

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
      await _showResultDialog(
        context,
        'PDF → DOCX Done',
        out,
        extraInfo: 'Pages processed: $pageCount',
      );
    });
  }

  // 6) PDF Page Merger & Page Remover
  Future<void> _pdfMergeOrRemove(BuildContext context) async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'PDF Page Merger & Remover',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.merge_type),
              title: const Text('Merge Multiple PDFs'),
              subtitle: const Text('Combine 2 or more PDF files into one PDF'),
              onTap: () => Navigator.pop(ctx, 'merge'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep),
              title: const Text('Remove Pages from PDF'),
              subtitle: const Text('Select pages to delete and save new PDF'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );

    if (mode == null || !context.mounted) return;

    if (mode == 'merge') {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );
      if (res == null || res.files.length < 2) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select at least 2 PDF files to merge')),
          );
        }
        return;
      }

      await _runTask(context, 'Merging PDF files...', () async {
        final mergedDoc = sf.PdfDocument();
        mergedDoc.pageSettings.margins.all = 0;

        for (final pf in res.files) {
          if (pf.path == null) continue;
          final bytes = await File(pf.path!).readAsBytes();
          final srcDoc = sf.PdfDocument(inputBytes: bytes);
          for (int i = 0; i < srcDoc.pages.count; i++) {
            final srcPage = srcDoc.pages[i];
            final template = srcPage.createTemplate();
            final newPage = mergedDoc.pages.add();
            newPage.graphics.drawPdfTemplate(
              template,
              ui.Offset.zero,
              ui.Size(srcPage.size.width, srcPage.size.height),
            );
          }
          srcDoc.dispose();
        }

        final outBytes = Uint8List.fromList(await mergedDoc.save());
        mergedDoc.dispose();

        final outFile = await _saveOutputFile(
          outBytes,
          'merged_${DateTime.now().millisecondsSinceEpoch}.pdf',
        );
        await _showResultDialog(context, 'PDF Merged', outFile);
      });
    } else if (mode == 'remove') {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (res == null || res.files.single.path == null) return;

      final bytes = await File(res.files.single.path!).readAsBytes();
      final tempDoc = sf.PdfDocument(inputBytes: bytes);
      final totalPages = tempDoc.pages.count;
      tempDoc.dispose();

      if (totalPages <= 1) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF has only 1 page')),
          );
        }
        return;
      }

      if (!context.mounted) return;
      final pagesToRemove = <int>{};
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text('Select Pages to Remove ($totalPages pages)'),
            content: SizedBox(
              width: double.maxFinite,
              height: 320,
              child: ListView.builder(
                itemCount: totalPages,
                itemBuilder: (_, idx) {
                  final pageNum = idx + 1;
                  final checked = pagesToRemove.contains(idx);
                  return CheckboxListTile(
                    title: Text('Page $pageNum'),
                    value: checked,
                    onChanged: (val) {
                      setDialogState(() {
                        if (val == true) {
                          if (pagesToRemove.length < totalPages - 1) {
                            pagesToRemove.add(idx);
                          }
                        } else {
                          pagesToRemove.remove(idx);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: pagesToRemove.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: Text('Remove (${pagesToRemove.length})'),
              ),
            ],
          ),
        ),
      );

      if (confirmed != true || pagesToRemove.isEmpty || !context.mounted) return;

      await _runTask(context, 'Removing selected pages...', () async {
        final srcDoc = sf.PdfDocument(inputBytes: bytes);
        final outDoc = sf.PdfDocument();
        outDoc.pageSettings.margins.all = 0;

        int kept = 0;
        for (int i = 0; i < srcDoc.pages.count; i++) {
          if (pagesToRemove.contains(i)) continue;
          final srcPage = srcDoc.pages[i];
          final template = srcPage.createTemplate();
          final page = outDoc.pages.add();
          page.graphics.drawPdfTemplate(
            template,
            ui.Offset.zero,
            ui.Size(srcPage.size.width, srcPage.size.height),
          );
          kept++;
        }
        srcDoc.dispose();

        final outBytes = Uint8List.fromList(await outDoc.save());
        outDoc.dispose();

        final outFile = await _saveOutputFile(
          outBytes,
          'trimmed_${DateTime.now().millisecondsSinceEpoch}.pdf',
        );
        await _showResultDialog(
          context,
          'Pages Removed',
          outFile,
          extraInfo: 'Remaining pages: $kept',
        );
      });
    }
  }

  Uint8List _encodeSharpJpeg(
    Uint8List pngBytes, {
    required int maxWidth,
    required int jpegQuality,
  }) {
    final decoded = img_lib.decodeImage(pngBytes);
    if (decoded == null) return pngBytes;

    img_lib.Image working = decoded;
    if (working.width > maxWidth) {
      working = img_lib.copyResize(
        working,
        width: maxWidth,
        interpolation: img_lib.Interpolation.cubic,
      );
    }
    return Uint8List.fromList(
      img_lib.encodeJpg(working, quality: jpegQuality),
    );
  }

  // 7) PDF File Compressor (High / Normal / Low Quality)
  Future<void> _compressPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (res == null || res.files.single.path == null) return;

    if (!context.mounted) return;
    final quality = await showDialog<CompressQuality>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select Compression Quality'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, CompressQuality.high),
            child: const ListTile(
              leading: Icon(Icons.high_quality),
              title: Text('High Quality'),
              subtitle: Text('Sharp text & ~50% target size'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, CompressQuality.normal),
            child: const ListTile(
              leading: Icon(Icons.tune),
              title: Text('Normal Quality'),
              subtitle: Text('Clear text & ~25% target size'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, CompressQuality.low),
            child: const ListTile(
              leading: Icon(Icons.compress),
              title: Text('Low Quality'),
              subtitle: Text('Smallest size (~12.5% target)'),
            ),
          ),
        ],
      ),
    );

    if (quality == null || !context.mounted) return;

    final double ratio = switch (quality) {
      CompressQuality.high => 0.50,
      CompressQuality.normal => 0.25,
      CompressQuality.low => 0.125,
    };

    final double renderDpi = switch (quality) {
      CompressQuality.high => 130,
      CompressQuality.normal => 96,
      CompressQuality.low => 72,
    };

    final String qualityLabel = switch (quality) {
      CompressQuality.high => 'High Quality',
      CompressQuality.normal => 'Normal Quality',
      CompressQuality.low => 'Low Quality',
    };

    await _runTask(context, 'Compressing PDF ($qualityLabel)...', () async {
      final originalFile = File(res.files.single.path!);
      final originalBytes = await originalFile.readAsBytes();
      final originalKb = (originalBytes.length / 1024).toStringAsFixed(1);
      final targetBytes = (originalBytes.length * ratio).round();

      final rawPages = <({Uint8List png, double widthPt, double heightPt})>[];
      await for (final rasterPage
          in Printing.raster(originalBytes, dpi: renderDpi)) {
        final pngBytes = await rasterPage.toPng();
        rawPages.add((
          png: pngBytes,
          widthPt: rasterPage.width * 72 / renderDpi,
          heightPt: rasterPage.height * 72 / renderDpi,
        ));
      }

      int maxWidth = switch (quality) {
        CompressQuality.high => 1100,
        CompressQuality.normal => 820,
        CompressQuality.low => 600,
      };

      int jpegQuality = switch (quality) {
        CompressQuality.high => 82,
        CompressQuality.normal => 65,
        CompressQuality.low => 45,
      };

      Uint8List bestBytes = originalBytes;
      for (int attempt = 0; attempt < 6; attempt++) {
        final outPdf = pw.Document();
        for (final p in rawPages) {
          final jpgBytes = _encodeSharpJpeg(
            p.png,
            maxWidth: maxWidth,
            jpegQuality: jpegQuality,
          );
          final img = pw.MemoryImage(jpgBytes);
          outPdf.addPage(
            pw.Page(
              pageFormat:
                  pw_pdf.PdfPageFormat(p.widthPt, p.heightPt, marginAll: 0),
              build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
            ),
          );
        }

        final candidate = await outPdf.save();
        bestBytes = candidate;
        if (candidate.length <= targetBytes) {
          break;
        }
        if (jpegQuality > 42) {
          jpegQuality = (jpegQuality - 12).clamp(38, 85);
        } else if (maxWidth > 420) {
          maxWidth = (maxWidth * 0.80).round();
        } else {
          break;
        }
      }

      final outFile = await _saveOutputFile(
        bestBytes,
        'compressed_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );

      final targetKb = (targetBytes / 1024).toStringAsFixed(1);
      await _showResultDialog(
        context,
        'PDF Compressed ($qualityLabel)',
        outFile,
        extraInfo: 'Original: $originalKb KB | Target: ~$targetKb KB',
      );
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
      ToolItem(
        title: 'PDF Merge / Remove',
        icon: Icons.auto_awesome_motion,
        onTap: _pdfMergeOrRemove,
      ),
      ToolItem(
        title: 'Compress PDF',
        icon: Icons.compress,
        onTap: _compressPdf,
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
