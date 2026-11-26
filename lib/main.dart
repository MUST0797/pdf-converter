import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
              await OpenFilex.open(file.path);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
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
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          build: (_) => [pw.Text(content, style: const pw.TextStyle(fontSize: 12))],
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

  // 4) DOCX -> PDF
  Future<void> _docxToPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Converting DOCX to PDF...', () async {
      final docxBytes = await File(res.files.single.path!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(docxBytes);
      final docXmlFile = archive.findFile('word/document.xml');
      String extractedText = '';
      if (docXmlFile != null) {
        final xmlStr = String.fromCharCodes(docXmlFile.content as List<int>);
        final documentXml = xml.XmlDocument.parse(xmlStr);
        final paragraphs = documentXml.findAllElements('w:p');
        extractedText = paragraphs
            .map((p) => p.findAllElements('w:t').map((t) => t.innerText).join())
            .where((line) => line.trim().isNotEmpty)
            .join('\n\n');
      }
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          build: (_) => [
            pw.Text(
              extractedText.isEmpty ? '(No text found in DOCX)' : extractedText,
              style: const pw.TextStyle(fontSize: 12),
            ),
          ],
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
      final text = sf.PdfTextExtractor(sfDoc).extractText();
      sfDoc.dispose();

      final escaped = text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      final lines = escaped.split('\n');
      final bodyXml = lines
          .map((l) => '<w:p><w:r><w:t xml:space="preserve">$l</w:t></w:r></w:p>')
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
        ..addFile(ArchiveFile('[Content_Types].xml', contentTypesXml.length, contentTypesXml.codeUnits))
        ..addFile(ArchiveFile('_rels/.rels', relsXml.length, relsXml.codeUnits))
        ..addFile(ArchiveFile('word/document.xml', documentXml.length, documentXml.codeUnits));

      final zipBytes = ZipEncoder().encode(archive) ?? <int>[];
      final out = await _saveOutputFile(
        Uint8List.fromList(zipBytes),
        'converted_${DateTime.now().millisecondsSinceEpoch}.docx',
      );
      await _showResultDialog(context, 'PDF → DOCX Done', out);
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

  Future<Uint8List> _downscalePng(Uint8List pngBytes, int targetWidth) async {
    final codec = await ui.instantiateImageCodec(
      pngBytes,
      targetWidth: targetWidth,
    );
    final frame = await codec.getNextFrame();
    final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return byteData?.buffer.asUint8List() ?? pngBytes;
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
              subtitle: Text('Target ~50% of original size'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, CompressQuality.normal),
            child: const ListTile(
              leading: Icon(Icons.tune),
              title: Text('Normal Quality'),
              subtitle: Text('Target ~25% of original size'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, CompressQuality.low),
            child: const ListTile(
              leading: Icon(Icons.compress),
              title: Text('Low Quality'),
              subtitle: Text('Target ~12.5% of original size'),
            ),
          ),
        ],
      ),
    );

    if (quality == null || !context.mounted) return;

    // Ratio targets: High ~0.50 (0.52 MB for 1.04 MB), Normal ~0.25 (0.26 MB), Low ~0.125 (0.13 MB)
    final double ratio = switch (quality) {
      CompressQuality.high => 0.50,
      CompressQuality.normal => 0.25,
      CompressQuality.low => 0.125,
    };

    final double baseDpi = switch (quality) {
      CompressQuality.high => 72,
      CompressQuality.normal => 54,
      CompressQuality.low => 40,
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
      await for (final rasterPage in Printing.raster(originalBytes, dpi: baseDpi)) {
        final pngBytes = await rasterPage.toPng();
        rawPages.add((
          png: pngBytes,
          widthPt: rasterPage.width * 72 / baseDpi,
          heightPt: rasterPage.height * 72 / baseDpi,
        ));
      }

      double scaleFactor = switch (quality) {
        CompressQuality.high => 0.70,
        CompressQuality.normal => 0.50,
        CompressQuality.low => 0.35,
      };

      Uint8List bestBytes = originalBytes;
      for (int attempt = 0; attempt < 6; attempt++) {
        final outPdf = pw.Document();
        for (final p in rawPages) {
          final targetW = (p.widthPt * scaleFactor).round().clamp(180, 1200);
          final scaledPng = await _downscalePng(p.png, targetW);
          final img = pw.MemoryImage(scaledPng);
          outPdf.addPage(
            pw.Page(
              pageFormat: pw_pdf.PdfPageFormat(p.widthPt, p.heightPt, marginAll: 0),
              build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
            ),
          );
        }

        final candidate = await outPdf.save();
        bestBytes = candidate;
        if (candidate.length <= targetBytes || scaleFactor <= 0.18) {
          break;
        }
        scaleFactor *= 0.72;
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
