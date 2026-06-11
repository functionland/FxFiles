import 'dart:io';

import 'package:fula_files/core/services/tabular_parser.dart';

export 'package:fula_files/core/services/tabular_parser.dart';

/// File-based entry point for [TabularParser] (native platforms).
/// Validation messages match the original TabularParser.parse(File);
/// the CSV core lives in the web-safe tabular_parser.dart.
Future<TabularData> parseTabularFile(File file) async {
  if (!await file.exists()) {
    throw TabularParseException('File not found: ${file.path}');
  }
  final size = await file.length();
  if (size == 0) {
    throw TabularParseException('File is empty');
  }
  if (size > TabularParser.maxFileBytes) {
    throw TabularParseException(
        'File is too large (${(size / 1024 / 1024).toStringAsFixed(1)} MB). '
        'CSV imports are capped at 10 MB in v1.');
  }
  final ext = TabularParser.extOf(file.path);
  if (ext != 'csv') {
    throw TabularParseException(
      'Unsupported file type: .$ext. v1 only reads CSV; export your '
      'spreadsheet as CSV from Excel/Numbers/Sheets first.',
    );
  }
  return TabularParser.parseBytes(await file.readAsBytes(),
      fileName: file.path);
}
