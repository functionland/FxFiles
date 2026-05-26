import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/file_tag.dart';

/// A scored tag suggestion. [score] is a containment ratio in [0, ~1.3]
/// (can exceed 1.0 when host-intent bonus stacks).
class TagSuggestion {
  final FileTag tag;
  final double score;
  const TagSuggestion(this.tag, this.score);
}

/// On-device, no-ML tag matcher. Scores each user-created [FileTag]
/// against the enriched fields of a [ShelfItem] (autoTitle,
/// autoDescription, mlLabels, originalName, textPayload + URL host)
/// using token containment with a small set of heuristics:
///
///   * stop-words filtered from both haystack and tag tokens
///   * tag tokens shorter than [_kMinTagTokenChars] dropped (so a tag
///     literally named "a" doesn't match everything)
///   * lightweight bidirectional stemming via prefix match within a
///     small length delta — "movie" matches "movies" AND "recipes"
///     matches "recipe"
///   * generic ML-Kit labels (Rectangle, Font, Material property…)
///     filtered out of the haystack so they don't spuriously light up
///     unrelated tags
///   * URL host → built-in intent table: if any tag token appears in
///     the host's intent set, the tag is **host-endorsed** and passes
///     regardless of text containment (an `imdb.com` link is reason
///     enough to suggest `must_watch` even with a blank OG title)
///
/// Two acceptance paths:
///   1. **Containment**: matches / tagTokenCount ≥ [_kMinContainment]
///      (3-of-4 for a 4-token tag, both for 2-token, whole for 1-token).
///   2. **Host endorsement**: any tag token ∈ host intent set. The host
///      intent table is high-signal (a curated ~50-host list), so the
///      false-positive risk is low: a `recipes` tag won't trigger on
///      an IMDb URL because "recipes" isn't in IMDb's intent set.
class ShelfTagSuggester {
  ShelfTagSuggester._();

  /// Minimum containment ratio for a tag to pass via text alone. 0.75
  /// means 3-of-4 tokens for a 4-token tag, both tokens for a 2-token
  /// tag, the whole token for a 1-token tag.
  static const double _kMinContainment = 0.75;

  /// Tag-name tokens shorter than this are dropped before scoring. Keeps
  /// "the" / "a" / "of" out of the keyword set even if a user manages
  /// to put them in a tag.
  static const int _kMinTagTokenChars = 3;

  /// Score bonus added when the host endorses the tag. Used for
  /// ranking only — a host-endorsed tag passes regardless of score.
  static const double _kHostBoost = 0.5;

  /// Cap on the number of suggestions returned per item. Three keeps
  /// the chip row visually contained and stops a wall of weak matches.
  static const int _kMaxSuggestions = 3;

  /// Allowable length delta for the bidirectional stem heuristic.
  /// "movie"/"movies" (delta 1) matches; "movie"/"moviegoer" (delta 4)
  /// does not. Symmetric: the shorter of the two strings must be a
  /// prefix of the longer.
  static const int _kStemMaxDelta = 2;

  /// Minimum shared-prefix length for the stem heuristic. Without this,
  /// haystack "the" would prefix-match a tag "tea" / "ten" / "ted",
  /// turning short stop-word-adjacent words into noise.
  static const int _kStemMinPrefixChars = 3;

  /// Returns up to [_kMaxSuggestions] tags ordered by score desc that
  /// score at or above [_kMinScore], excluding any tag already applied
  /// or dismissed for this item.
  static List<TagSuggestion> suggest({
    required ShelfItem item,
    required List<FileTag> allTags,
    required Set<String> appliedTagIds,
    required Set<String> dismissedTagIds,
  }) {
    if (allTags.isEmpty) return const <TagSuggestion>[];

    final haystack = _buildHaystack(item);
    if (haystack.isEmpty) return const <TagSuggestion>[];

    final hostIntents = _hostIntentsFor(item);

    final matches = <TagSuggestion>[];
    for (final tag in allTags) {
      if (appliedTagIds.contains(tag.id)) continue;
      if (dismissedTagIds.contains(tag.id)) continue;

      final tagTokens = _tokenize(tag.name)
          .where((t) => t.length >= _kMinTagTokenChars && !_kStopWords.contains(t))
          .toList(growable: false);
      if (tagTokens.isEmpty) continue;

      final hits = tagTokens
          .where((tt) => _haystackContains(haystack, tt))
          .length;
      final hostEndorses = hostIntents.isNotEmpty &&
          tagTokens.any((tt) => hostIntents.contains(tt));

      final containment = hits / tagTokens.length;
      final passes = hostEndorses || containment >= _kMinContainment;
      if (!passes) continue;

      // Score is containment + host boost (for ranking only — the
      // pass/fail decision is made above). A host-endorsed tag with
      // partial text containment outranks a host-endorsed tag with
      // none, which outranks a non-endorsed tag that barely cleared
      // containment.
      final score = containment + (hostEndorses ? _kHostBoost : 0.0);
      matches.add(TagSuggestion(tag, score));
    }

    matches.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.tag.name.compareTo(b.tag.name);
    });
    return matches.take(_kMaxSuggestions).toList(growable: false);
  }

  // ----------------------------------------------------------------
  // Haystack
  // ----------------------------------------------------------------

  static Set<String> _buildHaystack(ShelfItem item) {
    final parts = <String>[
      if (item.autoTitle != null) item.autoTitle!,
      if (item.autoDescription != null) item.autoDescription!,
      item.originalName,
      if (item.textPayload != null) item.textPayload!,
      ...item.mlLabels.where((l) => !_kBlacklistedMlLabels.contains(l.toLowerCase())),
    ];
    final tokens = <String>{};
    for (final part in parts) {
      tokens.addAll(_tokenize(part));
    }
    return tokens;
  }

  static bool _haystackContains(Set<String> haystack, String tagToken) {
    if (haystack.contains(tagToken)) return true;
    // Bidirectional stem heuristic: the shorter string must be a prefix
    // of the longer, with length delta ≤ [_kStemMaxDelta] and shared
    // prefix length ≥ [_kStemMinPrefixChars]. This catches both
    // "movie"→"movies" (tag is the root, haystack pluralised) AND
    // "recipes"→"recipe" (tag is the plural, haystack the root). The
    // shared-prefix floor stops "tea" from matching haystack "ten"/"the".
    for (final ht in haystack) {
      final String shorter;
      final String longer;
      if (ht.length < tagToken.length) {
        shorter = ht;
        longer = tagToken;
      } else {
        shorter = tagToken;
        longer = ht;
      }
      if (shorter.length < _kStemMinPrefixChars) continue;
      if (longer.length - shorter.length > _kStemMaxDelta) continue;
      if (longer.startsWith(shorter)) return true;
    }
    return false;
  }

  /// Lower-cases, then splits on any non-alphanumeric run. Keeps unicode
  /// letters/digits so non-English tag names work. Returns a List
  /// (callers may dedupe via Set as needed).
  static List<String> _tokenize(String s) {
    if (s.isEmpty) return const <String>[];
    final lower = s.toLowerCase();
    final out = <String>[];
    final buf = StringBuffer();
    for (final code in lower.runes) {
      if (_isWordChar(code)) {
        buf.writeCharCode(code);
      } else if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static bool _isWordChar(int code) {
    // ASCII digits
    if (code >= 0x30 && code <= 0x39) return true;
    // ASCII a-z (lowercased)
    if (code >= 0x61 && code <= 0x7A) return true;
    // Non-ASCII letter: anything above U+007F that isn't whitespace or
    // common punctuation. Cheap heuristic — accepts CJK, Farsi, Cyrillic
    // etc. while rejecting whitespace and punctuation that lowercase
    // doesn't touch.
    if (code > 0x7F) {
      // Reject common Unicode whitespace + punctuation ranges.
      if (code == 0x00A0 || code == 0x2028 || code == 0x2029) return false;
      if (code >= 0x2000 && code <= 0x200B) return false;
      if (code >= 0x2010 && code <= 0x2027) return false;
      if (code >= 0x3000 && code <= 0x3003) return false;
      return true;
    }
    return false;
  }

  // ----------------------------------------------------------------
  // Host intent table
  // ----------------------------------------------------------------

  /// Returns the intent tokens associated with this item's host (only
  /// meaningful for link items). Empty set if not a link or host
  /// unknown.
  static Set<String> _hostIntentsFor(ShelfItem item) {
    if (item.category != ShelfCategory.link) return const <String>{};
    final raw = item.textPayload?.trim();
    if (raw == null || raw.isEmpty) return const <String>{};
    final uri = Uri.tryParse(raw);
    if (uri == null) return const <String>{};
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return const <String>{};

    // Walk the host suffixes longest-first so a more specific entry
    // (e.g., `music.youtube.com`) wins over a generic one (`youtube.com`).
    final parts = host.split('.');
    for (var i = 0; i < parts.length - 1; i++) {
      final candidate = parts.sublist(i).join('.');
      final hit = _kHostIntents[candidate];
      if (hit != null) return hit;
    }
    return const <String>{};
  }

  // Static intent table — kept small and high-signal. Each entry maps a
  // host suffix to the keyword tokens a user is most likely to have
  // chosen for tags about that kind of content. Tokens are
  // intentionally short / single-word so the containment test finds
  // them in tag names like "movies", "must_watch", "music", "recipes".
  static const Map<String, Set<String>> _kHostIntents = <String, Set<String>>{
    // Movies / TV
    'imdb.com': <String>{'movie', 'movies', 'film', 'films', 'watch', 'tv', 'show', 'shows', 'series', 'cinema'},
    'themoviedb.org': <String>{'movie', 'movies', 'film', 'films', 'watch', 'tv', 'show', 'shows', 'series'},
    'letterboxd.com': <String>{'movie', 'movies', 'film', 'films', 'watch', 'cinema'},
    'rottentomatoes.com': <String>{'movie', 'movies', 'film', 'films', 'watch', 'tv', 'show', 'shows'},
    'netflix.com': <String>{'movie', 'movies', 'film', 'films', 'watch', 'show', 'shows', 'series', 'stream'},
    'hulu.com': <String>{'movie', 'movies', 'show', 'shows', 'series', 'stream', 'watch'},
    'disneyplus.com': <String>{'movie', 'movies', 'film', 'films', 'show', 'shows', 'watch', 'disney'},
    'primevideo.com': <String>{'movie', 'movies', 'film', 'films', 'show', 'shows', 'watch'},
    'apple.com': <String>{'apple'},
    'tv.apple.com': <String>{'movie', 'movies', 'film', 'films', 'show', 'shows', 'watch'},
    'hbomax.com': <String>{'movie', 'movies', 'film', 'films', 'show', 'shows', 'watch'},
    'max.com': <String>{'movie', 'movies', 'film', 'films', 'show', 'shows', 'watch'},

    // Video / general
    'youtube.com': <String>{'video', 'videos', 'watch', 'youtube'},
    'youtu.be': <String>{'video', 'videos', 'watch', 'youtube'},
    'vimeo.com': <String>{'video', 'videos', 'watch'},
    'twitch.tv': <String>{'video', 'videos', 'watch', 'stream', 'game', 'games', 'gaming'},
    'tiktok.com': <String>{'video', 'videos', 'watch', 'tiktok'},

    // Music
    'spotify.com': <String>{'music', 'song', 'songs', 'audio', 'playlist', 'listen'},
    'open.spotify.com': <String>{'music', 'song', 'songs', 'audio', 'playlist', 'listen'},
    'soundcloud.com': <String>{'music', 'song', 'songs', 'audio', 'listen'},
    'music.apple.com': <String>{'music', 'song', 'songs', 'audio', 'playlist', 'listen'},
    'bandcamp.com': <String>{'music', 'song', 'songs', 'audio', 'listen', 'album'},
    'music.youtube.com': <String>{'music', 'song', 'songs', 'audio', 'listen'},

    // Code / docs
    'github.com': <String>{'code', 'repo', 'project', 'dev', 'develop', 'programming'},
    'gitlab.com': <String>{'code', 'repo', 'project', 'dev', 'develop', 'programming'},
    'bitbucket.org': <String>{'code', 'repo', 'project', 'dev', 'develop'},
    'stackoverflow.com': <String>{'code', 'dev', 'develop', 'programming', 'question'},
    'developer.mozilla.org': <String>{'code', 'dev', 'docs', 'documentation', 'web'},
    'pub.dev': <String>{'code', 'dev', 'flutter', 'dart', 'package'},
    'npmjs.com': <String>{'code', 'dev', 'package', 'npm', 'node'},

    // Reading / reference
    'medium.com': <String>{'article', 'articles', 'read', 'reading', 'blog'},
    'substack.com': <String>{'article', 'articles', 'read', 'reading', 'newsletter', 'blog'},
    'wikipedia.org': <String>{'reference', 'wiki', 'article', 'articles'},
    'arxiv.org': <String>{'paper', 'papers', 'research', 'academic', 'study'},
    'scholar.google.com': <String>{'paper', 'papers', 'research', 'academic', 'study'},

    // Shopping
    'amazon.com': <String>{'shop', 'shopping', 'buy', 'product', 'amazon'},
    'amazon.co.uk': <String>{'shop', 'shopping', 'buy', 'product', 'amazon'},
    'ebay.com': <String>{'shop', 'shopping', 'buy', 'product'},
    'etsy.com': <String>{'shop', 'shopping', 'buy', 'product', 'craft', 'handmade'},
    'aliexpress.com': <String>{'shop', 'shopping', 'buy', 'product'},

    // Recipes / food
    'allrecipes.com': <String>{'recipe', 'recipes', 'food', 'cooking', 'cook', 'meal'},
    'foodnetwork.com': <String>{'recipe', 'recipes', 'food', 'cooking', 'cook', 'meal'},
    'seriouseats.com': <String>{'recipe', 'recipes', 'food', 'cooking', 'cook'},
    'bonappetit.com': <String>{'recipe', 'recipes', 'food', 'cooking', 'cook'},

    // News
    'news.ycombinator.com': <String>{'news', 'tech', 'read', 'reading', 'hackernews'},
    'bbc.com': <String>{'news', 'read', 'reading'},
    'nytimes.com': <String>{'news', 'read', 'reading', 'article', 'articles'},
    'theguardian.com': <String>{'news', 'read', 'reading', 'article', 'articles'},

    // Social
    'twitter.com': <String>{'tweet', 'tweets', 'social', 'twitter'},
    'x.com': <String>{'tweet', 'tweets', 'social', 'twitter'},
    'instagram.com': <String>{'social', 'photo', 'photos', 'instagram'},
    'facebook.com': <String>{'social', 'facebook'},
    'reddit.com': <String>{'discussion', 'reddit', 'community'},
    'linkedin.com': <String>{'social', 'professional', 'work', 'career', 'job', 'jobs'},
  };

  // ----------------------------------------------------------------
  // Stop-word and ML-label filters
  // ----------------------------------------------------------------

  /// Stop words filtered out of haystack tokens AND tag tokens. Keep
  /// this list short — only words almost certain to add noise. A
  /// non-English user's tags should still tokenize cleanly (we don't
  /// filter their words).
  static const Set<String> _kStopWords = <String>{
    'the', 'and', 'for', 'with', 'this', 'that', 'are', 'was', 'were',
    'has', 'have', 'had', 'but', 'not', 'you', 'your', 'our', 'their',
    'they', 'them', 'his', 'her', 'its', 'from', 'into', 'about', 'over',
    'under', 'than', 'then', 'when', 'where', 'what', 'who', 'why', 'how',
    'all', 'any', 'some', 'one', 'two', 'three', 'just', 'only', 'also',
    'very', 'much', 'more', 'most', 'less', 'few', 'too',
  };

  /// ML-Kit's on-device image labeler regularly returns generic
  /// structural labels that say nothing about the content. Filtering
  /// them prevents a tag like "art" from matching every screenshot
  /// just because the labeler emitted "Rectangle" with 0.7 confidence.
  static const Set<String> _kBlacklistedMlLabels = <String>{
    'rectangle', 'square', 'circle', 'oval', 'triangle',
    'font', 'text', 'line', 'parallel', 'pattern',
    'material property', 'electric blue', 'magenta', 'tints and shades',
    'grey', 'beige', 'azure',
  };
}
