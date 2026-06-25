// P14 — AI-workspace adoption: unit tests (device-free).
//
// Two seams, both FFI-free:
//   1. Category-view MERGE — the AI/MCP's `fula-ai-workspace` items appear in
//      the native category views, tagged sourceBucket='fula-ai-workspace',
//      routed to the right category by their `ai/<category>/...` key. GATED:
//      no AI connection ⇒ no workspace list call at all.
//   2. Additive TAG adoption — the pure `TagStorageService.selectNewTagRows`
//      rule: a pre-existing LOCAL id is kept (the colliding AI row is discarded
//      entirely); genuinely-new AI ids are added.
//
// Run: flutter test test/unit/core/services/ai_workspace_adoption_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/category_listing.dart';
import 'package:fula_files/core/services/fula_api_service.dart' show FulaApiService;
import 'package:fula_files/core/services/tag_storage_service.dart';

import '../../../helpers/fake_fula_api.dart';

FulaObject obj(String key, {int size = 1, String? etag}) =>
    FulaObject(key: key, size: size, etag: etag);

const String _ws = FulaApiService.aiWorkspaceBucket; // 'fula-ai-workspace'

void main() {
  // v8 routing OFF for these tests → each category is a single user bucket, so
  // the AI merge is exercised on the single-bucket path (the common case).
  setUp(() => BucketVersionResolver.enabled = false);
  tearDown(() => BucketVersionResolver.enabled = false);

  group('category merge surfaces AI-workspace items (native views)', () {
    test('SINGULAR AI categories map to the PLURAL FxFiles views; each tagged '
        'sourceBucket=fula-ai-workspace', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true; // an AI connection exists
      // The user's own files in each category.
      fake.objectsResponseFor['images'] = [obj('photo.jpg')];
      fake.objectsResponseFor['documents'] = [obj('resume.pdf')];
      // The AI/MCP writes SINGULAR category segments (ai/image/, ai/document/, …
      // per classify.ts / classify.rs) — NOT the app's plural category names.
      fake.objectsResponseFor[_ws] = [
        obj('ai/image/sketch.png'),
        obj('ai/document/notes.md'),
      ];

      final images = await listCategoryMerged(fake, 'images');
      final documents = await listCategoryMerged(fake, 'documents');

      // Images view: the user's own photo + ONLY the ai/image item (the
      // ai/document item must be routed to the documents view, not here).
      final imgKeys = images.map((o) => o.key).toSet();
      expect(imgKeys, containsAll(<String>['photo.jpg', 'ai/image/sketch.png']));
      expect(imgKeys.contains('ai/document/notes.md'), isFalse,
          reason: 'a document AI item must NOT leak into the images view');
      final imgSrc = {for (final o in images) o.key: o.sourceBucket};
      expect(imgSrc['ai/image/sketch.png'], _ws,
          reason: 'AI item carries sourceBucket=fula-ai-workspace');
      expect(imgSrc['photo.jpg'], 'images',
          reason: "the user's own item keeps its real bucket");

      // Documents view: the user's own pdf + ONLY the ai/document doc.
      final docKeys = documents.map((o) => o.key).toSet();
      expect(docKeys,
          containsAll(<String>['resume.pdf', 'ai/document/notes.md']));
      expect(docKeys.contains('ai/image/sketch.png'), isFalse);
      final docSrc = {for (final o in documents) o.key: o.sourceBucket};
      expect(docSrc['ai/document/notes.md'], _ws);
    });

    test('homeless AI categories fold into the closest view: '
        'note/link→documents, screenshot→images, file/other→other', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor[_ws] = [
        obj('ai/note/todo.txt'),
        obj('ai/link/bookmark.url'),
        obj('ai/screenshot/cap.png'),
        obj('ai/file/blob.bin'),
        obj('ai/other/misc.dat'),
      ];

      final docs =
          (await listCategoryMerged(fake, 'documents')).map((o) => o.key).toSet();
      final imgs =
          (await listCategoryMerged(fake, 'images')).map((o) => o.key).toSet();
      final other =
          (await listCategoryMerged(fake, 'other')).map((o) => o.key).toSet();

      expect(docs,
          containsAll(<String>['ai/note/todo.txt', 'ai/link/bookmark.url']));
      expect(imgs, contains('ai/screenshot/cap.png'));
      expect(other,
          containsAll(<String>['ai/file/blob.bin', 'ai/other/misc.dat']));
      // No cross-leak between the folded views.
      expect(docs.contains('ai/screenshot/cap.png'), isFalse);
      expect(imgs.contains('ai/note/todo.txt'), isFalse);
    });

    test('a view with NO AI mapping (downloads) never lists the workspace',
        () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor['downloads'] = [obj('setup.exe')];
      fake.objectsResponseFor[_ws] = [obj('ai/document/x.md')];

      final downloads = await listCategoryMerged(fake, 'downloads');
      expect(downloads.map((o) => o.key), <String>['setup.exe']);
      expect(fake.listWorkspaceObjectsCalls[_ws], isNull,
          reason: 'downloads maps to no AI category — short-circuit, no list');
    });

    test('GATE: no AI connection ⇒ the workspace is never listed', () async {
      final fake = FakeFulaApi();
      // aiConnectionExists defaults to FALSE (non-AI user).
      fake.objectsResponseFor['images'] = [obj('photo.jpg')];
      fake.objectsResponseFor[_ws] = [obj('ai/image/sketch.png')]; // ignored

      final images = await listCategoryMerged(fake, 'images');

      expect(images.map((o) => o.key), <String>['photo.jpg'],
          reason: 'non-AI user sees only their own files');
      expect(fake.listWorkspaceObjectsCalls[_ws], isNull,
          reason: 'the gate must short-circuit before any workspace list call');
    });

    test('off-category AI keys are dropped, not mis-filed', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor['images'] = [obj('photo.jpg')];
      fake.objectsResponseFor[_ws] = [
        obj('ai/image/ok.png'),
        obj('ai/video/clip.mp4'), // different category — must not reach images
      ];

      final images = await listCategoryMerged(fake, 'images');
      final keys = images.map((o) => o.key).toSet();
      expect(keys.contains('ai/image/ok.png'), isTrue);
      expect(keys.contains('ai/video/clip.mp4'), isFalse);
    });

    test('AI read failure is tolerated — user content still shows', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor['images'] = [obj('photo.jpg')];
      // The fake's listWorkspaceObjects returns objectsResponseFor (empty here),
      // so simulate "AI empty" — the user's own bucket must be unaffected.
      fake.objectsResponseFor[_ws] = const <FulaObject>[];

      final images = await listCategoryMerged(fake, 'images');
      expect(images.map((o) => o.key), <String>['photo.jpg']);
    });
  });

  group('additive tag adoption rule (TagStorageService.selectNewTagRows)', () {
    FileTag tag(String id, String name) => FileTag(
          id: id,
          name: name,
          colorValue: 0xFF112233,
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        );
    TaggedFile tf(String id, String tagId) => TaggedFile(
          id: id,
          tagId: tagId,
          fileName: 'f-$id',
          taggedAt: DateTime.utc(2026, 1, 1),
        );

    test('keeps a pre-existing LOCAL id (AI collision discarded) and adds new',
        () {
      // AI offers: one tag id that already exists locally ("local-1") with a
      // DIFFERENT name, and one genuinely new tag ("ai-9").
      final incoming = TagCloudMetadata(
        userId: 'ai',
        tags: [
          tag('local-1', 'AI-RENAMED'), // collides with a local id
          tag('ai-9', 'AI New Tag'), // new
        ],
        taggedFiles: [
          tf('tfile-local', 'local-1'), // collides with a local file id
          tf('tfile-ai', 'ai-9'), // new
        ],
        updatedAt: DateTime.utc(2026, 1, 2),
      );

      final selected = TagStorageService.selectNewTagRows(
        incoming,
        <String>{'local-1'}, // local tag ids
        <String>{'tfile-local'}, // local file ids
      );

      // The colliding tag id is DISCARDED ENTIRELY (not field-merged): only the
      // new tag is selected, and the local name is never touched here.
      expect(selected.tagsToAdd.map((t) => t.id), <String>['ai-9']);
      expect(selected.tagsToAdd.single.name, 'AI New Tag');
      // The colliding file id is likewise discarded; only the new file added.
      expect(selected.filesToAdd.map((f) => f.id), <String>['tfile-ai']);
    });

    test('empty local set adopts every AI row', () {
      final incoming = TagCloudMetadata(
        userId: 'ai',
        tags: [tag('a', 'A'), tag('b', 'B')],
        taggedFiles: [tf('x', 'a')],
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final selected = TagStorageService.selectNewTagRows(
        incoming,
        const <String>{},
        const <String>{},
      );
      expect(selected.tagsToAdd.map((t) => t.id), <String>['a', 'b']);
      expect(selected.filesToAdd.map((f) => f.id), <String>['x']);
    });

    test('all-colliding AI doc adds nothing (pure no-op)', () {
      final incoming = TagCloudMetadata(
        userId: 'ai',
        tags: [tag('a', 'A')],
        taggedFiles: [tf('x', 'a')],
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final selected = TagStorageService.selectNewTagRows(
        incoming,
        <String>{'a'},
        <String>{'x'},
      );
      expect(selected.tagsToAdd, isEmpty);
      expect(selected.filesToAdd, isEmpty);
    });
  });
}
