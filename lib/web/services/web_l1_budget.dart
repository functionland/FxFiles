import 'dart:collection';

/// In-memory byte budget for WebListingCache's L1 maps (plan: mobile
/// freeze fix, step 5). The L1 tier used to be unbounded — every
/// listing/manifest read this session stayed resident for the tab's
/// lifetime, which on a low-memory phone stacks on top of the wasm heap
/// and the non-lazy Hive box. This class does the ACCOUNTING only; the
/// cache owns the maps and applies the evictions it returns.
///
/// Pure + synchronous by design: WebListingCache imports package:web so
/// it can't be VM-tested — this can. Deliberately NOT the persisted
/// `_touchLru` sidecar (that orders L2 eviction and stays as-is): L1
/// order is session-local, so a plain LinkedHashMap (re-insert on
/// touch) is the whole LRU.
class L1Budget {
  L1Budget({required this.budgetBytes});

  final int budgetBytes;

  /// key → resident bytes, in LRU order (first = coldest).
  final LinkedHashMap<String, int> _bytes = LinkedHashMap<String, int>();
  int _total = 0;

  int get totalBytes => _total;

  /// False when [bytes] alone exceeds the whole budget — caching it
  /// would evict everything else for one entry.
  bool shouldCache(int bytes) => bytes <= budgetBytes;

  /// Record [key] at [bytes] (replacing any previous size) and return
  /// the keys to evict, coldest first — never [key] itself. The caller
  /// must drop the returned keys from its maps.
  List<String> insert(String key, int bytes) {
    remove(key); // replace releases the old bytes first
    final evict = <String>[];
    for (final e in _bytes.entries) {
      if (_total + bytes <= budgetBytes) break;
      evict.add(e.key);
      _total -= e.value;
    }
    for (final k in evict) {
      _bytes.remove(k);
    }
    _bytes[key] = bytes;
    _total += bytes;
    return evict;
  }

  /// Mark [key] most-recently-used.
  void touch(String key) {
    final b = _bytes.remove(key);
    if (b != null) _bytes[key] = b;
  }

  void remove(String key) {
    final b = _bytes.remove(key);
    if (b != null) _total -= b;
  }

  void clear() {
    _bytes.clear();
    _total = 0;
  }
}
