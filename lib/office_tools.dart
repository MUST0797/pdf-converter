import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart';

import 'main.dart';

String _baseName(String n) => n.replaceAll(RegExp(r'\.[^.]+$'), '');

// ---------- Generic pick + convert screen ----------

class SinglePickScreen extends StatefulWidget {
  final String title;
  final String extension;
  final IconData icon;
  final Future<File> Function(String path, String name) onConvert;

  const SinglePickScreen({
    super.key,
    required this.title,
    required this.extension,
    required this.icon,
    required this.onConvert,
  });

  @override
  State<SinglePickScreen> createState() => _SinglePickScreenState();
}

class _SinglePickScreenState extends State<SinglePickScreen> {
  String? _path;
  String? _name;
  bool _busy = false;

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [widget.extension],
    );
    if (res == null || res.files.single.path == null) return;
    setState(() {
      _path = res.files.single.path;
      _name = res.files.single.name;
    });
  }

  Future<void> _convert() async {
    setState(() => _busy = true);
    try {
      final file = await widget.onConvert(_path!, _name!);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ResultScreen(file: file)),
      );
    } catch (e) {
      if (mounted) snack(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _pick,
        icon: const Icon(Icons.folder_open),
        label: Text('Select .${widget.extension} file'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _name == null
                  ? Text('.${widget.extension} file select pannunga')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(widget.icon, size: 64),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(_name!, textAlign: TextAlign.center),
                        ),
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
                      : const Icon(Icons.swap_horiz),
                  label: Text(_busy ? 'Converting...' : 'Convert'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- DOCX -> PDF ----------

Future<File> docxToPdf(String path, String name) async {
  final bytes = await File(path).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final entry = archive.findFile('word/document.xml');
  if (entry == null) throw Exception('Idhu valid .docx file illa');
  final xmlStr = utf8.decode(entry.content as List<int>, allowMalformed: true);
  final xml = XmlDocument.parse(xmlStr);
  final bodies = xml.findAllElements('w:body');
  if (bodies.isEmpty) throw Exception('DOCX-la content kidaikkala');

  final widgets = <pw.Widget>[];
  for (final el in bodies.first.children.whereType<XmlElement>()) {
    final tag = el.name.qualified;
    if (tag == 'w:p') {
      widgets.add(_docxParagraph(el));
    } else if (tag == 'w:tbl') {
      widgets.add(_docxTable(el));
    }
  }

  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      maxPages: 2000,
      build: (_) => widgets.isEmpty ? [pw.Text(' ')] : widgets,
    ),
  );

  final dir = await pdfDir();
  final file = File(
      '${dir.path}/${_baseName(name)}_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

pw.Widget _docxParagraph(XmlElement p) {
  final pPr = p.getElement('w:pPr');
  final style = (pPr?.getElement('w:pStyle')?.getAttribute('w:val') ?? '')
      .toLowerCase();
  final jc = pPr?.getElement('w:jc')?.getAttribute('w:val');
  final isHeading = style.startsWith('heading') || style == 'title';

  final spans = <pw.InlineSpan>[];
  for (final r in p.findAllElements('w:r')) {
    final rPr = r.getElement('w:rPr');
    bool flag(String tag) {
      final e = rPr?.getElement(tag);
      if (e == null) return false;
      final v = e.getAttribute('w:val');
      return v != '0' && v != 'false';
    }

    final bold = flag('w:b') || isHeading;
    final italic = flag('w:i');
    final sz = int.tryParse(rPr?.getElement('w:sz')?.getAttribute('w:val') ?? '');
    var size = sz != null ? sz / 2 : 12.0;
    if (isHeading && sz == null) size = 16;

    final text = StringBuffer();
    for (final c in r.children.whereType<XmlElement>()) {
      switch (c.name.qualified) {
        case 'w:t':
          text.write(c.innerText);
          break;
        case 'w:tab':
          text.write('    ');
          break;
        case 'w:br':
          text.write('\n');
          break;
      }
    }
    if (text.isEmpty) continue;

    spans.add(
      pw.TextSpan(
        text: text.toString(),
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
        ),
      ),
    );
  }

  var align = pw.TextAlign.left;
  if (jc == 'center') align = pw.TextAlign.center;
  if (jc == 'right') align = pw.TextAlign.right;
  if (jc == 'both') align = pw.TextAlign.justify;

  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 6),
    child: spans.isEmpty
        ? pw.SizedBox(height: 8)
        : pw.RichText(
            text: pw.TextSpan(children: spans),
            textAlign: align,
          ),
  );
}

pw.Widget _docxTable(XmlElement tbl) {
  final data = <List<String>>[];
  var maxCols = 0;
  for (final tr in tbl.findElements('w:tr')) {
    final row = <String>[];
    for (final tc in tr.findElements('w:tc')) {
      final txt = tc
          .findAllElements('w:p')
          .map((p) => p.findAllElements('w:t').map((t) => t.innerText).join())
          .join('\n');
      row.add(txt);
    }
    if (row.isNotEmpty) {
      data.add(row);
      if (row.length > maxCols) maxCols = row.length;
    }
  }
  if (data.isEmpty) return pw.SizedBox();

  final rows = data.map((row) {
    final cells = <pw.Widget>[
      for (final t in row)
        pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(t, style: const pw.TextStyle(fontSize: 11)),
        ),
    ];
    while (cells.length < maxCols) {
      cells.add(pw.SizedBox());
    }
    return pw.TableRow(children: cells);
  }).toList();

  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Table(border: pw.TableBorder.all(), children: rows),
  );
}

// ---------- PDF -> DOCX ----------

String _xmlEsc(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

Future<File> pdfToDocx(String path, String name) async {
  final bytes = await File(path).readAsBytes();
  final sfDoc = sf.PdfDocument(inputBytes: bytes);
  final extractor = sf.PdfTextExtractor(sfDoc);

  final pages = <List<String>>[];
  var total = 0;
  for (var i = 0; i < sfDoc.pages.count; i++) {
    final t = extractor.extractText(startPageIndex: i, endPageIndex: i);
    total += t.trim().length;
    pages.add(
      t.replaceAll('\r\n', '\n').split('\n').map((l) => l.trimRight()).toList(),
    );
  }
  sfDoc.dispose();

  if (total == 0) {
    throw Exception(
        'Idhu scanned (image) PDF. Text illa, v1-la support illa.');
  }

  final body = StringBuffer();
  for (var i = 0; i < pages.length; i++) {
    for (final line in pages[i]) {
      body.write(
          '<w:p><w:r><w:t xml:space="preserve">${_xmlEsc(line)}</w:t></w:r></w:p>');
    }
    if (i < pages.length - 1) {
      body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
    }
  }

  const header = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  final docXml = '$header'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
      'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>'
      '</w:body></w:document>';

  const contentTypes = '$header'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';

  const rels = '$header'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  final out = Archive();
  void add(String n, String content) {
    final b = utf8.encode(content);
    out.addFile(ArchiveFile(n, b.length, b));
  }

  add('[Content_Types].xml', contentTypes);
  add('_rels/.rels', rels);
  add('word/document.xml', docXml);

  final dir = await pdfDir();
  final file = File(
      '${dir.path}/${_baseName(name)}_${DateTime.now().millisecondsSinceEpoch}.docx');
  await file.writeAsBytes(ZipEncoder().encode(out)!);
  return file;
}
