// ⚠️ HIDDEN — AI feature paused (see CreateSection's isAiEnabled gate).
// Source intact for future re-enable. See plan:
// C:\Users\ehsan\.claude\plans\now-i-need-a-keen-kahan.md
//
// `TargetApp`, `SendStatus`, `SendPlanRow` were moved out of this file
// into `lib/core/models/messaging_target.dart` so the still-active
// "Automate" feature can use them too. Re-exported below so any
// existing AI code that imports `ai_task.dart` keeps compiling.

import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/messaging_target.dart';

export 'package:fula_files/core/models/messaging_target.dart'
    show TargetApp, SendStatus, SendPlanRow;

part 'ai_task.g.dart';

/// Pre-defined automation task types. Only one supported in v1 (CRM
/// Automation); the enum exists so adding more types later doesn't require
/// changing every storage path.
@HiveType(typeId: 40)
enum AiTaskType {
  @HiveField(0)
  crmAutomation,
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
