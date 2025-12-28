import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/face_data.dart';
import 'package:fula_files/core/services/face_embedding_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';

/// Service for detecting faces in images using ML Kit
class FaceDetectionService {
  FaceDetectionService._();
  static final FaceDetectionService instance = FaceDetectionService._();

  FaceDetector? _faceDetector;
  bool _isInitialized = false;
  final _uuid = const Uuid();
  String? _thumbnailDir;
  
  // Queue for background processing
  final List<String> _processingQueue = [];
  bool _isQueueProcessing = false;
  
  // Callbacks for progress updates
  final List<void Function(String imagePath, int faceCount)> _listeners = [];

  /// Check if face detection is enabled in settings
  bool get isEnabled {
    return LocalStorageService.instance.getSetting<bool>('faceDetectionEnabled', defaultValue: true) ?? true;
  }

  /// Initialize the face detector
  Future<void> init() async {
    if (_isInitialized) return;
    
    try {
      final options = FaceDetectorOptions(
        enableContours: false,
        enableClassification: false,
        enableTracking: false,
        enableLandmarks: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.1,
      );
      
      _faceDetector = FaceDetector(options: options);
      
      // Create thumbnail directory
      final appDir = await getApplicationDocumentsDirectory();
      _thumbnailDir = p.join(appDir.path, 'face_thumbnails');
      final thumbDir = Directory(_thumbnailDir!);
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      
      _isInitialized = true;
      debugPrint('FaceDetectionService initialized');
    } catch (e) {
      debugPrint('Failed to initialize FaceDetectionService: $e');
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    await _faceDetector?.close();
    _faceDetector = null;
    _isInitialized = false;
  }

  /// Add listener for face detection updates
  void addListener(void Function(String imagePath, int faceCount) callback) {
    _listeners.add(callback);
  }

  /// Remove listener
  void removeListener(void Function(String imagePath, int faceCount) callback) {
    _listeners.remove(callback);
  }

  void _notifyListeners(String imagePath, int faceCount) {
    for (final listener in _listeners) {
      try {
        listener(imagePath, faceCount);
      } catch (e) {
        debugPrint('Face detection listener error: $e');
      }
    }
  }

  /// Check if an image has already been processed
  Future<bool> isImageProcessed(String imagePath) async {
    final state = await FaceStorageService.instance.getProcessingState(imagePath);
    return state != null && 
           (state.status == FaceProcessingStatus.completed || 
            state.status == FaceProcessingStatus.noFaces);
  }

  /// Queue an image for background face detection
  Future<void> queueImageForProcessing(String imagePath) async {
    if (!isEnabled) return;
    
    // Check if already processed
    if (await isImageProcessed(imagePath)) return;
    
    // Check if already in queue
    if (_processingQueue.contains(imagePath)) return;
    
    // Check if it's an image file
    if (!_isImageFile(imagePath)) return;
    
    _processingQueue.add(imagePath);
    _startQueueProcessing();
  }

  /// Queue multiple images for processing
  Future<void> queueImagesForProcessing(List<String> imagePaths) async {
    if (!isEnabled) return;
    
    for (final path in imagePaths) {
      if (!_isImageFile(path)) continue;
      if (await isImageProcessed(path)) continue;
      if (_processingQueue.contains(path)) continue;
      _processingQueue.add(path);
    }
    
    _startQueueProcessing();
  }

  bool _isImageFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'].contains(ext);
  }

  void _startQueueProcessing() {
    if (_isQueueProcessing || _processingQueue.isEmpty) return;
    _isQueueProcessing = true;
    _processNextInQueue();
  }

  Future<void> _processNextInQueue() async {
    if (_processingQueue.isEmpty) {
      _isQueueProcessing = false;
      return;
    }

    final imagePath = _processingQueue.removeAt(0);
    
    try {
      await processImage(imagePath);
    } catch (e) {
      debugPrint('Error processing image $imagePath: $e');
    }

    // Small delay to avoid blocking UI
    await Future.delayed(const Duration(milliseconds: 100));
    
    // Process next
    _processNextInQueue();
  }

  /// Process a single image for face detection
  Future<List<DetectedFace>> processImage(String imagePath) async {
    if (!isEnabled) return [];
    if (!_isInitialized) await init();
    if (_faceDetector == null) return [];

    try {
      // Update processing state
      await FaceStorageService.instance.updateProcessingState(
        imagePath,
        FaceProcessingStatus.processing,
      );

      final file = File(imagePath);
      if (!await file.exists()) {
        await FaceStorageService.instance.updateProcessingState(
          imagePath,
          FaceProcessingStatus.failed,
          errorMessage: 'File not found',
        );
        return [];
      }

      // Create input image
      final inputImage = InputImage.fromFilePath(imagePath);
      
      // Detect faces
      final faces = await _faceDetector!.processImage(inputImage);
      
      if (faces.isEmpty) {
        await FaceStorageService.instance.updateProcessingState(
          imagePath,
          FaceProcessingStatus.noFaces,
        );
        _notifyListeners(imagePath, 0);
        return [];
      }

      // Load image for cropping faces
      final imageBytes = await file.readAsBytes();
      final decodedImage = await _decodeImage(imageBytes);
      
      if (decodedImage == null) {
        await FaceStorageService.instance.updateProcessingState(
          imagePath,
          FaceProcessingStatus.failed,
          errorMessage: 'Failed to decode image',
        );
        return [];
      }

      final detectedFaces = <DetectedFace>[];

      for (final face in faces) {
        try {
          // Crop face region with padding
          final faceImage = _cropFace(decodedImage, face.boundingBox);
          
          if (faceImage == null) continue;

          // Get face embedding
          final embedding = await FaceEmbeddingService.instance.getEmbedding(faceImage);
          
          if (embedding == null || embedding.isEmpty) continue;

          // Save face thumbnail
          final faceId = _uuid.v4();
          String? thumbnailPath;
          if (_thumbnailDir != null) {
            thumbnailPath = await _saveFaceThumbnail(faceImage, faceId);
          }

          // Create face without auto-grouping - user will manually tag faces
          final detectedFace = DetectedFace(
            id: faceId,
            imagePath: imagePath,
            boundingBoxLeft: face.boundingBox.left,
            boundingBoxTop: face.boundingBox.top,
            boundingBoxWidth: face.boundingBox.width,
            boundingBoxHeight: face.boundingBox.height,
            embedding: embedding,
            personId: null, // No auto-grouping - faces start unnamed
            detectedAt: DateTime.now(),
            confidence: face.trackingId?.toDouble(),
            thumbnailPath: thumbnailPath,
          );

          detectedFaces.add(detectedFace);
          await FaceStorageService.instance.saveFace(detectedFace);
        } catch (e) {
          debugPrint('Error processing face in $imagePath: $e');
        }
      }

      // Update processing state
      await FaceStorageService.instance.updateProcessingState(
        imagePath,
        FaceProcessingStatus.completed,
        faceCount: detectedFaces.length,
      );

      _notifyListeners(imagePath, detectedFaces.length);
      
      // Sync face metadata to S3 in background
      FaceStorageService.instance.syncFaceMetadataToS3(imagePath, detectedFaces);

      return detectedFaces;
    } catch (e) {
      debugPrint('Face detection error for $imagePath: $e');
      await FaceStorageService.instance.updateProcessingState(
        imagePath,
        FaceProcessingStatus.failed,
        errorMessage: e.toString(),
      );
      return [];
    }
  }

  /// Decode image bytes to img.Image
  Future<img.Image?> _decodeImage(Uint8List bytes) async {
    try {
      return await compute(_decodeImageIsolate, bytes);
    } catch (e) {
      debugPrint('Image decode error: $e');
      return null;
    }
  }

  static img.Image? _decodeImageIsolate(Uint8List bytes) {
    try {
      return img.decodeImage(bytes);
    } catch (e) {
      return null;
    }
  }

  /// Save face thumbnail to disk
  Future<String?> _saveFaceThumbnail(img.Image faceImage, String faceId) async {
    try {
      final thumbnailPath = p.join(_thumbnailDir!, '$faceId.jpg');
      final jpegBytes = img.encodeJpg(faceImage, quality: 85);
      await File(thumbnailPath).writeAsBytes(jpegBytes);
      return thumbnailPath;
    } catch (e) {
      debugPrint('Failed to save face thumbnail: $e');
      return null;
    }
  }

  /// Crop face region from image with padding
  img.Image? _cropFace(img.Image image, ui.Rect boundingBox) {
    try {
      // Add 20% padding around face
      final padding = 0.2;
      final padX = (boundingBox.width * padding).toInt();
      final padY = (boundingBox.height * padding).toInt();
      
      int x = (boundingBox.left - padX).clamp(0, image.width - 1).toInt();
      int y = (boundingBox.top - padY).clamp(0, image.height - 1).toInt();
      int w = (boundingBox.width + padX * 2).clamp(1, image.width - x).toInt();
      int h = (boundingBox.height + padY * 2).clamp(1, image.height - y).toInt();
      
      final cropped = img.copyCrop(image, x: x, y: y, width: w, height: h);
      
      // Resize to 112x112 for MobileFaceNet
      return img.copyResize(cropped, width: 112, height: 112);
    } catch (e) {
      debugPrint('Crop face error: $e');
      return null;
    }
  }

  /// Get processing queue length
  int get queueLength => _processingQueue.length;

  /// Check if currently processing
  bool get isProcessing => _isQueueProcessing;

  /// Clear processing queue
  void clearQueue() {
    _processingQueue.clear();
    _isQueueProcessing = false;
  }

  /// Get faces for an image
  Future<List<DetectedFace>> getFacesForImage(String imagePath) async {
    return await FaceStorageService.instance.getFacesForImage(imagePath);
  }

  /// Search images by person
  Future<List<String>> searchImagesByPerson(String personId) async {
    return await FaceStorageService.instance.getImagesForPerson(personId);
  }
}
