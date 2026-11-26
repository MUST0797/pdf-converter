import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

Future<List<File>> convertPdfToPngs(
  String pdfPath, {
  double dpi = 150,
  void Function(int current, int total)? onProgress,
}) async {
  final Uint8List pdfBytes = await File(pdfPath).readAsBytes();
  final Directory dir = await getApplicationDocumentsDirectory();
  final String baseName = pdfPath
      .split('/')
      .last
      .split('\\')
      .last
      .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');

  final List<File> outputFiles = [];
  int pageIndex = 0;

  await for (final page in Printing.raster(pdfBytes, dpi: dpi)) {
    pageIndex++;
    onProgress?.call(pageIndex, 0);
    final Uint8List pngBytes = await page.toPng();
    final File outFile = File('${dir.path}/${baseName}_page_$pageIndex.png');
    await outFile.writeAsBytes(pngBytes, flush: true);
    outputFiles.add(outFile);
  }

  return outputFiles;
}
