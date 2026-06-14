/// Pure per-category sort logic for the web bucket screen (#7), mirroring the
/// native `file_service.dart` comparator: directories first, then by name
/// (case-insensitive) or last-modified date, ascending/descending. Returns a
/// NEW sorted list. Dependency-free (no Flutter) so it is VM unit-testable.
library;

import 'package:fula_files/core/models/fula_object.dart';

enum WebSortBy { date, name }

/// Sort [objects] into a new list. Directories sort before files (native
/// parity, even though web category views are usually flat). Date uses
/// `lastModified` (missing → epoch 0). Default in the UI is date-descending
/// (newest first), which reproduces the prior hard-coded ordering.
List<FulaObject> sortObjects(
    List<FulaObject> objects, WebSortBy by, bool ascending) {
  final out = List<FulaObject>.of(objects);
  out.sort((a, b) {
    if (a.isDirectory && !b.isDirectory) return -1;
    if (!a.isDirectory && b.isDirectory) return 1;
    final int c;
    switch (by) {
      case WebSortBy.name:
        c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case WebSortBy.date:
        final at = a.lastModified?.millisecondsSinceEpoch ?? 0;
        final bt = b.lastModified?.millisecondsSinceEpoch ?? 0;
        c = at.compareTo(bt);
    }
    return ascending ? c : -c;
  });
  return out;
}
