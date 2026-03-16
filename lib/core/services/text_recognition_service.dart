import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// Service for extracting text from images using ML Kit
class TextRecognitionService {
  TextRecognitionService._();
  static final TextRecognitionService instance = TextRecognitionService._();

  /// Recognize text in an image, returns full text or null if none found
  Future<String?> recognizeText(String imagePath) async {
    if (!PlatformCapabilities.isMobile) return null;

    final textRecognizer = TextRecognizer();
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await textRecognizer.processImage(inputImage);
      final text = recognizedText.text.trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      debugPrint('TextRecognitionService error: $e');
      rethrow;
    } finally {
      await textRecognizer.close();
    }
  }
}
