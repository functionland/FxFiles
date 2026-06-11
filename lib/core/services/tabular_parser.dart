import 'dart:convert';

import 'package:csv/csv.dart';

// Web-safe: the File-based entry point lives in tabular_parser_io.dart
// (the web shell parses picked bytes via [TabularParser.parseBytes]).

/// Result of parsing a tabular file (CSV in v1; xlsx is deferred to v1.1 —
/// see pubspec comment about the archive-version conflict that blocks the
/// `excel` and `spreadsheet_decoder` packages).
class TabularData {
  final List<String> headers;
  final List<Map<String, String>> rows;
  final String? warning; // soft warning when the file looked unusual

  const TabularData({
    required this.headers,
    required this.rows,
    this.warning,
  });

  bool get isEmpty => rows.isEmpty;
  int get rowCount => rows.length;
}

class TabularParseException implements Exception {
  final String message;
  TabularParseException(this.message);
  @override
  String toString() => 'TabularParseException: $message';
}

/// Parses a CSV file from disk. The first non-empty row is treated as the
/// header. Subsequent rows are mapped column-by-name. Handles UTF-8 with or
/// without BOM. Unknown encodings (Latin-1, UTF-16) are not auto-detected
/// in v1 — Excel's "Save As CSV" defaults to UTF-8 on modern macOS / Win11.
class TabularParser {
  TabularParser._();

  static const _maxFileBytes = 10 * 1024 * 1024; // 10 MB hard cap

  /// Parse already-read bytes (web file picker / in-memory sources).
  /// [fileName] drives the same size/extension validation as the
  /// File-based entry point in tabular_parser_io.dart.
  static TabularData parseBytes(List<int> bytes, {required String fileName}) {
    if (bytes.isEmpty) {
      throw TabularParseException('File is empty');
    }
    if (bytes.length > _maxFileBytes) {
      throw TabularParseException(
          'File is too large (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB). '
          'CSV imports are capped at 10 MB in v1.');
    }
    final ext = _extOf(fileName);
    if (ext != 'csv') {
      throw TabularParseException(
        'Unsupported file type: .$ext. v1 only reads CSV; export your '
        'spreadsheet as CSV from Excel/Numbers/Sheets first.',
      );
    }
    return _parseCsv(bytes);
  }

  /// Validation caps shared with the io entry point.
  static int get maxFileBytes => _maxFileBytes;

  static String extOf(String path) => _extOf(path);

  static TabularData _parseCsv(List<int> bytes) {
    // Strip UTF-8 BOM if present.
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    final text = utf8.decode(data, allowMalformed: true);
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(text.replaceAll('\r\n', '\n'));

    if (rows.isEmpty) {
      throw TabularParseException('CSV has no rows');
    }

    final rawHeaders = rows.first.map((c) => c?.toString().trim() ?? '').toList();
    final headers = <String>[];
    for (var i = 0; i < rawHeaders.length; i++) {
      final h = rawHeaders[i];
      headers.add(h.isEmpty ? 'column_${i + 1}' : h);
    }

    final dataRows = <Map<String, String>>[];
    String? warning;
    for (var r = 1; r < rows.length; r++) {
      final cells = rows[r];
      if (cells.isEmpty || cells.every((c) => (c?.toString() ?? '').trim().isEmpty)) {
        continue; // skip blank rows
      }
      final row = <String, String>{};
      for (var c = 0; c < headers.length; c++) {
        final v = c < cells.length ? (cells[c]?.toString() ?? '') : '';
        row[headers[c]] = v;
      }
      dataRows.add(row);
    }

    if (dataRows.isEmpty) {
      throw TabularParseException(
          'CSV has a header row but no data rows. Add at least one row.');
    }
    if (headers.toSet().length != headers.length) {
      warning =
          'Some column headers are duplicated; only the first occurrence is used.';
    }

    return TabularData(headers: headers, rows: dataRows, warning: warning);
  }

  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot + 1).toLowerCase();
  }
}
