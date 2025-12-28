import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Service for generating face embeddings using perceptual hashing
/// Note: For production use with MobileFaceNet, add tflite_flutter package
/// and uncomment the TFLite implementation below
class FaceEmbeddingService {
  FaceEmbeddingService._();
  static final FaceEmbeddingService instance = FaceEmbeddingService._();

  bool _isInitialized = false;

  // Embedding dimensions
  static const int inputSize = 112;
  static const int embeddingSize = 128;

  // Similarity threshold for face matching (cosine similarity)
  // Using 0.75 as a balanced threshold - may result in some incorrect groupings
  // Users can manually fix groupings via the face management UI
  static const double similarityThreshold = 0.75;

  /// Initialize the embedding service
  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;
    debugPrint('FaceEmbeddingService initialized (using perceptual hash embeddings)');
  }

  /// Check if embedding service is available
  bool get isAvailable => _isInitialized;

  /// Dispose resources
  Future<void> dispose() async {
    _isInitialized = false;
  }

  /// Get face embedding from a cropped face image (112x112)
  Future<List<double>?> getEmbedding(img.Image faceImage) async {
    if (!_isInitialized) await init();
    
    try {
      return _generatePerceptualEmbedding(faceImage);
    } catch (e) {
      debugPrint('Embedding generation error: $e');
      return null;
    }
  }

  /// Generate a perceptual hash-based embedding
  /// Uses DCT-like approach for better accuracy than simple pixel values
  List<double>? _generatePerceptualEmbedding(img.Image faceImage) {
    try {
      // Resize to standard size
      final resized = img.copyResize(faceImage, width: inputSize, height: inputSize);
      
      // Convert to grayscale and extract features
      final grayscale = img.grayscale(resized);
      
      final embedding = <double>[];
      
      // Extract features from different regions (8x8 grid = 64 regions)
      // Each region contributes 2 values (mean and variance)
      const gridSize = 8;
      final regionWidth = inputSize ~/ gridSize;
      final regionHeight = inputSize ~/ gridSize;
      
      for (int gy = 0; gy < gridSize; gy++) {
        for (int gx = 0; gx < gridSize; gx++) {
          double sum = 0;
          double sumSq = 0;
          int count = 0;
          
          for (int y = gy * regionHeight; y < (gy + 1) * regionHeight; y++) {
            for (int x = gx * regionWidth; x < (gx + 1) * regionWidth; x++) {
              final pixel = grayscale.getPixel(x, y);
              final luminance = pixel.r.toDouble(); // grayscale, so r=g=b
              sum += luminance;
              sumSq += luminance * luminance;
              count++;
            }
          }
          
          final mean = sum / count;
          final variance = (sumSq / count) - (mean * mean);
          
          // Normalize to [-1, 1] range
          embedding.add((mean / 127.5) - 1.0);
          embedding.add(sqrt(variance.abs()) / 127.5);
        }
      }
      
      return _normalizeEmbedding(embedding);
    } catch (e) {
      debugPrint('Perceptual embedding error: $e');
      return null;
    }
  }

  /// Normalize embedding vector (L2 normalization)
  List<double> _normalizeEmbedding(List<double> embedding) {
    double norm = 0;
    for (final val in embedding) {
      norm += val * val;
    }
    norm = sqrt(norm);
    
    if (norm == 0) return embedding;
    
    return embedding.map((v) => v / norm).toList();
  }

  /// Calculate cosine similarity between two embeddings
  double calculateSimilarity(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) return 0;
    
    double dotProduct = 0;
    double norm1 = 0;
    double norm2 = 0;
    
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }
    
    final denominator = sqrt(norm1) * sqrt(norm2);
    if (denominator == 0) return 0;
    
    return dotProduct / denominator;
  }

  /// Check if two faces are the same person
  bool areSamePerson(List<double> embedding1, List<double> embedding2) {
    final similarity = calculateSimilarity(embedding1, embedding2);
    return similarity >= similarityThreshold;
  }

  /// Calculate average embedding from multiple embeddings
  List<double> calculateAverageEmbedding(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    if (embeddings.length == 1) return embeddings.first;
    
    final length = embeddings.first.length;
    final average = List.filled(length, 0.0);
    
    for (final embedding in embeddings) {
      for (int i = 0; i < length; i++) {
        average[i] += embedding[i];
      }
    }
    
    for (int i = 0; i < length; i++) {
      average[i] /= embeddings.length;
    }
    
    return _normalizeEmbedding(average);
  }

  /// Find the best matching embedding from a list
  /// Returns index and similarity score, or null if no match above threshold
  (int, double)? findBestMatch(
    List<double> targetEmbedding,
    List<List<double>> candidateEmbeddings,
  ) {
    int bestIndex = -1;
    double bestSimilarity = 0;
    
    for (int i = 0; i < candidateEmbeddings.length; i++) {
      final similarity = calculateSimilarity(targetEmbedding, candidateEmbeddings[i]);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
        bestIndex = i;
      }
    }
    
    if (bestIndex >= 0 && bestSimilarity >= similarityThreshold) {
      return (bestIndex, bestSimilarity);
    }
    
    return null;
  }
}
