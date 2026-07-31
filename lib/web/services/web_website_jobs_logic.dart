// Pure merge logic for the pending website-generation jobs sidecar
// (`.fula/website_jobs/{uid}.json`), extracted from WebWebsiteService
// for VM unit tests (repo convention: services keep the I/O, logic
// files keep the decisions).

/// Merge pending entries from every downloaded blob, newest write wins
/// per generation id. Entries are kept as raw maps so a field this
/// client doesn't know about survives a rewrite.
Map<String, Map<String, dynamic>> mergePendingJobs(
    Iterable<Iterable<dynamic>> entryLists) {
  DateTime updatedAtOf(Map<String, dynamic> m) {
    final v = m['updatedAt'];
    return v is String
        ? (DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0))
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  final byId = <String, Map<String, dynamic>>{};
  for (final list in entryLists) {
    for (final raw in list) {
      if (raw is! Map) continue;
      final m = raw.cast<String, dynamic>();
      final id = m['generationId'];
      if (id is! String || id.isEmpty) continue;
      final existing = byId[id];
      if (existing == null || updatedAtOf(m).isAfter(updatedAtOf(existing))) {
        byId[id] = m;
      }
    }
  }
  return byId;
}
