import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/services/ai_model_service.dart';

/// Streams the current model download status. The download card and any
/// "Run task" gate use this to decide what to render.
final aiModelStatusProvider = StreamProvider<AiModelEvent>((ref) async* {
  // Seed with the last known event so widgets don't flash through a
  // "loading" state on mount when the model is already ready.
  yield AiModelService.instance.lastEvent;
  yield* AiModelService.instance.statusStream;
});
