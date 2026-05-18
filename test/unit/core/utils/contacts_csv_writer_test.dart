// Unit tests for ContactsCsvWriter — converts flutter_contacts.Contact
// objects (from either the picker or VCard parsing) into a CSV with
// Name,Phone,Email columns. The output is what feeds the Automate
// placeholder-chip + render pipeline, so getting the header right
// matters.

import 'package:csv/csv.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/utils/contacts_csv_writer.dart';

/// Build a Contact for testing. We construct it field-by-field so we
/// can exercise the various missing-field combinations without
/// touching the platform channel.
Contact _contact({
  String displayName = '',
  String first = '',
  String last = '',
  List<String> phones = const [],
  List<String> emails = const [],
}) {
  return Contact(
    displayName: displayName,
    name: Name(first: first, last: last),
    phones: [for (final n in phones) Phone(n)],
    emails: [for (final e in emails) Email(e)],
  );
}

/// Parse the produced CSV back into rows so the assertions read
/// naturally (instead of doing fragile substring matches on the raw
/// string).
List<List<String>> _parse(String csv) {
  return const CsvToListConverter().convert(csv).map((row) {
    return row.map((cell) => cell.toString()).toList();
  }).toList();
}

void main() {
  group('ContactsCsvWriter.toCsv — header', () {
    test('always emits Name,Phone,Email header even with zero contacts', () {
      final csv = ContactsCsvWriter.toCsv(const []);
      final rows = _parse(csv);
      expect(rows, hasLength(1));
      expect(rows.first, ['Name', 'Phone', 'Email']);
    });

    test('header is the first row when contacts are present', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'Alice', phones: ['555-1234']),
      ]);
      final rows = _parse(csv);
      expect(rows.first, ['Name', 'Phone', 'Email'],
          reason: 'header drives the placeholder-chip names in the UI');
    });
  });

  group('ContactsCsvWriter.toCsv — per-contact rows', () {
    test('single contact with all three fields', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(
          displayName: 'Bob Smith',
          phones: ['+1 555-1234'],
          emails: ['bob@example.com'],
        ),
      ]);
      final rows = _parse(csv);
      expect(rows, hasLength(2));
      expect(rows[1], ['Bob Smith', '+1 555-1234', 'bob@example.com']);
    });

    test('missing phone → empty cell (NOT skipped)', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'No Phone', emails: ['x@y.com']),
      ]);
      final rows = _parse(csv);
      expect(rows, hasLength(2));
      expect(rows[1], ['No Phone', '', 'x@y.com']);
    });

    test('missing email → empty cell', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'No Email', phones: ['5551234']),
      ]);
      final rows = _parse(csv);
      expect(rows[1], ['No Email', '5551234', '']);
    });

    test('uses first phone + first email when multiple present', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(
          displayName: 'Multi',
          phones: ['111', '222', '333'],
          emails: ['a@x', 'b@x'],
        ),
      ]);
      final rows = _parse(csv);
      expect(rows[1], ['Multi', '111', 'a@x']);
    });

    test('multiple contacts each on their own row', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'A', phones: ['1234567']),
        _contact(displayName: 'B', emails: ['b@x.com']),
        _contact(displayName: 'C'),
      ]);
      final rows = _parse(csv);
      expect(rows, hasLength(4)); // header + 3
      expect(rows[1], ['A', '1234567', '']);
      expect(rows[2], ['B', '', 'b@x.com']);
      expect(rows[3], ['C', '', '']);
    });
  });

  group('ContactsCsvWriter.toCsv — name fallback', () {
    test('displayName preferred when present', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'Display', first: 'F', last: 'L'),
      ]);
      final rows = _parse(csv);
      expect(rows[1].first, 'Display');
    });

    test('falls back to first + last when displayName is empty', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(first: 'Jane', last: 'Doe'),
      ]);
      final rows = _parse(csv);
      expect(rows[1].first, 'Jane Doe');
    });

    test('uses first alone if last is empty', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(first: 'Solo'),
      ]);
      expect(_parse(csv)[1].first, 'Solo');
    });

    test('uses last alone if first is empty', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(last: 'Surname'),
      ]);
      expect(_parse(csv)[1].first, 'Surname');
    });

    test('all-empty name → empty cell (does not crash)', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(phones: ['1234567']),
      ]);
      final rows = _parse(csv);
      expect(rows[1].first, '',
          reason: 'no name available — emit empty cell, not "(no name)"');
    });
  });

  group('ContactsCsvWriter.toCsv — CSV escaping', () {
    test('values with commas are quoted (RFC-4180 round-trip)', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'Smith, Bob', phones: ['1234567']),
      ]);
      // The raw CSV should contain a quoted "Smith, Bob". After
      // round-trip parse, the comma is back in the cell.
      final rows = _parse(csv);
      expect(rows[1][0], 'Smith, Bob');
    });

    test('values with embedded quotes are escaped', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(displayName: 'O"Hara', phones: ['1234567']),
      ]);
      final rows = _parse(csv);
      expect(rows[1][0], 'O"Hara',
          reason: 'csv package handles `"" -> "` per RFC-4180');
    });

    test('values with newlines round-trip cleanly', () {
      final csv = ContactsCsvWriter.toCsv([
        _contact(
            displayName: 'Multi\nLine', phones: ['1234567'], emails: const []),
      ]);
      final rows = _parse(csv);
      expect(rows[1][0], 'Multi\nLine');
    });
  });
}
