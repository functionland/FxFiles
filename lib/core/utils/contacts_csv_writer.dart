import 'package:csv/csv.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

/// Convert a list of [Contact] objects (from `flutter_contacts`, either
/// the device contacts API or `Contact.fromVCard(...)`) into a
/// well-formed CSV string with columns `Name,Phone,Email`.
///
/// One row per contact. For contacts with multiple phones/emails, the
/// **first** entry is used (typically the primary). Empty fields are
/// emitted as empty strings rather than skipped — the per-row run-time
/// validation in the Automate detail screen will mark rows with an
/// invalid phone/email as failed, which is the same behaviour we have
/// for a hand-authored CSV with blanks.
///
/// Output uses the `csv` package's `ListToCsvConverter` which handles
/// the corner cases (commas in names, embedded quotes, newlines) per
/// RFC 4180. The first row is the header — that header IS what the
/// Automate detail screen uses to build the placeholder chips.
class ContactsCsvWriter {
  ContactsCsvWriter._();

  static const String _headerName = 'Name';
  static const String _headerPhone = 'Phone';
  static const String _headerEmail = 'Email';

  /// Build the CSV text. Header row is always
  /// `Name,Phone,Email` so the user gets `{Name}` / `{Phone}` /
  /// `{Email}` chips regardless of which contacts they pick.
  static String toCsv(List<Contact> contacts) {
    final rows = <List<String>>[
      const [_headerName, _headerPhone, _headerEmail],
      for (final c in contacts)
        [
          _bestDisplayName(c),
          c.phones.isNotEmpty ? c.phones.first.number.trim() : '',
          c.emails.isNotEmpty ? c.emails.first.address.trim() : '',
        ],
    ];
    return const ListToCsvConverter().convert(rows);
  }

  /// Pick the most-useful display name for a contact. Falls back through
  /// `displayName` → `first + last` → an empty string.
  static String _bestDisplayName(Contact c) {
    final dn = c.displayName.trim();
    if (dn.isNotEmpty) return dn;
    final first = c.name.first.trim();
    final last = c.name.last.trim();
    final combo = [first, last].where((s) => s.isNotEmpty).join(' ');
    return combo;
  }
}
