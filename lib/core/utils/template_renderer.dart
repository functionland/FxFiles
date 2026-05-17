/// Deterministic `{Column}` substitution used by both:
///   - the (hidden) AI Automation feature, after the LLM extracts a
///     template — substituting the template against each row, and
///   - the active Automate feature, where the user wrote the template
///     themselves with column-name placeholders.
///
/// Lifted from `ai_task_detail_screen.dart`'s inline `_renderTemplate`
/// to share one canonical implementation.
class TemplateRenderer {
  TemplateRenderer._();

  /// Substitute `{Column}` placeholders inside [template] with the
  /// corresponding values from [row]. Matching is exact first, then
  /// case-insensitive; placeholders that don't match any column are
  /// left verbatim (e.g. `{XYZ}` stays `{XYZ}`) so the user gets
  /// visual feedback that something's off rather than a silent blank.
  static String render(String template, Map<String, String> row) {
    return template.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) {
      final key = m.group(1)!;
      // Exact match first, then case-insensitive.
      if (row.containsKey(key)) return row[key]!;
      for (final entry in row.entries) {
        if (entry.key.toLowerCase() == key.toLowerCase()) {
          return entry.value;
        }
      }
      return m.group(0)!;
    });
  }
}
