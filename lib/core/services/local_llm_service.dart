// ⚠️ HIDDEN — AI feature paused (see CreateSection's isAiEnabled gate).
// See plan: C:\Users\ehsan\.claude\plans\now-i-need-a-keen-kahan.md

import 'dart:async';
import 'dart:convert';

import 'package:fllama/fllama.dart';
import 'package:flutter/widgets.dart';
import 'package:fula_files/core/services/ai_model_service.dart';
import 'package:fula_files/core/services/device_memory_service.dart';

/// Parsed output of [LocalLlmService.inferTemplate]. Used by the CRM
/// Automation task to render per-row messages deterministically.
class InferredCrmTemplate {
  /// Per-row message body. May contain `{column}` placeholders matching
  /// CSV headers (case-insensitive substitution).
  final String perRowTemplate;

  /// CSV column holding the recipient identifier (phone/email).
  final String recipientColumn;

  /// CSV column holding the recipient's display name, if the model
  /// returned one.
  final String? nameColumn;

  /// True if the result came from the manual fallback (heuristics +
  /// optional user edit), not the LLM. The UI surfaces this so the user
  /// knows to double-check.
  final bool fromFallback;

  const InferredCrmTemplate({
    required this.perRowTemplate,
    required this.recipientColumn,
    this.nameColumn,
    this.fromFallback = false,
  });
}

/// Thrown by [LocalLlmService.inferTemplate] when both the LLM and its
/// retry produce unusable output. The caller (AiTaskDetailScreen) catches
/// this and opens a manual editor sheet so the user can correct the
/// template + column mapping by hand. The feature always ships, even when
/// the model is unreliable.
class TemplateInferenceFailure implements Exception {
  final String message;
  final String? rawResponse;
  TemplateInferenceFailure(this.message, {this.rawResponse});
  @override
  String toString() => 'TemplateInferenceFailure: $message';
}

/// Thrown when the device doesn't have enough memory headroom to safely
/// load the LLM context. Distinct from [TemplateInferenceFailure] so the
/// caller can surface a different banner ("AI parsing skipped — your
/// device is low on memory") and still fall back to the heuristic path.
class LowMemoryException implements Exception {
  final int? headroomBytes;
  final MemoryTier tier;
  LowMemoryException({this.headroomBytes, required this.tier});
  @override
  String toString() =>
      'LowMemoryException: tier=$tier, headroom=$headroomBytes bytes';
}

/// Thrown when the model file on disk is missing, truncated, or has the
/// wrong magic bytes. fllama's native loader will SIGSEGV rather than
/// return an error on a bad GGUF header, so we MUST screen the file
/// before handing it to `initContext`. The file is also deleted from
/// disk when this is thrown so the user's next visit to the AI screen
/// triggers a fresh download instead of repeating the same crash loop.
class ModelCorruptException implements Exception {
  final String reason;
  ModelCorruptException(this.reason);
  @override
  String toString() => 'ModelCorruptException: $reason';
}

/// On-device LLM wrapper. Loads the GGUF model lazily on first inference
/// (3-5 s on a phone, depending on RAM) and may keep the context warm
/// between tasks on high-tier devices. The model runs **once per task**
/// and emits one JSON document — never per-row.
///
/// Memory-pressure aware: subscribes to
/// [WidgetsBindingObserver.didHaveMemoryPressure] and releases the
/// context immediately when the OS signals it's low on RAM.
///
/// Tier-driven parameters: [DeviceMemoryService.tuningProfile] decides
/// `nCtx`, `nBatch`, `nPredict`, `nThreads`, and whether to keep the
/// context warm. On [MemoryTier.insufficient] the LLM is not invoked at
/// all — callers should be checking `DeviceMemoryService.supportsOnDeviceLlm`
/// first and using the heuristic path instead.
class LocalLlmService with WidgetsBindingObserver {
  LocalLlmService._();
  static final LocalLlmService instance = LocalLlmService._();

  static const double _temperature = 0.2; // low — we want deterministic-ish JSON

  /// GBNF grammar that constrains the output to exactly the JSON object
  /// shape we expect. fllama 0.0.1 exposes `grammar` as a parameter on
  /// `completion`; when honoured by the underlying llama.cpp build the
  /// model literally cannot emit invalid JSON.
  ///
  /// Keep this in sync with [_buildPrompt]'s example output below.
  static const String _gbnfGrammar = r'''
root        ::= "{" ws "\"per_row_template\"" ws ":" ws string ws ","
                ws "\"recipient_column\"" ws ":" ws string
                (ws "," ws "\"name_column\"" ws ":" ws string)?
                ws "}" ws
string      ::= "\"" char* "\""
char        ::= [^"\\] | "\\" ["\\/bfnrt]
ws          ::= [ \t\n]*
''';

  double? _contextId;
  Future<double?>? _loading;
  bool _observerRegistered = false;

  /// Run the LLM (loading it lazily) and return a parsed
  /// [InferredCrmTemplate]. Throws:
  /// - [LowMemoryException] when the device tier blocks LLM use or
  ///   current headroom is below the per-platform safety threshold.
  /// - [ModelCorruptException] when the on-disk model file is missing
  ///   or has the wrong magic bytes. The file is deleted; the user's
  ///   next visit to the AI screen will offer a re-download.
  /// - [TemplateInferenceFailure] when both the grammar-constrained
  ///   attempt AND the regex-repaired retry fail.
  ///
  /// [headers] are the CSV column headers verbatim.
  /// [samples] are up to 3 rows used as in-prompt examples so the model
  /// sees what the data actually looks like (it does NOT iterate over
  /// every row).
  /// [prompt] is the user's natural-language request.
  Future<InferredCrmTemplate> inferTemplate({
    required List<String> headers,
    required List<Map<String, String>> samples,
    required String prompt,
  }) async {
    // ---- Pre-flight: memory tier + runtime headroom ----
    // DeviceMemoryService.init must already have resolved by the time
    // this is called (AiModelService.init awaits it). Tier is stable.
    final memSvc = DeviceMemoryService.instance;
    if (!memSvc.supportsOnDeviceLlm) {
      throw LowMemoryException(tier: memSvc.tier);
    }
    // One probe of current headroom — memory can drift between two
    // separate calls, so capture once and use the same value for both
    // the decision and the exception payload.
    final headroom = await memSvc.headroomBytes();
    if (!DeviceMemoryService.isHeadroomEnoughForLlm(headroom)) {
      throw LowMemoryException(headroomBytes: headroom, tier: memSvc.tier);
    }

    // ---- Pre-flight: model file integrity ----
    // Last line of defense before fllama. The native loader segfaults
    // on a bad GGUF header instead of returning an error, so we MUST
    // verify the file looks right before handing it over. Deleting the
    // file when this fails means the next AI-screen visit shows the
    // download UI rather than re-crashing on the same corrupt bytes.
    if (!await AiModelService.instance.isModelFileValid()) {
      await AiModelService.instance.deleteModel();
      throw ModelCorruptException(
          'Model file missing or magic bytes not GGUF — deleted, '
          're-download required');
    }

    final profile = memSvc.tuningProfile ?? LlmTuningProfile.high;
    _registerObserverIfNeeded();

    final ctx = await _ensureContext(profile);
    if (ctx == null) {
      throw TemplateInferenceFailure('Model failed to load');
    }

    try {
      // ---- Tier 1: grammar-constrained attempt ----
      final formatted = _buildPrompt(headers: headers, samples: samples, prompt: prompt);
      try {
        final result = await _completeAndParse(ctx, formatted, profile, useGrammar: true);
        if (result != null) return result;
      } catch (e) {
        debugPrint('LocalLlmService: tier-1 inference threw: $e');
      }

      // ---- Tier 2: stricter prompt + regex repair ----
      final stricter = '$formatted\n\nIMPORTANT: respond with ONLY one JSON '
          'object, wrapped in <json>…</json>. No prose, no markdown.\n';
      try {
        final result = await _completeAndParse(ctx, stricter, profile,
            useGrammar: false, expectTags: true);
        if (result != null) return result;
      } catch (e) {
        debugPrint('LocalLlmService: tier-2 inference threw: $e');
      }

      throw TemplateInferenceFailure(
          'Model output could not be parsed after two attempts');
    } finally {
      // On low/medium devices we don't keep the ~1 GB working set
      // around between tasks — release immediately. High tier devices
      // keep the context warm for fast re-runs.
      if (!profile.keepWarm) {
        await dispose();
      }
    }
  }

  /// Free model weights from memory. Call when navigating away from the
  /// AI flow or when memory pressure is reported.
  Future<void> dispose() async {
    final ctx = _contextId;
    _contextId = null;
    if (ctx != null) {
      try {
        await Fllama.instance()?.releaseContext(ctx);
      } catch (e) {
        debugPrint('LocalLlmService: releaseContext failed: $e');
      }
    }
  }

  /// [WidgetsBindingObserver] callback. Fired by the framework when the
  /// OS signals memory pressure. We drop the model context immediately —
  /// the next task pays the 3-5 s load cost again, but the alternative
  /// is being killed by the OS.
  @override
  void didHaveMemoryPressure() {
    debugPrint('LocalLlmService: memory pressure signal — releasing context');
    // Fire-and-forget; we can't await from a non-async override.
    unawaited(dispose());
  }

  // ---------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------

  void _registerObserverIfNeeded() {
    if (_observerRegistered) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observerRegistered = true;
    } catch (e) {
      // WidgetsBinding may not be initialised in some unit-test contexts.
      debugPrint('LocalLlmService: addObserver failed: $e');
    }
  }

  Future<double?> _ensureContext(LlmTuningProfile profile) async {
    if (_contextId != null) return _contextId;
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final c = Completer<double?>();
    _loading = c.future;
    try {
      final modelPath = await AiModelService.instance.modelFilePath();
      final fllama = Fllama.instance();
      if (fllama == null) {
        throw TemplateInferenceFailure('fllama platform not available');
      }
      final ctxResult = await fllama.initContext(
        modelPath,
        nCtx: profile.nCtx,
        nBatch: profile.nBatch,
        nThreads: profile.nThreads,
        useMmap: true,
        // useMlock=true pins pages and disables paging — fatal on phones.
        // The fllama default is true, so we MUST override.
        useMlock: false,
      );
      final id = (ctxResult?['contextId'] ?? ctxResult?['context_id']) as num?;
      _contextId = id?.toDouble();
      c.complete(_contextId);
      return _contextId;
    } catch (e) {
      debugPrint('LocalLlmService: _ensureContext error: $e');
      c.complete(null);
      return null;
    } finally {
      _loading = null;
    }
  }

  Future<InferredCrmTemplate?> _completeAndParse(
    double contextId,
    String prompt,
    LlmTuningProfile profile, {
    required bool useGrammar,
    bool expectTags = false,
  }) async {
    final fllama = Fllama.instance();
    if (fllama == null) return null;
    final response = await fllama.completion(
      contextId,
      prompt: prompt,
      grammar: useGrammar ? _gbnfGrammar : '',
      temperature: _temperature,
      nPredict: profile.nPredict,
      stop: const ['</json>', '<|eot_id|>', '<|end_of_text|>'],
    );
    final text = (response?['text'] ?? response?['content']) as String?;
    if (text == null || text.trim().isEmpty) return null;
    return _parseResponse(text, expectTags: expectTags);
  }

  /// Pull a JSON object out of the LLM's response and shape it into an
  /// [InferredCrmTemplate]. Returns null when no parse is possible
  /// (caller treats that as "try the next tier").
  InferredCrmTemplate? _parseResponse(String raw, {bool expectTags = false}) {
    String? jsonBlob;
    if (expectTags) {
      final m = RegExp(r'<json>\s*(\{[\s\S]*?\})\s*</json>').firstMatch(raw);
      jsonBlob = m?.group(1);
    }
    jsonBlob ??= _firstJsonObject(raw);
    if (jsonBlob == null) return null;

    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(jsonBlob) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final template = obj['per_row_template'];
    final recipient = obj['recipient_column'] ?? obj['phone_column'];
    final name = obj['name_column'];
    if (template is! String || recipient is! String) return null;
    if (template.trim().isEmpty || recipient.trim().isEmpty) return null;
    return InferredCrmTemplate(
      perRowTemplate: template,
      recipientColumn: recipient,
      nameColumn: name is String && name.trim().isNotEmpty ? name : null,
    );
  }

  /// Find the first balanced `{ ... }` JSON object in [text]. Tolerates
  /// model preamble like "Sure! Here's the JSON: { ... }".
  String? _firstJsonObject(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (ch == r'\') {
        escape = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) {
          return text.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  String _buildPrompt({
    required List<String> headers,
    required List<Map<String, String>> samples,
    required String prompt,
  }) {
    final sb = StringBuffer();
    sb.writeln(
        'You are a CRM template extractor. Given the CSV headers, up to '
        '3 sample rows, and a user request, output ONE JSON object with:');
    sb.writeln('- per_row_template: the message body with {column} placeholders');
    sb.writeln('- recipient_column: the column holding the phone or email');
    sb.writeln('- name_column: optional, the column holding the recipient name');
    sb.writeln('No prose, no markdown, no commentary. JSON object only.');
    sb.writeln();
    sb.writeln('Example:');
    sb.writeln('Headers: Name, Phone, City');
    sb.writeln('User request: "Send Hello {Name}, hope you\'re doing well to each row."');
    sb.writeln(
        'Output: {"per_row_template":"Hello {Name}, hope you\'re doing well","recipient_column":"Phone","name_column":"Name"}');
    sb.writeln();
    sb.writeln('Now do this one:');
    sb.writeln('Headers: ${headers.join(', ')}');
    if (samples.isNotEmpty) {
      sb.writeln('Sample rows:');
      for (final row in samples.take(3)) {
        sb.writeln('  ${jsonEncode(row)}');
      }
    }
    sb.writeln('User request: ${prompt.trim()}');
    sb.write('Output: ');
    return sb.toString();
  }
}
