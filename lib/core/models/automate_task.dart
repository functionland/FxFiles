import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/messaging_target.dart';

part 'automate_task.g.dart';

/// One Automate task. Persisted in the `automate_tasks` Hive box.
///
/// Architecturally identical to `AiTask` (the now-HIDDEN AI Automation
/// feature) except for what produces the per-row templates:
///   - AI flow: an on-device LLM read the user's natural-language prompt
///     and inferred a template + recipient column.
///   - Automate flow (this): the user picks the recipient and types the
///     template directly using `{Column}` placeholders extracted from
///     the CSV header. No model, no inference, no LLM dependencies.
///
/// Shape decisions:
///   - `targetApp` / `SendPlanRow` are reused from `messaging_target.dart`
///     so the launch + per-row UI is identical to (and was lifted from)
///     the AI flow.
///   - `toFieldTemplate` is the TO field as the user typed it; e.g.
///     `+1{Phone}` will render to `+15551234567` for a row with
///     `Phone=5551234567`. This is then passed through
///     `TargetUriBuilder.normalizePhone` which strips the `+` for
///     wa.me etc. Invalid phones → row marked failed before send.
///   - `subjectTemplate` is only meaningful when `targetApp == email`.
@HiveType(typeId: 50)
class AutomateTask extends HiveObject {
  @HiveField(0)
  final String id; // UUID

  @HiveField(1)
  final String tagId; // automate-tasks-* tag

  @HiveField(2)
  final String tagName;

  @HiveField(3)
  TargetApp targetApp;

  /// User-authored TO-field template — typically a placeholder like
  /// `{Phone}` or `+1{Phone}` for WhatsApp/SMS, `{Email}` for email.
  @HiveField(4)
  String toFieldTemplate;

  /// User-authored message template with `{Column}` placeholders.
  @HiveField(5)
  String messageTemplate;

  /// Optional email subject template (email target only).
  @HiveField(6)
  String? subjectTemplate;

  @HiveField(7)
  final DateTime createdAt;

  @HiveField(8)
  DateTime updatedAt;

  /// Send plan — one entry per CSV row after deterministic template
  /// expansion. Empty until the user taps Run.
  @HiveField(9)
  List<SendPlanRow> rows;

  AutomateTask({
    required this.id,
    required this.tagId,
    required this.tagName,
    required this.targetApp,
    this.toFieldTemplate = '',
    this.messageTemplate = '',
    this.subjectTemplate,
    required this.createdAt,
    required this.updatedAt,
    this.rows = const [],
  });
}
