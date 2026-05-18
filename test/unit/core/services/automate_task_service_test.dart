// Integration-flavoured unit tests for AutomateTaskService — exercises
// the full Hive round-trip (adapter registration + put/get) so the
// hand-written `.g.dart` adapters can't silently regress.
//
// Each test gets a fresh temp Hive dir + a freshly-reset service
// singleton. We use `Hive.init(path)` (NOT `Hive.initFlutter`) because
// flutter_test has no path_provider plugin available.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/automate_task_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('automate_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await AutomateTaskService.instance.resetForTesting();
    // Drop all box files so the next test's `openBox` starts clean.
    await Hive.deleteFromDisk();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows sometimes holds the dir briefly; harmless in tests.
    }
  });

  group('AutomateTaskService.init', () {
    test('opens Hive boxes idempotently', () async {
      await AutomateTaskService.instance.init();
      expect(AutomateTaskService.instance.isInitialized, isTrue);
      // Second call is a no-op — must not throw.
      await AutomateTaskService.instance.init();
      expect(AutomateTaskService.instance.isInitialized, isTrue);
    });

    test('registers TargetApp / SendStatus / SendPlanRow / AutomateTask '
        'adapters', () async {
      await AutomateTaskService.instance.init();
      expect(Hive.isAdapterRegistered(41), isTrue,
          reason: 'TargetApp adapter');
      expect(Hive.isAdapterRegistered(42), isTrue,
          reason: 'SendStatus adapter');
      expect(Hive.isAdapterRegistered(44), isTrue,
          reason: 'SendPlanRow adapter');
      expect(Hive.isAdapterRegistered(50), isTrue,
          reason: 'AutomateTask adapter');
    });

    test('idempotent adapter registration — second init does NOT throw '
        'on already-registered adapters', () async {
      // First service init — registers adapters.
      await AutomateTaskService.instance.init();
      await AutomateTaskService.instance.resetForTesting();
      // Second service init — adapters are still in the global Hive
      // registry, but the service's isAdapterRegistered guards must
      // prevent re-registration (which would throw).
      await AutomateTaskService.instance.init();
      expect(AutomateTaskService.instance.isInitialized, isTrue);
    });
  });

  group('AutomateTaskService.getOrCreate', () {
    test('creates a fresh task with sane defaults when none exists', () async {
      await AutomateTaskService.instance.init();
      final task = await AutomateTaskService.instance.getOrCreate(
        tagId: 'tag-abc',
        tagName: 'automate-tasks-test',
      );
      expect(task.id, isNotEmpty);
      expect(task.tagId, 'tag-abc');
      expect(task.tagName, 'automate-tasks-test');
      expect(task.targetApp, TargetApp.whatsapp);
      expect(task.toFieldTemplate, '');
      expect(task.messageTemplate, '');
      expect(task.subjectTemplate, isNull);
      expect(task.rows, isEmpty);
      expect(task.attachmentLocalPath, isNull);
      expect(task.attachmentFileName, isNull);
      expect(task.attachmentCid, isNull);
    });

    test('returns the SAME task on a second call for the same tagId', () async {
      await AutomateTaskService.instance.init();
      final first = await AutomateTaskService.instance.getOrCreate(
          tagId: 'tag-x', tagName: 'x');
      final second = await AutomateTaskService.instance.getOrCreate(
          tagId: 'tag-x', tagName: 'x');
      expect(second.id, first.id,
          reason: 'one task per tag — must not duplicate');
    });
  });

  group('AutomateTaskService.save + findByTagId', () {
    test('save persists field changes (round-trip through Hive)', () async {
      await AutomateTaskService.instance.init();
      final task = await AutomateTaskService.instance.getOrCreate(
          tagId: 'tag-1', tagName: 'one');
      task.targetApp = TargetApp.telegram;
      task.toFieldTemplate = '{Phone}';
      task.messageTemplate = 'Hello {Name}';
      task.subjectTemplate = 'subj';
      task.rows = [
        SendPlanRow(
          recipient: '5551234567',
          displayName: 'Alice',
          message: 'Hello Alice',
          status: SendStatus.opened,
          openedAt: DateTime.utc(2026, 5, 17, 12),
          failureReason: null,
        ),
      ];
      task.attachmentLocalPath = '/tmp/file.pdf';
      task.attachmentFileName = 'file.pdf';
      task.attachmentCid = 'Qm123';
      await AutomateTaskService.instance.save(task);

      // Re-fetch via findByTagId — should return the same persisted state.
      final found = AutomateTaskService.instance.findByTagId('tag-1');
      expect(found, isNotNull);
      expect(found!.targetApp, TargetApp.telegram);
      expect(found.toFieldTemplate, '{Phone}');
      expect(found.messageTemplate, 'Hello {Name}');
      expect(found.subjectTemplate, 'subj');
      expect(found.rows, hasLength(1));
      expect(found.rows.first.recipient, '5551234567');
      expect(found.rows.first.displayName, 'Alice');
      expect(found.rows.first.status, SendStatus.opened);
      expect(found.rows.first.openedAt, DateTime.utc(2026, 5, 17, 12));
      expect(found.attachmentLocalPath, '/tmp/file.pdf');
      expect(found.attachmentFileName, 'file.pdf');
      expect(found.attachmentCid, 'Qm123');
    });

    test('survives a service-reset cycle (true on-disk persistence)',
        () async {
      // Write
      await AutomateTaskService.instance.init();
      final t = await AutomateTaskService.instance.getOrCreate(
          tagId: 'persist-1', tagName: 'p');
      t.messageTemplate = 'persisted';
      await AutomateTaskService.instance.save(t);

      // Close boxes
      await AutomateTaskService.instance.resetForTesting();

      // Re-init (re-opens boxes from disk)
      await AutomateTaskService.instance.init();
      final found = AutomateTaskService.instance.findByTagId('persist-1');
      expect(found, isNotNull);
      expect(found!.messageTemplate, 'persisted');
    });

    test('findByTagId returns null for unknown tag', () async {
      await AutomateTaskService.instance.init();
      expect(AutomateTaskService.instance.findByTagId('nope'), isNull);
    });

    test('statusStream emits the saved task to listeners', () async {
      await AutomateTaskService.instance.init();
      final task = await AutomateTaskService.instance.getOrCreate(
          tagId: 'stream-1', tagName: 's');

      final received = <AutomateTask>[];
      final sub = AutomateTaskService.instance.statusStream.listen(received.add);

      task.messageTemplate = 'first';
      await AutomateTaskService.instance.save(task);
      task.messageTemplate = 'second';
      await AutomateTaskService.instance.save(task);

      // Give the broadcast stream a chance to dispatch synchronously.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received, hasLength(2),
          reason: 'one emit per save() call');
      expect(received.last.messageTemplate, 'second');
    });
  });

  group('AutomateTaskService.deleteTasksForTag', () {
    test('removes the task and its asset comments together', () async {
      await AutomateTaskService.instance.init();
      await AutomateTaskService.instance
          .getOrCreate(tagId: 'tag-del', tagName: 'd');
      await AutomateTaskService.instance
          .setAssetComment('tag-del', 'file-1', 'note');
      expect(AutomateTaskService.instance.findByTagId('tag-del'), isNotNull);
      expect(
          AutomateTaskService.instance.getAssetComment('tag-del', 'file-1'),
          'note');

      await AutomateTaskService.instance.deleteTasksForTag('tag-del');

      expect(AutomateTaskService.instance.findByTagId('tag-del'), isNull);
      expect(
          AutomateTaskService.instance.getAssetComment('tag-del', 'file-1'),
          isNull,
          reason: 'comments must cascade-delete with the task');
    });

    test('leaves other tags\' tasks and comments untouched', () async {
      await AutomateTaskService.instance.init();
      await AutomateTaskService.instance
          .getOrCreate(tagId: 'keep', tagName: 'k');
      await AutomateTaskService.instance
          .getOrCreate(tagId: 'drop', tagName: 'd');
      await AutomateTaskService.instance
          .setAssetComment('keep', 'fk', 'survive');
      await AutomateTaskService.instance
          .setAssetComment('drop', 'fd', 'gone');

      await AutomateTaskService.instance.deleteTasksForTag('drop');

      expect(AutomateTaskService.instance.findByTagId('keep'), isNotNull);
      expect(AutomateTaskService.instance.findByTagId('drop'), isNull);
      expect(AutomateTaskService.instance.getAssetComment('keep', 'fk'),
          'survive');
      expect(AutomateTaskService.instance.getAssetComment('drop', 'fd'),
          isNull);
    });
  });

}
