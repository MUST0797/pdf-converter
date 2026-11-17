import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

class _Ctx {
  final Archive archive;
  final Map<String, String> rels;
  _Ctx(this.archive, this.rels);
}

class _PRes {
  final pw.Widget widget;
  final double height;
  _PRes(this.widget, this.height);
}

class _Img {
  final pw.MemoryImage image;
  final double w;
  final double h;
  _Img(this.image, this.w, this.h);
}

class _Part {
  final List<pw.Widget> widgets;
  final double height;
  _Part(this.widgets, this.height);
}

double _twips(String? v) => (double.tryParse(v ?? '') ?? 0) / 20;

Map<String, String> _loadRels(Archive a, String partPath) {
  final idx = partPath.lastIndexOf('/');
  final dir = partPath.substring(0, idx);
  final name = partPath.substring(idx + 1);
  final map = <String, String>{};
  final f = a.findFile('$dir/_rels/$name.rels');
  if (f == null) return map;
  final doc = XmlDocument.parse(
      utf8.decode(f.content as List<int>, allowMalformed: true));
  for (final r in doc.findAllElements('Relationship')) {
    final id = r.getAttribute('Id');
    final t = r.getAttribute('Target');
    if (id != null && t != null) {
      map[id] = t.startsWith('/') ? t.substring(1) : '$dir/$t';
    }
  }
  return map;
}

pw.MemoryImage? _loadImage(_Ctx c, String? rid) {
  if (rid == null) return null;
  final path = c.rels[rid];
  if (path == null) return null;
  final f = c.archive.findFile(path);
  if (f == null) return null;
  try {
    return pw.MemoryImage(Uint8List.fromList(f.content as List<int>));
  } catch (_) {
    return null;
  }
}

pw.InlineSpan _checkBox(XmlElement sym, double size) {
  final ch = (sym.getAttribute('w:char') ?? '').toLowerCase();
  const checked = {'f0fe', 'f0fd', 'f0fc', 'f0fb', 'f052'};
  final s = size * 0.8;
  final isChecked = checked.contains(ch);
  return pw.WidgetSpan(
    child: pw.Container(
      width: s,
      height: s,
      margin: const pw.EdgeInsets.only(right: 1),
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)),
      child: isChecked
          ? pw.Container(
              margin: const pw.EdgeInsets.all(2), color: PdfColors.black)
          : null,
    ),
  );
}

_PRes _paragraph(XmlElement p, _Ctx ctx, double width) {
  final pPr = p.getElement('w:pPr');
  final jc = pPr?.getElement('w:jc')?.getAttribute('w:val');
  final numbered = pPr?.getElement('w:numPr') != null;
  final markSz = int.tryParse(
      pPr?.getElement('w:rPr')?.getElement('w:sz')?.getAttribute('w:val') ??
          '');
  final markSize = markSz != null ? markSz / 2 : 10.5;

  final spans = <pw.InlineSpan>[];
  final images = <_Img>[];
  var maxSize = 0.0;
  var textW = 0.0;
  var breaks = 0;

  for (final r in p.findAllElements('w:r')) {
    final rPr = r.getElement('w:rPr');
    bool flag(String tag) {
      final e = rPr?.getElement(tag);
      if (e == null) return false;
      final v = e.getAttribute('w:val');
      return v != '0' && v != 'false';
    }

    final bold = flag('w:b');
    final italic = flag('w:i');
    final sz = int.tryParse(rPr?.getElement('w:sz')?.getAttribute('w:val') ?? '');
    final size = sz != null ? sz / 2 : 10.5;
    final hex = rPr?.getElement('w:color')?.getAttribute('w:val');
    PdfColor? color;
    if (hex != null && hex.length == 6 && hex != 'auto') {
      color = PdfColor.fromHex('#$hex');
    }
    final u = rPr?.getElement('w:u')?.getAttribute('w:val');
    final style = pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
      color: color,
      decoration:
          (u != null && u != 'none') ? pw.TextDecoration.underline : null,
    );
    if (size > maxSize) maxSize = size;

    final text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) {
        spans.add(pw.TextSpan(text: text.toString(), style: style));
        text.clear();
      }
    }

    for (final c in r.children.whereType<XmlElement>()) {
      switch (c.name.qualified) {
        case 'w:t':
          final t = c.innerText;
          text.write(t);
          textW += t.length * size * (bold ? 0.68 : 0.58);
          break;
        case 'w:tab':
          text.write('    ');
          textW += size * 1.2;
          break;
        case 'w:br':
          text.write('\n');
          breaks++;
          break;
        case 'w:sym':
          flush();
          spans.add(_checkBox(c, size));
          textW += size * 1.2;
          break;
      }
    }
    flush();

    for (final inl in r.findAllElements('wp:inline')) {
      final ext = inl.getElement('wp:extent');
      final blip = inl.findAllElements('a:blip').firstOrNull;
      final img = _loadImage(ctx, blip?.getAttribute('r:embed'));
      if (img == null || ext == null) continue;
      final cx = double.tryParse(ext.getAttribute('cx') ?? '') ?? 0;
      final cy = double.tryParse(ext.getAttribute('cy') ?? '') ?? 0;
      if (cx <= 0 || cy <= 0) continue;
      images.add(_Img(img, cx / 12700, cy / 12700));
    }
  }

  // Paragraph with inline images (logo etc.)
  if (images.isNotEmpty) {
    var totalW = 0.0;
    for (final i in images) {
      totalW += i.w;
    }
    final k = totalW > width ? width / totalW : 1.0;
    var h = 0.0;
    for (final i in images) {
      if (i.h * k > h) h = i.h * k;
    }
    var align = pw.MainAxisAlignment.start;
    if (images.length > 1) {
      align = pw.MainAxisAlignment.spaceBetween;
    } else if (jc == 'center') {
      align = pw.MainAxisAlignment.center;
    } else if (jc == 'right') {
      align = pw.MainAxisAlignment.end;
    }
    return _PRes(
      pw.Row(
        mainAxisAlignment: align,
        children: [
          for (final i in images)
            pw.Image(i.image, width: i.w * k, height: i.h * k),
        ],
      ),
      h + 2,
    );
  }

  // Empty paragraph
  if (spans.isEmpty) {
    final h = markSize * 1.25;
    return _PRes(pw.SizedBox(height: h), h);
  }

  final size = maxSize > 0 ? maxSize : markSize;
  var avail = width;
  if (numbered) {
    spans.insert(0, pw.TextSpan(text: '-  ', style: pw.TextStyle(fontSize: size)));
    avail = width - 12;
  }
  var lines = (textW / (avail < 1 ? 1 : avail)).ceil();
  if (lines < 1) lines = 1;
  lines += breaks;
  final h = lines * size * 1.3;

  var ta = pw.TextAlign.left;
  if (jc == 'center') ta = pw.TextAlign.center;
  if (jc == 'right') ta = pw.TextAlign.right;

  pw.Widget w = pw.RichText(text: pw.TextSpan(children: spans), textAlign: ta);
  if (numbered) {
    w = pw.Padding(padding: const pw.EdgeInsets.only(left: 12), child: w);
  }
  return _PRes(w, h);
}

List<pw.Widget> _docxTable(XmlElement tbl, _Ctx ctx, double contentW) {
  final out = <pw.Widget>[];
  for (final tr in tbl.findElements('w:tr')) {
    final trH = _twips(
        tr.getElement('w:trPr')?.getElement('w:trHeight')?.getAttribute('w:val'));
    final cells = tr.findElements('w:tc').toList();
    if (cells.isEmpty) continue;

    final ws = <double>[];
    var total = 0.0;
    for (final tc in cells) {
      final w = double.tryParse(
              tc.getElement('w:tcPr')?.getElement('w:tcW')?.getAttribute('w:w') ??
                  '') ??
          1000;
      ws.add(w);
      total += w;
    }

    var rowH = trH;
    final cellWidgets = <pw.Widget>[];
    for (var i = 0; i < cells.length; i++) {
      final cw = ws[i] / total * contentW;
      final inner = cw - 10.8;
      final kids = <pw.Widget>[];
      var h = 3.0;
      for (final p in cells[i].findElements('w:p')) {
        final res = _paragraph(p, ctx, inner);
        kids.add(res.widget);
        h += res.height;
      }
      if (h > rowH) rowH = h;
      cellWidgets.add(
        pw.Expanded(
          flex: ws[i].round(),
          child: pw.Container(
            padding: const pw.EdgeInsets.fromLTRB(5.4, 2, 5.4, 0),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: kids,
            ),
          ),
        ),
      );
    }
    out.add(
      pw.SizedBox(
        height: rowH,
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: cellWidgets,
        ),
      ),
    );
  }
  return out;
}

_Part _buildPart(Archive a, String? path, double width) {
  if (path == null) return _Part([], 0);
  final f = a.findFile(path);
  if (f == null) return _Part([], 0);
  final xml = XmlDocument.parse(
      utf8.decode(f.content as List<int>, allowMalformed: true));
  final ctx = _Ctx(a, _loadRels(a, path));
  final out = <pw.Widget>[];
  var h = 0.0;
  for (final p in xml.rootElement.children.whereType<XmlElement>()) {
    if (p.name.qualified != 'w:p') continue;
    final hasRule = p
        .findAllElements('wp:anchor')
        .any((an) => an.findAllElements('a:blip').isEmpty);
    if (hasRule) {
      out.add(pw.SizedBox(
          width: width,
          height: 0.7,
          child: pw.Container(color: PdfColors.black)));
      out.add(pw.SizedBox(height: 3));
      h += 3.7;
    }
    final r = _paragraph(p, ctx, width);
    out.add(r.widget);
    h += r.height;
  }
  return _Part(out, h);
}

Future<File> docxToPdf(String path, String name) async {
  final bytes = await File(path).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final entry = archive.findFile('word/document.xml');
  if (entry == null) throw Exception('Idhu valid .docx file illa');
  final xml = XmlDocument.parse(
      utf8.decode(entry.content as List<int>, allowMalformed: true));
  final bodies = xml.findAllElements('w:body');
  if (bodies.isEmpty) throw Exception('DOCX-la content kidaikkala');
  final body = bodies.first;

  // Page setup
  final sect = body.getElement('w:sectPr');
  final pgSz = sect?.getElement('w:pgSz');
  final pgMar = sect?.getElement('w:pgMar');
  double tw(XmlElement? e, String attr, double def) {
    final v = double.tryParse(e?.getAttribute(attr) ?? '');
    return v == null ? def : v / 20;
  }

  final pageW = tw(pgSz, 'w:w', 595.3);
  final pageH = tw(pgSz, 'w:h', 841.9);
  final mt = tw(pgMar, 'w:top', 72);
  final mb = tw(pgMar, 'w:bottom', 72);
  final ml = tw(pgMar, 'w:left', 72);
  final mr = tw(pgMar, 'w:right', 72);
  final hd = tw(pgMar, 'w:header', 36);
  final fd = tw(pgMar, 'w:footer', 36);
  final contentW = pageW - ml - mr;

  // Header / footer
  final docRels = _loadRels(archive, 'word/document.xml');
  String? refPath(String tag) {
    final id = sect?.getElement(tag)?.getAttribute('r:id');
    return id == null ? null : docRels[id];
  }

  final header = _buildPart(archive, refPath('w:headerReference'), contentW);
  final footer = _buildPart(archive, refPath('w:footerReference'), contentW);
  final hasHeader = header.widgets.isNotEmpty;
  final hasFooter = footer.widgets.isNotEmpty;
  final headerPad = math.max(0.0, (mt - hd) - header.height) + 4;

  // Body
  final ctx = _Ctx(archive, docRels);
  final widgets = <pw.Widget>[];
  for (final el in body.children.whereType<XmlElement>()) {
    final tag = el.name.qualified;
    if (tag == 'w:p') {
      widgets.add(_paragraph(el, ctx, contentW).widget);
    } else if (tag == 'w:tbl') {
      widgets.addAll(_docxTable(el, ctx, contentW));
    }
  }

  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat(pageW, pageH),
      margin: pw.EdgeInsets.fromLTRB(
          ml, hasHeader ? hd : mt, mr, hasFooter ? fd : mb),
      maxPages: 2000,
      header: hasHeader
          ? (pw.Context c) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [...header.widgets, pw.SizedBox(height: headerPad)],
              )
          : null,
      footer: hasFooter
          ? (pw.Context c) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: footer.widgets,
              )
          : null,
      build: (_) => widgets.isEmpty ? [pw.Text(' ')] : widgets,
    ),
  );

  final dir = await pdfDir();
  final file = File(
      '${dir.path}/${_baseName(name)}_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
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
