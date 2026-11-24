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
  final double fit;
  _Ctx(this.archive, this.rels, this.styles, [this.fit = 1.0]);
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
  final String? align;
  _Block(this.widget, this.w, this.h, [this.align]);
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

// Built-in PDF fonts only support Latin-1; map common symbols to safe text
String _sanitize(String s) {
  const map = {
    '\u2013': '-',
    '\u2014': '-',
    '\u2212': '-',
    '\u2264': '<=',
    '\u2265': '>=',
    '\u2018': "'",
    '\u2019': "'",
    '\u201C': '"',
    '\u201D': '"',
    '\u2026': '...',
    '\u2022': '-',
    '\u00A0': ' ',
    '\u2192': '->',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    b.write(map[ch] ?? ch);
  }
  return b.toString();
}

_PRes _paragraph(XmlElement p, _Ctx ctx, double width) {
  final st = ctx.styles;
  final pPr = p.getElement('w:pPr');
  var jc = pPr?.getElement('w:jc')?.getAttribute('w:val');
  final tabEls = pPr?.getElement('w:tabs')?.findElements('w:tab').toList() ??
      <XmlElement>[];
  final hasCenterTab = tabEls.any((t) => t.getAttribute('w:val') == 'center');
  final hasRightTab = tabEls.any((t) => t.getAttribute('w:val') == 'right');
  final firstRun = p.findAllElements('w:r').firstOrNull;
  final firstKid = firstRun?.children
      .whereType<XmlElement>()
      .where((c) => c.name.qualified != 'w:rPr')
      .firstOrNull;
  String? tabAlign;
  if (jc == null && firstKid?.name.qualified == 'w:tab') {
    if (hasCenterTab) {
      tabAlign = 'center';
    } else if (hasRightTab) {
      tabAlign = 'right';
    }
  }
  if (tabAlign != null) jc = tabAlign;
  final numbered = pPr?.getElement('w:numPr') != null;
  final markSz = int.tryParse(
      pPr?.getElement('w:rPr')?.getElement('w:sz')?.getAttribute('w:val') ??
          '');
  final markSize = (markSz != null ? markSz / 2 : st.size) * ctx.fit;
  final spAfter = pPr?.getElement('w:spacing')?.getAttribute('w:after');
  final after = (spAfter != null ? _twips(spAfter) : st.after) * ctx.fit;

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
    final font0 =
        (rPr?.getElement('w:rFonts')?.getAttribute('w:ascii') ?? '').toLowerCase();
    // Calibri is narrower than Helvetica: shrink a bit to keep the same wrapping
    final scale = font0.startsWith('calibri') ? 0.84 : 1.0;
    final size = (sz != null ? sz / 2 : st.size) * scale * ctx.fit;
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
          final t = _sanitize(c.innerText);
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
          if (tabAlign != null && spans.isEmpty && text.isEmpty) break;
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

    for (final inl in [
      ...r.findAllElements('wp:inline'),
      ...r.findAllElements('wp:anchor'),
    ]) {
      final b = _drawing(inl, ctx, width);
      if (b != null) {
        final al =
            inl.getElement('wp:positionH')?.getElement('wp:align')?.innerText;
        blocks.add(al == null ? b : _Block(b.widget, b.w, b.h, al));
      }
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
    } else if (jc == 'center' || blocks.first.align == 'center') {
      align = pw.MainAxisAlignment.center;
    } else if (jc == 'right' || blocks.first.align == 'right') {
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

pw.Widget _tableGroup(List<XmlElement> trs, List<double> ws, _Ctx ctx,
    double contentW, double padL, double padR) {
  var total = 0.0;
  for (final w in ws) {
    total += w;
  }
  final colWidths = <int, pw.TableColumnWidth>{
    for (var i = 0; i < ws.length; i++) i: pw.FlexColumnWidth(ws[i]),
  };
  final rows = <pw.TableRow>[];
  for (final tr in trs) {
    final trH = _twips(
        tr.getElement('w:trPr')?.getElement('w:trHeight')?.getAttribute('w:val'));
    final cells = tr.findElements('w:tc').toList();
    final kids = <pw.Widget>[];
    for (var i = 0; i < cells.length; i++) {
      final fill =
          cells[i].getElement('w:tcPr')?.getElement('w:shd')?.getAttribute('w:fill');
      PdfColor? bg;
      if (fill != null && fill.length == 6 && fill.toUpperCase() != 'FFFFFF') {
        bg = PdfColor.fromHex('#$fill');
      }
      final inner = ws[i] / total * contentW - padL - padR;
      final paras = <pw.Widget>[];
      for (final p in cells[i].findElements('w:p')) {
        paras.add(_paragraph(p, ctx, inner).widget);
      }
      kids.add(
        pw.Container(
          color: bg,
          constraints:
              trH > 0 ? pw.BoxConstraints(minHeight: trH * ctx.fit) : null,
          padding: pw.EdgeInsets.fromLTRB(padL, ctx.fit, padR, ctx.fit),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisSize: pw.MainAxisSize.min,
            children: paras,
          ),
        ),
      );
    }
    rows.add(pw.TableRow(children: kids));
  }
  return pw.Table(
    columnWidths: colWidths,
    border: pw.TableBorder.all(width: 0.4),
    defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
    children: rows,
  );
}

// Rows with the same column widths go in one table; row height = natural
// text height (so nothing gets clipped and everything fits like Word).
List<pw.Widget> _docxTable(XmlElement tbl, _Ctx ctx, double contentW) {
  final out = <pw.Widget>[];
  final mar = tbl.getElement('w:tblPr')?.getElement('w:tblCellMar');
  final padL = math.min(
      4.5, _twips(mar?.getElement('w:left')?.getAttribute('w:w') ?? '108'));
  final padR = math.min(
      4.5, _twips(mar?.getElement('w:right')?.getAttribute('w:w') ?? '108'));
  List<XmlElement> group = [];
  List<double> groupW = [];
  for (final tr in tbl.findElements('w:tr')) {
    final cells = tr.findElements('w:tc').toList();
    if (cells.isEmpty) continue;
    final ws = <double>[
      for (final tc in cells)
        _num(tc.getElement('w:tcPr')?.getElement('w:tcW'), 'w:w', 1000),
    ];
    var same = group.isNotEmpty && ws.length == groupW.length;
    if (same) {
      for (var i = 0; i < ws.length; i++) {
        if ((ws[i] - groupW[i]).abs() > 1) {
          same = false;
          break;
        }
      }
    }
    if (!same && group.isNotEmpty) {
      out.add(_tableGroup(group, groupW, ctx, contentW, padL, padR));
      group = [];
    }
    groupW = ws;
    group.add(tr);
  }
  if (group.isNotEmpty) {
    out.add(_tableGroup(group, groupW, ctx, contentW, padL, padR));
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

  final styles = _loadStyles(archive);
  final docRels = _loadRels(archive, 'word/document.xml');
  String? refPath(String tag) {
    final id = sect?.getElement(tag)?.getAttribute('r:id');
    return id == null ? null : docRels[id];
  }

  // Build the PDF; fit < 1 shrinks text a little (used when only a few rows
  // spill over to an extra page)
  Future<Uint8List> render(double fit) async {
    final header =
        _buildPart(archive, refPath('w:headerReference'), contentW, styles);
    final footer =
        _buildPart(archive, refPath('w:footerReference'), contentW, styles);
    final hasHeader = header.widgets.isNotEmpty;
    final hasFooter = footer.widgets.isNotEmpty;
    final headerPad = math.max(0.0, (mt - hd) - header.height) + 4;

    final ctx = _Ctx(archive, docRels, styles, fit);
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
    return await doc.save();
  }

  int pageCount(Uint8List b) {
    final d = sf.PdfDocument(inputBytes: b);
    final n = d.pages.count;
    d.dispose();
    return n;
  }

  var out = await render(1.0);
  final base = pageCount(out);
  if (base > 1) {
    for (final f in const [0.95, 0.9, 0.85]) {
      final t = await render(f);
      if (pageCount(t) < base) {
        out = t;
        break;
      }
    }
  }

  final dir = await pdfDir();
  final file = File(
      '${dir.path}/${_baseName(name)}_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await file.writeAsBytes(out);
  return file;
}
