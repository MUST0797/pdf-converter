import 'dart:convert';
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

enum _DocxBlockType { paragraph, table }

class _DocxBlock {
  final _DocxBlockType type;
  final String? text;
  final List<List<String>>? rows;

  const _DocxBlock.paragraph(this.text)
      : type = _DocxBlockType.paragraph,
        rows = null;

  const _DocxBlock.table(this.rows)
      : type = _DocxBlockType.table,
        text = null;
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
        SnackBar(content: Text('Open failed (${result.type}): ${result.message}')),
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

  String _normalizePdfSafeText(String input) {
    return _cleanText(input)
        .replaceAll('°', ' deg')
        .replaceAll('µ', 'u')
        .replaceAll('μ', 'u')
        .replaceAll('Α', 'A')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('−', '-')
        .replaceAll('≤', '<=')
        .replaceAll('≥', '>=')
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('‘', "'")
        .replaceAll('’', "'")
        .replaceAll('\t', ' ')
        .replaceAll(RegExp(r' +'), ' ');
  }

  String _escapeXml(String input) {
    return _cleanText(input)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  List<String> _splitForMultiPage(String text, {int maxChars = 420}) {
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

  String _collectParagraphText(xml.XmlElement pElem) {
    final buf = StringBuffer();
    void walk(xml.XmlNode n) {
      if (n is xml.XmlElement) {
        final local = n.name.local;
        if (local == 't') {
          buf.write(n.innerText);
        } else if (local == 'tab') {
          buf.write(' ');
        } else if (local == 'br' || local == 'cr') {
          buf.write(' ');
        }
        for (final child in n.children) {
          walk(child);
        }
      }
    }

    walk(pElem);
    return _normalizePdfSafeText(buf.toString()).trim();
  }

  String _collectCellText(xml.XmlElement tcElem) {
    final lines = <String>[];
    for (final p in tcElem.findAllElements('w:p')) {
      final t = _collectParagraphText(p);
      if (t.isNotEmpty) {
        lines.add(t);
      }
    }
    return lines.join(' ').trim();
  }

  List<_DocxBlock> _parseDocxBlocks(String xmlStr) {
    final cleaned = _cleanText(xmlStr);
    if (cleaned.trim().isEmpty) return const [];

    try {
      final docXml = xml.XmlDocument.parse(cleaned);
      final blocks = <_DocxBlock>[];

      void walkNode(xml.XmlNode n) {
        if (n is xml.XmlElement) {
          final local = n.name.local;
          if (local == 'tbl') {
            final rows = <List<String>>[];
            int maxCols = 0;
            for (final child in n.children) {
              if (child is xml.XmlElement && child.name.local == 'tr') {
                final rawCells = <String>[];
                for (final trChild in child.children) {
                  if (trChild is xml.XmlElement && trChild.name.local == 'tc') {
                    rawCells.add(_collectCellText(trChild));
                  }
                }
                if (rawCells.any((c) => c.isNotEmpty)) {
                  if (rawCells.length > maxCols) maxCols = rawCells.length;
                  rows.add(rawCells);
                }
              }
            }
            if (rows.isNotEmpty && maxCols > 0) {
              final normalizedRows = rows
                  .map((r) => List<String>.generate(
                        maxCols,
                        (idx) => idx < r.length ? r[idx] : '',
                      ))
                  .toList();
              blocks.add(_DocxBlock.table(normalizedRows));
            }
            return;
          }
          if (local == 'p') {
            final pText = _collectParagraphText(n);
            if (pText.isNotEmpty) {
              blocks.add(_DocxBlock.paragraph(pText));
            }
            return;
          }
        }
        for (final child in n.children) {
          walkNode(child);
        }
      }

      walkNode(docXml);
      return blocks;
    } catch (_) {
      final matches =
          RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true).allMatches(cleaned);
      final fallback = _normalizePdfSafeText(
        matches.map((m) => m.group(1) ?? '').join(' ').trim(),
      );
      if (fallback.isEmpty) return const [];
      return [_DocxBlock.paragraph(fallback)];
    }
  }

  String _blocksToPlainText(List<_DocxBlock> blocks) {
    final lines = <String>[];
    for (final b in blocks) {
      if (b.type == _DocxBlockType.paragraph && b.text != null) {
        final t = b.text!.trim();
        if (t.isNotEmpty) lines.add(t);
      } else if (b.type == _DocxBlockType.table && b.rows != null) {
        for (final row in b.rows!) {
          final nonEmpty = row.where((c) => c.trim().isNotEmpty).toList();
          if (nonEmpty.isNotEmpty) {
            lines.add(nonEmpty.join('  |  '));
          }
        }
      }
    }
    return lines.join('\n').trim();
  }

  List<pw.Widget> _buildPdfWidgetsFromBlocks(List<_DocxBlock> blocks) {
    final widgets = <pw.Widget>[];
    for (final b in blocks) {
      if (b.type == _DocxBlockType.paragraph && b.text != null) {
        for (final chunk in _splitForMultiPage(b.text!, maxChars: 380)) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Text(
                chunk,
                style: const pw.TextStyle(fontSize: 9.5),
              ),
            ),
          );
        }
      } else if (b.type == _DocxBlockType.table &&
          b.rows != null &&
          b.rows!.isNotEmpty) {
        final colCount = b.rows!.first.length;
        final colWidths = <int, pw.TableColumnWidth>{};
        for (int c = 0; c < colCount; c++) {
          if (colCount == 5 && c == 0) {
            colWidths[c] = const pw.FixedColumnWidth(36);
          } else if (colCount == 5 && c == 2) {
            colWidths[c] = const pw.FixedColumnWidth(48);
          } else {
            colWidths[c] = const pw.FlexColumnWidth();
          }
        }

        // Split large tables into chunks of 14 rows so MultiPage never overflows
        for (int start = 0; start < b.rows!.length; start += 14) {
          final end =
              (start + 14 < b.rows!.length) ? start + 14 : b.rows!.length;
          final subRows = b.rows!.sublist(start, end);
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              child: pw.Table(
                border: pw.TableBorder.all(
                  color: pw_pdf.PdfColors.grey600,
                  width: 0.6,
                ),
                columnWidths: colWidths,
                children: subRows.map((row) {
                  final isBannerRow = row.length >= 2 &&
                      row[0].toUpperCase().contains('PREVENTIVE MAINTENANCE');
                  final isHeaderRow = row.any((cell) =>
                      cell.toUpperCase().contains('S. NO') ||
                      cell.toUpperCase().contains('INSTRUMENTS') ||
                      cell.toUpperCase().contains('NORMAL PARAMETERS'));
                  return pw.TableRow(
                    decoration: (isBannerRow || isHeaderRow)
                        ? const pw.BoxDecoration(
                            color: pw_pdf.PdfColors.blue100,
                          )
                        : null,
                    children: row
                        .map(
                          (cell) => pw.Padding(
                            padding: const pw.EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 3,
                            ),
                            child: pw.Text(
                              cell,
                              style: pw.TextStyle(
                                fontSize: 8.5,
                                fontWeight: (isBannerRow || isHeaderRow)
                                    ? pw.FontWeight.bold
                                    : pw.FontWeight.normal,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  );
                }).toList(),
              ),
            ),
          );
        }
      }
    }
    return widgets;
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
      final rawBytes = await File(res.files.single.path!).readAsBytes();
      final content = _normalizePdfSafeText(
        utf8.decode(rawBytes, allowMalformed: true),
      );
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
                  child: pw.Text(line, style: const pw.TextStyle(fontSize: 10.5)),
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

  // 4) DOCX -> PDF (Header, Body with Table Columns, and Footer)
  Future<void> _docxToPdf(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx'],
    );
    if (res == null || res.files.single.path == null) return;

    await _runTask(context, 'Converting DOCX to PDF...', () async {
      final docxBytes = await File(res.files.single.path!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(docxBytes);

      List<_DocxBlock> readBlocks(String entryName) {
        final f = archive.findFile(entryName);
        if (f == null) return const [];
        final raw = f.content;
        final bytes =
            raw is Uint8List ? raw : Uint8List.fromList((raw as List<int>));
        return _parseDocxBlocks(utf8.decode(bytes, allowMalformed: true));
      }

      final headerBlocks = <_DocxBlock>[];
      for (final f in archive.files) {
        if (f.isFile &&
            f.name.startsWith('word/header') &&
            f.name.endsWith('.xml')) {
          headerBlocks.addAll(readBlocks(f.name));
        }
      }

      final bodyBlocks = readBlocks('word/document.xml');

      final footerBlocks = <_DocxBlock>[];
      for (final f in archive.files) {
        if (f.isFile &&
            f.name.startsWith('word/footer') &&
            f.name.endsWith('.xml')) {
          footerBlocks.addAll(readBlocks(f.name));
        }
      }

      final extractedHeader = _blocksToPlainText(headerBlocks);
      final extractedFooter = _blocksToPlainText(footerBlocks);
      final bodyWidgets = _buildPdfWidgetsFromBlocks(bodyBlocks);

      final headerDisplay = extractedHeader.isNotEmpty
          ? extractedHeader
          : 'NUCTECH  |  Nuctech Middle East FZCO';
      final footerDisplay = extractedFooter.isNotEmpty
          ? extractedFooter
          : 'Office 321, Building 5WA, Dubai Airport Free Zone, P.O. Box: 371820, Tel.: +971-4-2602308, www.nuctech.com';

      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(20),
          header: (_) => pw.Container(
            padding: const pw.EdgeInsets.only(bottom: 6),
            margin: const pw.EdgeInsets.only(bottom: 8),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(
                  color: pw_pdf.PdfColors.grey600,
                  width: 0.8,
                ),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                  child: pw.Text(
                    headerDisplay,
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: pw_pdf.PdfColors.blue900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          footer: (ctx) => pw.Container(
            padding: const pw.EdgeInsets.only(top: 6),
            margin: const pw.EdgeInsets.only(top: 8),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                top: pw.BorderSide(
                  color: pw_pdf.PdfColors.grey600,
                  width: 0.8,
                ),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                  child: pw.Text(
                    footerDisplay,
                    style: const pw.TextStyle(
                      fontSize: 7.5,
                      color: pw_pdf.PdfColors.grey800,
                    ),
                  ),
                ),
                pw.SizedBox(width: 8),
                pw.Text(
                  'Page ${ctx.pageNumber}/${ctx.pagesCount}',
                  style: const pw.TextStyle(
                    fontSize: 7.5,
                    color: pw_pdf.PdfColors.grey700,
                  ),
                ),
              ],
            ),
          ),
          build: (_) => bodyWidgets.isEmpty
              ? [
                  pw.Text(
                    '(No text found in DOCX)',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ]
              : bodyWidgets,
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

      final docBytes = utf8.encode(documentXml);
      final ctBytes = utf8.encode(contentTypesXml);
      final relBytes = utf8.encode(relsXml);

      final archive = Archive()
        ..addFile(ArchiveFile('[Content_Types].xml', ctBytes.length, ctBytes))
        ..addFile(ArchiveFile('_rels/.rels', relBytes.length, relBytes))
        ..addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));

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
