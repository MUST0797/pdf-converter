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

class _Styles {
  final double size;
  final bool bold;
  final String? color;
  final double after;
  _Styles(this.size, this.bold, this.color, this.after);
}

class _Ctx {
  final Archive archive;
  final Map<String, String> rels;
  final _Styles styles;
  _Ctx(this.archive, this.rels, this.styles);
}

class _PRes {
  final pw.Widget widget;
  final double height;
  _PRes(this.widget, this.height);
}

class _Block {
  final pw.Widget widget;
  final double w;
  final double h;
  _Block(this.widget, this.w, this.h);
}

class _Part {
  final List<pw.Widget> widgets;
  final double height;
  _Part(this.widgets, this.height);
}

double _twips(String? v) => (double.tryParse(v ?? '') ?? 0) / 20;

double _num(XmlElement? el, String name, double def) =>
    double.tryParse(el?.getAttribute(name) ?? '') ?? def;

_Styles _loadStyles(Archive a) {
  var size = 10.5;
  var bold = false;
  String? color;
  var after = 0.0;
  final f = a.findFile('word/styles.xml');
  if (f != null) {
    final doc = XmlDocument.parse(
        utf8.decode(f.content as List<int>, allowMalformed: true));
    void applyRPr(XmlElement? rPr) {
      if (rPr == null) return;
      final sz = int.tryParse(rPr.getElement('w:sz')?.getAttribute('w:val') ?? '');
      if (sz != null) size = sz / 2;
      final b = rPr.getElement('w:b');
      if (b != null) {
        final v = b.getAttribute('w:val');
        bold = v != '0' && v != 'false';
      }
      final c = rPr.getElement('w:color')?.getAttribute('w:val');
      if (c != null && c.length == 6) color = c;
    }

    void applyPPr(XmlElement? pPr) {
      final v = pPr?.getElement('w:spacing')?.getAttribute('w:after');
      if (v != null) after = _twips(v);
    }

    final dd = doc.findAllElements('w:docDefaults').firstOrNull;
    applyRPr(dd?.getElement('w:rPrDefault')?.getElement('w:rPr'));
    applyPPr(dd?.getElement('w:pPrDefault')?.getElement('w:pPr'));
    for (final st in doc.findAllElements('w:style')) {
      if (st.getAttribute('w:type') == 'paragraph' &&
          st.getAttribute('w:default') == '1') {
        applyRPr(st.getElement('w:rPr'));
        applyPPr(st.getElement('w:pPr'));
      }
    }
  }
  return _Styles(size, bold, color, after);
}

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

// Wingdings codes that mean "checked box"; everything else = empty box
const _checkedCodes = {0xFE, 0xFD, 0xFC, 0xFB, 0x52};

pw.InlineSpan _boxSpan(double size, bool checked, bool shaded) {
  final s = size * 0.8;
  return pw.WidgetSpan(
    child: pw.Container(
      width: s,
      height: s,
      margin: const pw.EdgeInsets.only(right: 1),
      decoration: pw.BoxDecoration(
        color: shaded ? PdfColors.grey400 : null,
        border: pw.Border.all(width: 0.8),
      ),
      child: checked
          ? pw.Container(
              margin: const pw.EdgeInsets.all(2), color: PdfColors.black)
          : null,
    ),
  );
}

// Inline drawing: single picture or a group (logo + title, footer image + line)
_Block? _drawing(XmlElement inl, _Ctx ctx, double maxW) {
  final ext = inl.getElement('wp:extent');
  final cx = _num(ext, 'cx', 0);
  final cy = _num(ext, 'cy', 0);
  if (cx <= 0 || cy <= 0) return null;
  const emu = 12700.0;
  final gw = cx / emu;
  final gh = cy / emu;
  final k = gw > maxW ? maxW / gw : 1.0;

  final grp = inl.findAllElements('wpg:wgp').firstOrNull;
  if (grp == null) {
    final blip = inl.findAllElements('a:blip').firstOrNull;
    final img = _loadImage(ctx, blip?.getAttribute('r:embed'));
    if (img == null) return null;
    return _Block(
        pw.Image(img, width: gw * k, height: gh * k), gw * k, gh * k);
  }

  final xf = grp.getElement('wpg:grpSpPr')?.getElement('a:xfrm');
  final gx = _num(xf?.getElement('a:ext'), 'cx', cx);
  final gy = _num(xf?.getElement('a:ext'), 'cy', cy);
  final chx = _num(xf?.getElement('a:chExt'), 'cx', gx);
  final chy = _num(xf?.getElement('a:chExt'), 'cy', gy);
  final sx = chx > 0 ? gx / chx : 1.0;
  final sy = chy > 0 ? gy / chy : 1.0;

  final items = <pw.Widget>[];
  for (final pic in grp.findAllElements('pic:pic')) {
    final blip = pic.findAllElements('a:blip').firstOrNull;
    final img = _loadImage(ctx, blip?.getAttribute('r:embed'));
    final xfrm = pic.findAllElements('a:xfrm').firstOrNull;
    if (img == null || xfrm == null) continue;
    final ox = _num(xfrm.getElement('a:off'), 'x', 0);
    final oy = _num(xfrm.getElement('a:off'), 'y', 0);
    final ew = _num(xfrm.getElement('a:ext'), 'cx', 0);
    final eh = _num(xfrm.getElement('a:ext'), 'cy', 0);
    if (ew <= 0 || eh <= 0) continue;
    items.add(
      pw.Positioned(
        left: ox * sx / emu * k,
        top: oy * sy / emu * k,
        child: pw.Image(img, width: ew * sx / emu * k, height: eh * sy / emu * k),
      ),
    );
  }
  for (final wsp in grp.findAllElements('wps:wsp')) {
    final xfrm = wsp.findAllElements('a:xfrm').firstOrNull;
    if (xfrm == null) continue;
    final ew = _num(xfrm.getElement('a:ext'), 'cx', 0);
    final eh = _num(xfrm.getElement('a:ext'), 'cy', 0);
    // only thin horizontal lines (footer rule)
    if (ew < 100000 || eh > 38100) continue;
    final ox = _num(xfrm.getElement('a:off'), 'x', 0);
    final oy = _num(xfrm.getElement('a:off'), 'y', 0);
    items.add(
      pw.Positioned(
        left: ox * sx / emu * k,
        top: oy * sy / emu * k,
        child: pw.SizedBox(
          width: ew * sx / emu * k,
          height: 0.7,
          child: pw.Container(color: PdfColors.black),
        ),
      ),
    );
  }
  return _Block(
    pw.SizedBox(
      width: gw * k,
      height: gh * k,
      child: pw.Stack(children: items),
    ),
    gw * k,
    gh * k,
  );
}

_PRes _paragraph(XmlElement p, _Ctx ctx, double width) {
  final st = ctx.styles;
  final pPr = p.getElement('w:pPr');
  final jc = pPr?.getElement('w:jc')?.getAttribute('w:val');
  final numbered = pPr?.getElement('w:numPr') != null;
  final markSz = int.tryParse(
      pPr?.getElement('w:rPr')?.getElement('w:sz')?.getAttribute('w:val') ??
          '');
  final markSize = markSz != null ? markSz / 2 : st.size;
  final spAfter = pPr?.getElement('w:spacing')?.getAttribute('w:after');
  final after = spAfter != null ? _twips(spAfter) : st.after;

  final spans = <pw.InlineSpan>[];
  final blocks = <_Block>[];
  var maxSize = 0.0;
  var textW = 0.0;
  var breaks = 0;

  for (final r in p.findAllElements('w:r')) {
    final rPr = r.getElement('w:rPr');
    bool flag(String tag, bool def) {
      final e = rPr?.getElement(tag);
      if (e == null) return def;
      final v = e.getAttribute('w:val');
      return v != '0' && v != 'false';
    }

    final bold = flag('w:b', st.bold);
    final italic = flag('w:i', false);
    final sz = int.tryParse(rPr?.getElement('w:sz')?.getAttribute('w:val') ?? '');
    final size = sz != null ? sz / 2 : st.size;
    final hex = rPr?.getElement('w:color')?.getAttribute('w:val') ?? st.color;
    PdfColor? color;
    if (hex != null && hex.length == 6 && hex != 'auto') {
      color = PdfColor.fromHex('#$hex');
    }
    final u = rPr?.getElement('w:u')?.getAttribute('w:val');
    final fontName =
        (rPr?.getElement('w:rFonts')?.getAttribute('w:ascii') ?? '').toLowerCase();
    final isSym = fontName.startsWith('wingdings');
    final shaded = rPr?.getElement('w:highlight') != null;
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
          if (isSym) {
            flush();
            for (final rune in t.runes) {
              spans.add(_boxSpan(size, _checkedCodes.contains(rune & 0xFF), shaded));
              textW += size * 1.2;
            }
          } else {
            text.write(t);
            textW += t.length * size * (bold ? 0.68 : 0.58);
          }
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
          final code = int.tryParse(c.getAttribute('w:char') ?? '', radix: 16) ?? 0;
          spans.add(_boxSpan(size, _checkedCodes.contains(code & 0xFF), shaded));
          textW += size * 1.2;
          break;
      }
    }
    flush();

    for (final inl in r.findAllElements('wp:inline')) {
      final b = _drawing(inl, ctx, width);
      if (b != null) blocks.add(b);
    }
  }

  // Paragraph with drawings (logo, footer image etc.)
  if (blocks.isNotEmpty) {
    var h = 0.0;
    for (final b in blocks) {
      if (b.h > h) h = b.h;
    }
    var align = pw.MainAxisAlignment.start;
    if (blocks.length > 1) {
      align = pw.MainAxisAlignment.spaceBetween;
    } else if (jc == 'center') {
      align = pw.MainAxisAlignment.center;
    } else if (jc == 'right') {
      align = pw.MainAxisAlignment.end;
    }
    return _PRes(
      pw.Row(
        mainAxisAlignment: align,
        children: [for (final b in blocks) b.widget],
      ),
      h + 2,
    );
  }

  // Empty paragraph
  if (spans.isEmpty) {
    final h = markSize * 1.25 + after;
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
  final h = lines * size * 1.3 + after;

  var ta = pw.TextAlign.left;
  if (jc == 'center') ta = pw.TextAlign.center;
  if (jc == 'right') ta = pw.TextAlign.right;

  pw.Widget w = pw.RichText(text: pw.TextSpan(children: spans), textAlign: ta);
  if (numbered) {
    w = pw.Padding(padding: const pw.EdgeInsets.only(left: 12), child: w);
  }
  if (after > 0) {
    w = pw.Padding(padding: pw.EdgeInsets.only(bottom: after), child: w);
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

_Part _buildPart(Archive a, String? path, double width, _Styles styles) {
  if (path == null) return _Part([], 0);
  final f = a.findFile(path);
  if (f == null) return _Part([], 0);
  final xml = XmlDocument.parse(
      utf8.decode(f.content as List<int>, allowMalformed: true));
  final ctx = _Ctx(a, _loadRels(a, path), styles);
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
      utf8.decode(entry.content as List
