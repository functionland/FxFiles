/// Pure logic for the web global file search (#8). Dependency-free (no Flutter)
/// so it is VM unit-testable; the screen + listing fetch are browser-only.
library;

import 'package:fula_files/core/models/fula_object.dart';

/// One searchable file: the category [base] it lives in (used to deep-open via
/// `/b/<base>?open=<key>`) plus the cloud [object].
class WebSearchEntry {
  final String base;
  final FulaObject object;
  const WebSearchEntry(this.base, this.object);
  String get name => object.name;
}

/// Filter [entries] to those whose file name contains [query]
/// (case-insensitive, trimmed). A blank query returns an empty list — the
/// search screen then shows a prompt rather than the entire vault. Order is
/// preserved (the caller pre-sorts the index).
List<WebSearchEntry> searchEntries(
    List<WebSearchEntry> entries, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return entries
      .where((e) => e.name.toLowerCase().contains(q))
      .toList(growable: false);
}
