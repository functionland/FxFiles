import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/shelf_item.dart';

/// One file the user wants Ask AI to read, with everything needed to FETCH it.
///
/// This exists because a [TaggedFile] cannot express which cloud bucket an
/// object lives in — the tag manifest stores only a `remoteKey`, and the bucket
/// is recorded on a sibling field (`ShelfItem.sourceBucket`,
/// `SyncState.remoteBucket`). Flattening a shelf item into a `TaggedFile` threw
/// that bucket away, so the uploader had to guess it from the key and got it
/// wrong. Carrying an explicit descriptor keeps the bucket intact without a
/// Hive migration on the persisted tag model.
class AskAiAttachment {
  /// Display name; also decides the media type server-side.
  final String fileName;

  /// On-device path, when the file exists locally (native only).
  final String? localPath;

  /// iOS PhotoKit asset id, for virtual paths.
  final String? iosAssetId;

  /// Cloud object key. May be bare (`2026/07/x.pdf`, `photo.jpg`) or the
  /// composite `bucket/key` form the web cloud browser writes.
  final String? remoteKey;

  /// Authoritative bucket for [remoteKey] when it is known.
  final String? sourceBucket;

  /// Owning feature's default bucket base, used when [sourceBucket] is absent
  /// and [remoteKey] carries no bucket — e.g. `'dump'` for shelf items, so a
  /// pre-P7 row is not guessed from its file extension.
  final String? fallbackBucketBase;

  const AskAiAttachment({
    required this.fileName,
    this.localPath,
    this.iosAssetId,
    this.remoteKey,
    this.sourceBucket,
    this.fallbackBucketBase,
  });

  factory AskAiAttachment.fromTaggedFile(TaggedFile file) => AskAiAttachment(
        fileName: file.fileName,
        localPath: file.localPath,
        iosAssetId: file.iosAssetId,
        remoteKey: file.remoteKey,
      );
}

abstract class AskAiContext {
  String get id;
  String get name;

  /// The files to upload — the single source of truth for what is asked
  /// about, counted against the 30-file cap, and recorded in history.
  ///
  /// There is deliberately no parallel `List<TaggedFile> files`: a second
  /// representation of the same set can drift from this one, and a
  /// `TaggedFile` cannot carry the bucket anyway.
  List<AskAiAttachment> get attachments;

  String? get contextualPromptSuffix;
}

class TagAskAiContext implements AskAiContext {
  final FileTag tag;
  final List<TaggedFile> _files;

  TagAskAiContext(this.tag, this._files);

  @override
  String get id => tag.id;

  @override
  String get name => tag.name;

  @override
  List<AskAiAttachment> get attachments =>
      _files.map(AskAiAttachment.fromTaggedFile).toList();

  @override
  String? get contextualPromptSuffix => null;
}

class ShelfAskAiContext implements AskAiContext {
  final ShelfItem item;

  ShelfAskAiContext(this.item);

  @override
  String get id => 'shelf_${item.id}';

  @override
  String get name => item.originalName;

  @override
  List<AskAiAttachment> get attachments {
    // A link has no body to upload — it travels as prompt text instead. This
    // is the ONE legitimate zero-attachment case.
    if (item.category == ShelfCategory.link) return const <AskAiAttachment>[];

    final recorded = item.sourceBucket;
    return [
      AskAiAttachment(
        fileName: item.originalName,
        // The REAL on-device copy. (The shelf's `dump://<id>` string is a
        // synthetic TAG-ASSOCIATION identity, not a path — it never resolves
        // to a file, which is why the old code always fell through to a
        // mis-parsed cloud fetch.)
        localPath: item.localCachePath,
        remoteKey: item.remoteKey,
        // shelf_item.dart documents a null sourceBucket as the LEGACY `dump`
        // bucket (pre-P7 rows), so resolve it here rather than letting the
        // generic resolver guess a category from the file extension.
        sourceBucket: (recorded != null && recorded.isNotEmpty)
            ? recorded
            : 'dump',
        fallbackBucketBase: 'dump',
      ),
    ];
  }

  @override
  String? get contextualPromptSuffix => item.category == ShelfCategory.link
      ? '\n\nContextual Link: ${item.textPayload ?? item.originalName}'
      : null;
}
