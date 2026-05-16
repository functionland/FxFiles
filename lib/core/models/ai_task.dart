import 'package:hive_flutter/hive_flutter.dart';

part 'ai_task.g.dart';

/// Pre-defined automation task types. Only one supported in v1 (CRM
/// Automation); the enum exists so adding more types later doesn't require
/// changing every storage path.
@HiveType(typeId: 40)
enum AiTaskType {
  @HiveField(0)
  crmAutomation,
}

/// Target messaging app for a CRM-automation task. Determines the URL
/// scheme used at send time; `target_uri_builder.dart` knows the per-app
/// format.
@HiveType(typeId: 41)
enum TargetApp {
  @HiveField(0)
  whatsapp,
  @HiveField(1)
  telegram,
  @HiveField(2)
  sms,
  @HiveField(3)
  email,
}

/// Per-row send status. `opened` = user tapped the Open button (we
/// launched the target app), `sent` = we assume the user actually tapped
/// Send (best-effort heuristic; the OS gives us no programmatic confirm).
@HiveType(typeId: 42)
enum SendStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  opened,
  @HiveField(2)
  sent,
  @HiveField(3)
  skipped,
  @HiveField(4)
  failed,
}

/// A single row in a task's send-plan — one recipient + the pre-rendered
/// message that will be passed to the target app's URL scheme.
@HiveType(typeId: 44)
class SendPlanRow extends HiveObject {
  @HiveField(0)
  final String recipient; // phone (digits) or email address

  @HiveField(1)
  final String? displayName;

  @HiveField(2)
  String message;

  @HiveField(3)
  SendStatus status;

  @HiveField(4)
  DateTime? openedAt;

  /// Optional failure reason — e.g. "phone number invalid".
  @HiveField(5)
  String? failureReason;

  SendPlanRow({
    required this.recipient,
    this.displayName,
    required this.message,
    this.status = SendStatus.pending,
    this.openedAt,
    this.failureReason,
  });
}

/// One AI automation task. Persisted in the `ai_tasks` Hive box. Parallel
/// of `WebsiteGeneration` for the website builder — same lifecycle shape
/// (created → configured → run → results stored on the same record).
@HiveType(typeId: 43)
class AiTask extends HiveObject {
  @HiveField(0)
  final String id; // UUID

  @HiveField(1)
  final String tagId; // ai-tasks-* tag

  @HiveField(2)
  final String tagName;

  @HiveField(3)
  AiTaskType taskType;

  @HiveField(4)
  TargetApp targetApp;

  @HiveField(5)
  String userPrompt;

  /// LLM-generated row template. Contains `{column}` placeholders that
  /// match the headers in the attached CSV.
  @HiveField(6)
  String? renderedTemplate;

  /// CSV column that holds the recipient (phone for whatsapp/telegram/sms,
  /// email for email target).
  @HiveField(7)
  String? recipientColumn;

  /// CSV column that holds the recipient's display name (optional, used
  /// for UI niceness — independent from `{name}` placeholders inside
  /// the template, which can come from any column).
  @HiveField(8)
  String? nameColumn;

  @HiveField(9)
  final DateTime createdAt;

  @HiveField(10)
  DateTime updatedAt;

  /// Send plan — one entry per CSV row after deterministic template
  /// expansion. Empty until the user runs the task.
  @HiveField(11)
  List<SendPlanRow> rows;

  AiTask({
    required this.id,
    required this.tagId,
    required this.tagName,
    required this.taskType,
    required this.targetApp,
    required this.userPrompt,
    this.renderedTemplate,
    this.recipientColumn,
    this.nameColumn,
    required this.createdAt,
    required this.updatedAt,
    this.rows = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'tagId': tagId,
        'tagName': tagName,
        'taskType': taskType.index,
        'targetApp': targetApp.index,
        'userPrompt': userPrompt,
        'renderedTemplate': renderedTemplate,
        'recipientColumn': recipientColumn,
        'nameColumn': nameColumn,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'rows': rows
            .map((r) => {
                  'recipient': r.recipient,
                  'displayName': r.displayName,
                  'message': r.message,
                  'status': r.status.index,
                  'openedAt': r.openedAt?.toIso8601String(),
                  'failureReason': r.failureReason,
                })
            .toList(),
      };
}
