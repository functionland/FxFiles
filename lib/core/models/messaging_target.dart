import 'package:hive_flutter/hive_flutter.dart';

part 'messaging_target.g.dart';

/// Shared messaging-target types, used by both:
///   - the (currently HIDDEN) AI Automation feature in
///     `lib/features/ai_tasks/` + `lib/core/models/ai_task.dart`, and
///   - the active Automate feature in `lib/features/automate/`.
///
/// These types were previously defined in `ai_task.dart`. They were moved
/// here when the AI feature was hidden and the deterministic Automate
/// feature was added — to keep one canonical definition (same Hive
/// typeIds, so existing on-disk data stays readable) rather than
/// duplicating per-feature.

/// Target messaging app for a bulk-send task. Determines the URL scheme
/// used at send time; `lib/core/utils/target_uri_builder.dart` knows the
/// per-app format.
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
