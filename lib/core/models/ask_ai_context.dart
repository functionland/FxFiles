import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/shelf_item.dart';

abstract class AskAiContext {
  String get id;
  String get name;
  List<TaggedFile> get files;
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
  List<TaggedFile> get files => _files;

  @override
  String? get contextualPromptSuffix => null;
}

class ShelfAskAiContext implements AskAiContext {
  final ShelfItem item;
  final TaggedFile? _dummyFile;

  ShelfAskAiContext(this.item) : _dummyFile = _createDummyFile(item);

  static TaggedFile? _createDummyFile(ShelfItem item) {
    if (item.category == ShelfCategory.link) return null;
    return TaggedFile(
      id: item.id,
      tagId: '',
      fileName: item.originalName,
      remoteKey: item.remoteKey,
      localPath: 'dump://${item.id}',
      taggedAt: item.receivedAt,
    );
  }

  @override
  String get id => 'shelf_${item.id}';

  @override
  String get name => item.originalName;

  @override
  List<TaggedFile> get files => _dummyFile != null ? [_dummyFile!] : [];

  @override
  String? get contextualPromptSuffix =>
      item.category == ShelfCategory.link 
          ? '\n\nContextual Link: ${item.textPayload ?? item.originalName}' 
          : null;
}
