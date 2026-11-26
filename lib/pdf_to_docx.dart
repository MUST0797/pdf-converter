import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:archive/archive.dart';
import 'package:printing/printing.dart' show Printing;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'main.dart';

String _baseName(String n) => n.replaceAll(RegExp(r'\.[^.]+$'), '');

// ---------- PDF -> DOCX ----------

String _xmlEsc(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

class _PW {
  final String text;
  final double x0;
  final double x1;
  final double top;
  final double bottom;
  final double size;
  final bool bold;
  final bool italic;
  final String family;
  _PW(this.text, this.x0, this.x1, this.top, this.bottom, this.size, this.bold,
      this.italic, this.family);
  double get cy => (top + bottom) / 2;
  double get cx => (x0 + x1) / 2;
}

String _family(String fontName) {
  var f = fontName;
  final plus = f.indexOf('+');
  if (plus >= 0 && plus <= 7) f = f.substring(plus + 1);
  f = f.split(RegExp(r'[-,]'))[0];
  f = f.replaceAll(RegExp(r'(MT|PS)$'), '');
  return f.isEmpty ? 'Arial' : f;
}

// Group words that sit on the same visual line
List<List<_PW>> _clusterRows(List<_PW> words) {
  final sorted = [...words]..sort((a, b) => a.cy.compareTo(b.cy));
  final rows = <List<_PW>>[];
  final cys = <double>[];
  for (final w in sorted) {
    if (rows.isNotEmpty) {
      final tol = 0.45 * math.max(w.size, rows.last.first.size);
      if ((w.cy - cys.last).abs() <= tol) {
        rows.last.add(w);
        var sum = 0.0;
        for (final x in rows.last) {
          sum += x.cy;
        }
        cys[cys.length - 1] = sum / rows.last.length;
        continue;
      }
    }
    rows.add([w]);
    cys.add(w.cy);
  }
  return rows;
}

// ----- table (box / column) detection from the rendered page image -----

class _Ln {
  int ps;
  int pe;
  int a;
  int b;
  _Ln(this.ps, this.pe, this.a, this.b);
}

class _Hl {
  final double pos;
  final double a;
  final double b;
  _Hl(this.pos, this.a, this.b);
}

class _Grid {
  final List<_Hl> h;
  final List<_Hl> v;
  _Grid(this.h, this.v);
}

class _TRow {
  final double top;
  final double bottom;
  final List<double> xs;
  _TRow(this.top, this.bottom, this.xs);
}

class _Fill {
  final String hex;
  final bool dark;
  _Fill(this.hex, this.dark);
}

class _PageData {
  final List<_PW> words;
  final List<_TRow> rows;
  final List<List<_Fill?>> fills;
  _PageData(this.words, this.rows, this.fills);
}

class _Item {
  final double top;
  final double bottom;
  final String xml;
  final bool para;
  _Item(this.top, this.bottom, this.xml, this.para);
}

List<List<int>> _runs(int n, bool Function(int) at, int minLen) {
  final out = <List<int>>[];
  var i = 0;
  while (i < n) {
    if (at(i)) {
      var j = i;
      var last = i;
      while (j + 1 < n && (at(j + 1) || (j + 2 < n && at(j + 2)))) {
        j++;
        if (at(j)) last = j;
      }
      if (last - i + 1 >= minLen) out.add([i, last]);
      i = last + 1;
    } else {
      i++;
    }
  }
  return out;
}

List<_Ln> _mergeLines(List<MapEntry<int, List<List<int>>>> perRow) {
  final lines = <_Ln>[];
  var active = <_Ln>[];
  for (final e in perRow) {
    final pos = e.key;
    final fresh = <_Ln>[];
    for (final r in e.value) {
      final a = r[0];
      final b = r[1];
      _Ln? hit;
      for (final ln in active) {
        final ov = math.min(b, ln.b) - math.max(a, ln.a);
        if (ln.pe >= pos - 2 && ov >= 0.5 * math.min(b - a, ln.b - ln.a)) {
          hit = ln;
          break;
        }
      }
      if (hit != null) {
        hit.pe = pos;
        hit.a = math.min(hit.a, a);
        hit.b = math.max(hit.b, b);
        fresh.add(hit);
      } else {
        final ln = _Ln(pos, pos, a, b);
        lines.add(ln);
        fresh.add(ln);
      }
    }
    for (final ln in active) {
      if (!fresh.contains(ln) && ln.pe >= pos - 2) fresh.add(ln);
    }
    active = fresh;
  }
  return lines;
}

List<double> _cluster(List<double> vals, double tol) {
  final v = [...vals]..sort();
  final groups = <List<double>>[];
  for (final x in v) {
    if (groups.isNotEmpty && x - groups.last.last <= tol) {
      groups.last.add(x);
    } else {
      groups.add([x]);
    }
  }
  return [
    for (final g in groups) g.reduce((a, b) => a + b) / g.length,
  ];
}

_Grid _detectGrid(Uint8List px, int w, int h, double dpi) {
  final mask = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    final a = px[i * 4 + 3];
    final r = 255 - a * (255 - px[i * 4]) ~/ 255;
    final g = 255 - a * (255 - px[i * 4 + 1]) ~/ 255;
    final b = 255 - a * (255 - px[i * 4 + 2]) ~/ 255;
    if ((r + g + b) ~/ 3 < 150) mask[i] = 1;
  }
  final hMin = (0.6 * dpi).round();
  final vMin = (0.17 * dpi).round();

  final hrows = <MapEntry<int, List<List<int>>>>[];
  for (var y = 0; y < h; y++) {
    final r = _runs(w, (x) => mask[y * w + x] == 1, hMin);
    if (r.isNotEmpty) hrows.add(MapEntry(y, r));
  }
  final vcols = <MapEntry<int, List<List<int>>>>[];
  for (var x = 0; x < w; x++) {
    final r = _runs(h, (y) => mask[y * w + x] == 1, vMin);
    if (r.isNotEmpty) vcols.add(MapEntry(x, r));
  }

  final hl = <_Hl>[];
  for (final l in _mergeLines(hrows)) {
    if (l.pe - l.ps + 1 <= 6) {
      hl.add(_Hl((l.ps + l.pe) / 2, l.a.toDouble(), l.b.toDouble()));
    }
  }
  final vAll = <_Hl>[];
  for (final l in _mergeLines(vcols)) {
    if (l.pe - l.ps + 1 <= 6) {
      vAll.add(_Hl((l.ps + l.pe) / 2, l.a.toDouble(), l.b.toDouble()));
    }
  }
  bool nearH(double y) => hl.any((x) => (x.pos - y).abs() <= 4);
  final vl = vAll.where((l) => nearH(l.a) && nearH(l.b)).toList();
  return _Grid(hl, vl);
}

List<_TRow> _buildRows(_Grid g) {
  final ys = _cluster([for (final h in g.h) h.pos], 3);
  final rows = <_TRow>[];
  for (var i = 0; i + 1 < ys.length; i++) {
    final a = ys[i];
    final b = ys[i + 1];
    if (b - a < 6) continue;
    final xs = _cluster([
      for (final v in g.v)
        if (v.a <= a + 4 && v.b >= b - 4) v.pos,
    ], 3);
    if (xs.length < 2) continue;
    bool covered(double y) {
      var tot = 0.0;
      for (final h in g.h) {
        if ((h.pos - y).abs() <= 3) {
          final lo = math.max(h.a, xs.first - 3);
          final hi = math.min(h.b, xs.last + 3);
          if (hi > lo) tot += hi - lo;
        }
      }
      return tot >= 0.6 * (xs.last - xs.first);
    }

    if (covered(a) && covered(b)) rows.add(_TRow(a, b, xs));
  }
  return rows;
}

_Fill? _cellFill(Uint8List px, int w, int h, double x0, double y0, double x1,
    double y1) {
  final xa = math.max(0, (x0 + 3).round());
  final xb = math.min(w, (x1 - 3).round());
  final ya = math.max(0, (y0 + 3).round());
  final yb = math.min(h, (y1 - 3).round());
  if (xb - xa < 4 || yb - ya < 4) return null;
  final counts = <int, List<int>>{};
  for (var y = ya; y < yb; y++) {
    for (var x = xa; x < xb; x++) {
      final i = (y * w + x) * 4;
      final a = px[i + 3];
      final r = 255 - a * (255 - px[i]) ~/ 255;
      final g = 255 - a * (255 - px[i + 1]) ~/ 255;
      final b = 255 - a * (255 - px[i + 2]) ~/ 255;
      final key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      final e = counts.putIfAbsent(key, () => [0, 0, 0, 0]);
      e[0]++;
      e[1] += r;
      e[2] += g;
      e[3] += b;
    }
  }
  List<int>? best;
  for (final e in counts.values) {
    if (best == null || e[0] > best[0]) best = e;
  }
  if (best == null) return null;
  final r = best[1] ~/ best[0];
  final g = best[2] ~/ best[0];
  final b = best[3] ~/ best[0];
  if (math.min(r, math.min(g, b)) >= 235) return null;
  final lum = 0.299 * r + 0.587 * g + 0.114 * b;
  String hx(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  return _Fill('${hx(r)}${hx(g)}${hx(b)}', lum < 110);
}

// ----- DOCX xml builders -----

String _runsXml(List<_PW> ws, String? color) {
  final out = StringBuffer();
  for (var i = 0; i < ws.length; i++) {
    final w = ws[i];
    final sp = i < ws.length - 1 ? ' ' : '';
    final fam = _xmlEsc(w.family);
    final hs = (w.size * 2).round();
    out.write('<w:r><w:rPr>'
        '<w:rFonts w:ascii="$fam" w:hAnsi="$fam" w:cs="$fam"/>'
        '${w.bold ? '<w:b/>' : ''}${w.italic ? '<w:i/>' : ''}'
        '${color != null ? '<w:color w:val="$color"/>' : ''}'
        '<w:sz w:val="$hs"/><w:szCs w:val="$hs"/>'
        '</w:rPr><w:t xml:space="preserve">${_xmlEsc(w.text)}$sp</w:t></w:r>');
  }
  return out.toString();
}

List<List<_PW>> _segments(List<_PW> ln, double size) {
  final segs = <List<_PW>>[];
  for (final w in ln) {
    if (segs.isNotEmpty && w.x0 - segs.last.last.x1 < size * 0.8) {
      segs.last.add(w);
    } else {
      segs.add([w]);
    }
  }
  return segs;
}

const _emptyCellPara =
    '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="exact"/></w:pPr></w:p>';

String _cellParas(
    List<_PW> ws, double cx0, double cx1, double cy0, bool darkFill) {
  final color = darkFill ? 'FFFFFF' : null;
  final lines = _clusterRows(ws);
  if (lines.isEmpty) return _emptyCellPara;
  final out = StringBuffer();
  double? prevTop;
  var prevLine = 0.0;
  final cw = cx1 - cx0;
  for (final ln in lines) {
    ln.sort((a, b) => a.x0.compareTo(b.x0));
    var size = 0.0;
    var top = double.infinity;
    for (final w in ln) {
      if (w.size > size) size = w.size;
      if (w.top < top) top = w.top;
    }
    final line = size * 1.2;
    var before = prevTop == null ? (top - cy0 - 1.0) : (top - (prevTop + prevLine));
    if (before < 0) before = 0;
    final segs = _segments(ln, size);
    final x0 = segs.first.first.x0;
    final x1 = segs.last.last.x1;
    final leftGap = x0 - cx0;
    final rightGap = cx1 - x1;
    String? jc;
    var ind = 0;
    final tabs = StringBuffer();
    if (segs.length == 1) {
      if ((leftGap - rightGap).abs() <= 4 && cw > 40 && leftGap > 8) {
        jc = 'center';
      } else if (rightGap <= 8 && leftGap > 15 && rightGap < leftGap * 0.5) {
        jc = 'right';
      } else {
        ind = math.max(0, ((leftGap - 2) * 20).round());
      }
    } else {
      ind = math.max(0, ((leftGap - 2) * 20).round());
      var last = 0;
      for (var si = 1; si < segs.length; si++) {
        var pos = ((segs[si].first.x0 - cx0) * 20).round();
        if (pos <= last) pos = last + 1;
        last = pos;
        tabs.write('<w:tab w:val="left" w:pos="$pos"/>');
      }
    }
    final ppr = StringBuffer('<w:pPr>');
    if (tabs.isNotEmpty) ppr.write('<w:tabs>$tabs</w:tabs>');
    ppr.write('<w:spacing w:before="${(before * 20).round()}" w:after="0" '
        'w:line="${(line * 20).round()}" w:lineRule="exact"/>');
    if (ind > 0) ppr.write('<w:ind w:left="$ind"/>');
    if (jc != null) ppr.write('<w:jc w:val="$jc"/>');
    ppr.write('</w:pPr>');
    final runs = StringBuffer();
    for (var si = 0; si < segs.length; si++) {
      if (si > 0) runs.write('<w:r><w:tab/></w:r>');
      runs.write(_runsXml(segs[si], color));
    }
    out.write('<w:p>$ppr$runs</w:p>');
    prevTop = top;
    prevLine = line;
  }
  return out.toString();
}

int _gridIndex(List<double> gx, double x) {
  var best = 0;
  for (var i = 1; i < gx.length; i++) {
    if ((gx[i] - x).abs() < (gx[best] - x).abs()) best = i;
  }
  return best;
}

String _tableXml(List<int> tb, _PageData d, List<List<List<_PW>>> cw,
    double leftM) {
  final trs = [for (final i in tb) d.rows[i]];
  final allX = <double>[];
  for (final r in trs) {
    allX.addAll(r.xs);
  }
  final gx = _cluster(allX, 3);
  final ncols = gx.length - 1;
  final grid = StringBuffer();
  for (var i = 0; i < ncols; i++) {
    grid.write('<w:gridCol w:w="${((gx[i + 1] - gx[i]) * 20).round()}"/>');
  }
  final total = ((gx.last - gx.first) * 20).round();
  final ind = ((gx.first - leftM) * 20).round();
  final xml = StringBuffer('<w:tbl><w:tblPr>'
      '<w:tblW w:w="$total" w:type="dxa"/><w:tblInd w:w="$ind" w:type="dxa"/>'
      '<w:tblBorders>');
  for (final e in ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) {
    xml.write('<w:$e w:val="single" w:sz="4" w:space="0" w:color="000000"/>');
  }
  xml.write('</w:tblBorders><w:tblLayout w:type="fixed"/>'
      '<w:tblCellMar><w:left w:w="0" w:type="dxa"/>'
      '<w:right w:w="0" w:type="dxa"/></w:tblCellMar></w:tblPr>'
      '<w:tblGrid>$grid</w:tblGrid>');

  for (final ri in tb) {
    final r = d.rows[ri];
    final ia0 = _gridIndex(gx, r.xs.first);
    final ia1 = _gridIndex(gx, r.xs.last);
    final trpr = StringBuffer('<w:trPr>');
    if (ia0 > 0) {
      trpr.write('<w:gridBefore w:val="$ia0"/>'
          '<w:wBefore w:w="${((gx[ia0] - gx.first) * 20).round()}" w:type="dxa"/>');
    }
    if (ia1 < ncols) {
      trpr.write('<w:gridAfter w:val="${ncols - ia1}"/>'
          '<w:wAfter w:w="${((gx.last - gx[ia1]) * 20).round()}" w:type="dxa"/>');
    }
    trpr.write('<w:cantSplit/><w:trHeight w:val="${((r.bottom - r.top) * 20).round()}" '
        'w:hRule="atLeast"/></w:trPr>');
    final cells = StringBuffer();
    for (var ci = 0; ci + 1 < r.xs.length; ci++) {
      final xa = r.xs[ci];
      final xb = r.xs[ci + 1];
      final a = _gridIndex(gx, xa);
      final b = _gridIndex(gx, xb);
      final span = math.max(1, b - a);
      final fill = (ri < d.fills.length && ci < d.fills[ri].length)
          ? d.fills[ri][ci]
          : null;
      final shd = fill != null
          ? '<w:shd w:val="clear" w:color="auto" w:fill="${fill.hex}"/>'
          : '';
      cells.write('<w:tc><w:tcPr><w:tcW w:w="${((xb - xa) * 20).round()}" w:type="dxa"/>'
          '<w:gridSpan w:val="$span"/>$shd</w:tcPr>'
          '${_cellParas(cw[ri][ci], xa, xb, r.top, fill?.dark ?? false)}</w:tc>');
    }
    xml.write('<w:tr>$trpr$cells</w:tr>');
  }
  xml.write('</w:tbl>');
  return xml.toString();
}

List<_Item> _pageItems(_PageData d, double leftM) {
  final rows = d.rows;
  final cw = [
    for (final r in rows)
      [for (var c = 0; c + 1 < r.xs.length; c++) <_PW>[]],
  ];
  final free = <_PW>[];
  for (final w in d.words) {
    var placed = false;
    for (var ri = 0; ri < rows.length; ri++) {
      final r = rows[ri];
      if (w.cy >= r.top - 1 && w.cy <= r.bottom + 1) {
        for (var ci = 0; ci + 1 < r.xs.length; ci++) {
          if (w.cx >= r.xs[ci] - 1 && w.cx <= r.xs[ci + 1] + 1) {
            cw[ri][ci].add(w);
            placed = true;
            break;
          }
        }
        break;
      }
    }
    if (!placed) free.add(w);
  }

  // contiguous rows form one table
  final tables = <List<int>>[];
  for (var ri = 0; ri < rows.length; ri++) {
    if (tables.isNotEmpty && (rows[tables.last.last].bottom - rows[ri].top).abs() <= 2) {
      tables.last.add(ri);
    } else {
      tables.add([ri]);
    }
  }

  final items = <_Item>[];
  for (final tb in tables) {
    items.add(_Item(rows[tb.first].top, rows[tb.last].bottom,
        _tableXml(tb, d, cw, leftM), false));
  }
  for (final ln in _clusterRows(free)) {
    ln.sort((a, b) => a.x0.compareTo(b.x0));
    var size = 0.0;
    var top = double.infinity;
    for (final w in ln) {
      if (w.size > size) size = w.size;
      if (w.top < top) top = w.top;
    }
    final line = size * 1.2;
    final segs = _segments(ln, size);
    final tabs = StringBuffer();
    var last = 0;
    for (var si = 1; si < segs.length; si++) {
      var pos = ((segs[si].first.x0 - leftM) * 20).round();
      if (pos <= last) pos = last + 1;
      last = pos;
      tabs.write('<w:tab w:val="left" w:pos="$pos"/>');
    }
    final indent = ((segs.first.first.x0 - leftM) * 20).round();
    final runs = StringBuffer();
    for (var si = 0; si < segs.length; si++) {
      if (si > 0) runs.write('<w:r><w:tab/></w:r>');
      runs.write(_runsXml(segs[si], null));
    }
    final xml = '<w:p><w:pPr>'
        '${segs.length > 1 ? '<w:tabs>$tabs</w:tabs>' : ''}'
        '<w:spacing w:before="@B@" w:after="0" w:line="${(line * 20).round()}" w:lineRule="exact"/>'
        '${indent > 0 ? '<w:ind w:left="$indent"/>' : ''}'
        '</w:pPr>$runs</w:p>';
    items.add(_Item(top, top + line, xml, true));
  }
  items.sort((a, b) => a.top.compareTo(b.top));
  return items;
}

Future<File> pdfToDocx(String path, String name) async {
  final bytes = await File(path).readAsBytes();
  final sfDoc = sf.PdfDocument(inputBytes: bytes);
  final extractor = sf.PdfTextExtractor(sfDoc);
  final pageCount = sfDoc.pages.count;
  final sizes = <Size>[];
  for (var i = 0; i < pageCount; i++) {
    sizes.add(sfDoc.pages[i].size);
  }

  final pages = <List<_PW>>[];
  var total = 0;
  var minX = double.infinity;
  for (var i = 0; i < pageCount; i++) {
    final ws = <_PW>[];
    final lines = extractor.extractTextLines(startPageIndex: i, endPageIndex: i);
    for (final line in lines) {
      for (final w in line.wordCollection) {
        final t = w.text.trim();
        if (t.isEmpty) continue;
        final b = w.bounds;
        final fn = w.fontName;
        final low = fn.toLowerCase();
        ws.add(_PW(
          t,
          b.left,
          b.right,
          b.top,
          b.bottom,
          w.fontSize > 0 ? w.fontSize : 10,
          low.contains('bold'),
          low.contains('italic') || low.contains('oblique'),
          _family(fn),
        ));
        total += t.length;
        if (b.left < minX) minX = b.left;
      }
    }
    pages.add(ws);
  }
  sfDoc.dispose();

  if (total == 0) {
    throw Exception(
        'Idhu scanned (image) PDF. Text illa, v1-la support illa.');
  }

  // Detect table borders from a rendered image of each page
  const dpi = 100.0;
  final datas = <_PageData>[];
  for (var i = 0; i < pages.length; i++) {
    final rows = <_TRow>[];
    final fills = <List<_Fill?>>[];
    try {
      final r = await Printing.raster(bytes, pages: [i], dpi: dpi).first;
      final grid = _detectGrid(r.pixels, r.width, r.height, dpi);
      final pxRows = _buildRows(grid);
      final kx = r.width / sizes[i].width;
      final ky = r.height / sizes[i].height;
      for (final pr in pxRows) {
        final f = <_Fill?>[];
        for (var c = 0; c + 1 < pr.xs.length; c++) {
          f.add(_cellFill(r.pixels, r.width, r.height, pr.xs[c], pr.top,
              pr.xs[c + 1], pr.bottom));
        }
        fills.add(f);
        rows.add(_TRow(pr.top / ky, pr.bottom / ky, [for (final x in pr.xs) x / kx]));
      }
    } catch (_) {
      rows.clear();
      fills.clear();
    }
    datas.add(_PageData(pages[i], rows, fills));
  }

  var minLeft = minX.isFinite ? minX : 36.0;
  for (final d in datas) {
    for (final r in d.rows) {
      if (r.xs.first < minLeft) minLeft = r.xs.first;
    }
  }
  final leftM = math.max(0.0, minLeft - 1);
  const topM = 18.0;

  final body = StringBuffer();
  for (var pi = 0; pi < datas.length; pi++) {
    final items = _pageItems(datas[pi], leftM);
    var cursor = topM;
    var firstItem = true;
    for (final it in items) {
      final gap = math.max(0.0, it.top - cursor);
      if (firstItem && pi > 0) {
        // new page: spacer paragraph carries the page break
        body.write('<w:p><w:pPr><w:pageBreakBefore/>'
            '<w:spacing w:before="0" w:after="0" w:line="${math.max(20, (gap * 20).round())}" '
            'w:lineRule="exact"/></w:pPr></w:p>');
        if (it.para) {
          body.write(it.xml.replaceAll('@B@', '0'));
        } else {
          body.write(it.xml);
        }
      } else if (it.para) {
        body.write(it.xml.replaceAll('@B@', '${(gap * 20).round()}'));
      } else {
        body.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0" '
            'w:line="${math.max(20, (gap * 20).round())}" w:lineRule="exact"/></w:pPr></w:p>');
        body.write(it.xml);
      }
      cursor = it.bottom;
      firstItem = false;
    }
  }

  const header = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  final docXml = '$header'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body'
      '<w:sectPr><w:pgSz w:w="${(sizes[0].width * 20).round()}" w:h="${(sizes[0].height * 20).round()}"/>'
      '<w:pgMar w:top="${(topM * 20).round()}" w:right="360" w:bottom="360" '
      'w:left="${(leftM * 20).round()}" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>'
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
