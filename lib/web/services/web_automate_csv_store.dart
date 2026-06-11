import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Browser-side stand-in for the app's sandbox files behind an Automate
/// task. The native flow copies the picked CSV (and optional attachment)
/// into the app's Documents sandbox and stores the path; a browser has
/// no durable file paths, so the bytes themselves live in a Hive box
/// (IndexedDB) keyed by the task's tagId. Same locality contract as the
/// app: recipients/attachments are per-device, while the task's tag
/// syncs through the cloud tag manifest.
class WebAutomateCsvStore {
  WebAutomateCsvStore._();
  static final WebAutomateCsvStore instance = WebAutomateCsvStore._();

  static const _boxName = 'web_automate_files';

  /// Attachments are held base64 in IndexedDB; keep them bounded so a
  /// stray pick can't blow up browser storage. IPFS-share use cases
  /// (a PDF, an image, a flyer) sit far below this.
  static const int maxAttachmentBytes = 25 * 1024 * 1024;

  Box<String>? _box;

  Future<Box<String>> _open() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    final box = await Hive.openBox<String>(_boxName);
    _box = box;
    return box;
  }

  String _csvKey(String tagId) => '$tagId|csv';
  String _attachmentKey(String tagId) => '$tagId|attachment';

  // ------------------------------------------------------------- CSV

  Future<void> saveCsv({
    required String tagId,
    required String fileName,
    required String csvText,
  }) async {
    final box = await _open();
    await box.put(
        _csvKey(tagId), jsonEncode({'name': fileName, 'csv': csvText}));
  }

  /// Returns the stored recipients CSV for [tagId], or null when none
  /// was imported on this browser yet.
  Future<({String fileName, String csvText})?> readCsv(String tagId) async {
    final box = await _open();
    final raw = box.get(_csvKey(tagId));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        fileName: (m['name'] as String?) ?? 'recipients.csv',
        csvText: (m['csv'] as String?) ?? '',
      );
    } catch (e) {
      debugPrint('WebAutomateCsvStore.readCsv parse failed: $e');
      return null;
    }
  }

  Future<void> removeCsv(String tagId) async {
    final box = await _open();
    await box.delete(_csvKey(tagId));
  }

  // ------------------------------------------------------ attachment

  Future<void> saveAttachment({
    required String tagId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final box = await _open();
    await box.put(_attachmentKey(tagId),
        jsonEncode({'name': fileName, 'b64': base64Encode(bytes)}));
  }

  Future<({String fileName, Uint8List bytes})?> readAttachment(
      String tagId) async {
    final box = await _open();
    final raw = box.get(_attachmentKey(tagId));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        fileName: (m['name'] as String?) ?? 'file',
        bytes: base64Decode((m['b64'] as String?) ?? ''),
      );
    } catch (e) {
      debugPrint('WebAutomateCsvStore.readAttachment parse failed: $e');
      return null;
    }
  }

  Future<void> removeAttachment(String tagId) async {
    final box = await _open();
    await box.delete(_attachmentKey(tagId));
  }

  /// Drop everything stored for a task (called on task delete).
  Future<void> removeAll(String tagId) async {
    await removeCsv(tagId);
    await removeAttachment(tagId);
  }
}
