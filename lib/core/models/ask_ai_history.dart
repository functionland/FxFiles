import 'package:hive_flutter/hive_flutter.dart';

part 'ask_ai_history.g.dart';

@HiveType(typeId: 28)
class AskAiHistory extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String tagId;

  @HiveField(2)
  final String tagName;

  @HiveField(3)
  final List<String> filenames;

  @HiveField(4)
  final String prompt;

  @HiveField(5)
  final String response;

  @HiveField(6)
  final DateTime createdAt;

  @HiveField(7)
  final bool deleted; // Tombstone marker

  AskAiHistory({
    required this.id,
    required this.tagId,
    required this.tagName,
    required this.filenames,
    required this.prompt,
    required this.response,
    required this.createdAt,
    this.deleted = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tagId': tagId,
      'tagName': tagName,
      'filenames': filenames,
      'prompt': prompt,
      'response': response,
      'createdAt': createdAt.toIso8601String(),
      'deleted': deleted,
      'v': 1,
    };
  }

  factory AskAiHistory.fromJson(Map<String, dynamic> json) {
    return AskAiHistory(
      id: json['id'] as String,
      tagId: json['tagId'] as String,
      tagName: json['tagName'] as String,
      filenames: (json['filenames'] as List?)?.cast<String>() ?? [],
      prompt: json['prompt'] as String? ?? '',
      response: json['response'] as String? ?? '',
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : DateTime.now(),
      deleted: json['deleted'] as bool? ?? false,
    );
  }
}
