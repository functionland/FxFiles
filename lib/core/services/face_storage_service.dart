import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/face_data.dart';
import 'package:fula_files/core/services/face_embedding_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

/// Service for storing and managing face data locally and in S3
class FaceStorageService {
  FaceStorageService._();
  static final FaceStorageService instance = FaceStorageService._();

  late Box<DetectedFace> _facesBox;
  late Box<Person> _personsBox;
  late Box<FaceProcessingState> _processingStateBox;
  bool _isInitialized = false;
  final _uuid = const Uuid();

  // S3 bucket for face metadata
  static const String _faceMetadataBucket = 'face-metadata';
  bool _bucketChecked = false;
  bool _bucketExists = false;

  /// Initialize Hive boxes for face storage
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // Register adapters if not already registered
      if (!Hive.isAdapterRegistered(10)) {
        Hive.registerAdapter(DetectedFaceAdapter());
      }
      if (!Hive.isAdapterRegistered(11)) {
        Hive.registerAdapter(PersonAdapter());
      }
      if (!Hive.isAdapterRegistered(12)) {
        Hive.registerAdapter(FaceProcessingStateAdapter());
      }
      if (!Hive.isAdapterRegistered(13)) {
        Hive.registerAdapter(FaceProcessingStatusAdapter());
      }

      _facesBox = await Hive.openBox<DetectedFace>('detected_faces');
      _personsBox = await Hive.openBox<Person>('persons');
      _processingStateBox = await Hive.openBox<FaceProcessingState>('face_processing_states');

      _isInitialized = true;
      debugPrint('FaceStorageService initialized');
    } catch (e) {
      debugPrint('Failed to initialize FaceStorageService: $e');
    }
  }

  /// Save a detected face
  Future<void> saveFace(DetectedFace face) async {
    if (!_isInitialized) await init();
    await _facesBox.put(face.id, face);
  }

  /// Get all faces for an image
  Future<List<DetectedFace>> getFacesForImage(String imagePath) async {
    if (!_isInitialized) await init();
    return _facesBox.values.where((f) => f.imagePath == imagePath).toList();
  }

  /// Get all faces for a person
  Future<List<DetectedFace>> getFacesForPerson(String personId) async {
    if (!_isInitialized) await init();
    return _facesBox.values.where((f) => f.personId == personId).toList();
  }

  /// Get all unnamed faces (faces without a personId)
  Future<List<DetectedFace>> getUnnamedFaces() async {
    if (!_isInitialized) await init();
    return _facesBox.values.where((f) => f.personId == null).toList();
  }

  /// Get count of unnamed faces
  Future<int> getUnnamedFaceCount() async {
    if (!_isInitialized) await init();
    return _facesBox.values.where((f) => f.personId == null).length;
  }

  /// Assign multiple faces to a person
  Future<void> assignFacesToPerson(List<String> faceIds, String personId) async {
    if (!_isInitialized) await init();

    // Track unique image paths for syncing
    final imagePaths = <String>{};

    for (final faceId in faceIds) {
      final face = _facesBox.get(faceId);
      if (face != null) {
        imagePaths.add(face.imagePath);
      }
      await updateFacePerson(faceId, personId);
    }

    // Update person face count
    final faceCount = _facesBox.values.where((f) => f.personId == personId).length;
    final person = _personsBox.get(personId);
    if (person != null) {
      await _personsBox.put(personId, person.copyWith(
        faceCount: faceCount,
        updatedAt: DateTime.now(),
      ));
    }

    // Sync updated faces to S3 (fire-and-forget for each unique image)
    for (final imagePath in imagePaths) {
      final facesForImage = _facesBox.values
          .where((f) => f.imagePath == imagePath)
          .toList();
      syncFaceMetadataToS3(imagePath, facesForImage);
    }
  }

  /// Remove a face from a person (set personId to null)
  Future<void> removeFaceFromPerson(String faceId) async {
    if (!_isInitialized) await init();

    final face = _facesBox.get(faceId);
    if (face == null) return;

    final oldPersonId = face.personId;
    final imagePath = face.imagePath; // Save for later sync

    // Set face to unnamed
    await updateFacePerson(faceId, null);

    // Update old person's face count
    if (oldPersonId != null) {
      final faceCount = _facesBox.values.where((f) => f.personId == oldPersonId).length;
      final person = _personsBox.get(oldPersonId);
      if (person != null) {
        if (faceCount == 0) {
          // Delete person if no faces left
          await _personsBox.delete(oldPersonId);
        } else {
          await _personsBox.put(oldPersonId, person.copyWith(
            faceCount: faceCount,
            updatedAt: DateTime.now(),
          ));
        }
      }
    }

    // Sync updated faces to S3
    final facesForImage = _facesBox.values
        .where((f) => f.imagePath == imagePath)
        .toList();
    syncFaceMetadataToS3(imagePath, facesForImage);
  }

  /// Create a new named person and assign faces to it
  Future<Person> createNamedPerson(String name, List<String> faceIds) async {
    if (!_isInitialized) await init();

    // Get first face for thumbnail and collect image paths for syncing
    DetectedFace? firstFace;
    final imagePaths = <String>{};

    if (faceIds.isNotEmpty) {
      firstFace = _facesBox.get(faceIds.first);
      // Collect all image paths for syncing
      for (final faceId in faceIds) {
        final face = _facesBox.get(faceId);
        if (face != null) {
          imagePaths.add(face.imagePath);
        }
      }
    }

    final person = Person(
      id: _uuid.v4(),
      name: name,
      averageEmbedding: firstFace?.embedding ?? [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      faceCount: faceIds.length,
      thumbnailPath: firstFace?.thumbnailPath,
    );

    await _personsBox.put(person.id, person);

    // Assign all faces to this person
    for (final faceId in faceIds) {
      await updateFacePerson(faceId, person.id);
    }

    // Sync updated faces to S3 (fire-and-forget for each unique image)
    for (final imagePath in imagePaths) {
      final facesForImage = _facesBox.values
          .where((f) => f.imagePath == imagePath)
          .toList();
      syncFaceMetadataToS3(imagePath, facesForImage);
    }

    return person;
  }

  /// Get first face thumbnail for a person
  Future<String?> getPersonThumbnail(String personId) async {
    if (!_isInitialized) await init();
    final faces = _facesBox.values.where((f) => f.personId == personId);
    if (faces.isEmpty) return null;
    // Return first face with a thumbnail, or null
    for (final face in faces) {
      if (face.thumbnailPath != null) return face.thumbnailPath;
    }
    return null;
  }

  /// Move a face to a different person
  Future<void> moveFaceToPerson(String faceId, String newPersonId) async {
    if (!_isInitialized) await init();
    
    final face = _facesBox.get(faceId);
    if (face == null) return;
    
    final oldPersonId = face.personId;
    
    // Update face's person
    await updateFacePerson(faceId, newPersonId);
    
    // Update face counts
    if (oldPersonId != null) {
      await _updatePersonFaceCount(oldPersonId);
    }
    await _updatePersonFaceCount(newPersonId);
  }

  /// Update person's face count
  Future<void> _updatePersonFaceCount(String personId) async {
    final person = _personsBox.get(personId);
    if (person == null) return;
    
    final faceCount = _facesBox.values.where((f) => f.personId == personId).length;
    
    if (faceCount == 0) {
      // Delete person if no faces left
      await _personsBox.delete(personId);
    } else {
      // Update face count and maybe thumbnail
      String? thumbnail = person.thumbnailPath;
      if (thumbnail == null || !File(thumbnail).existsSync()) {
        thumbnail = await getPersonThumbnail(personId);
      }
      
      await _personsBox.put(personId, person.copyWith(
        faceCount: faceCount,
        thumbnailPath: thumbnail,
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// Get all image paths containing a person
  Future<List<String>> getImagesForPerson(String personId) async {
    if (!_isInitialized) await init();
    return _facesBox.values
        .where((f) => f.personId == personId)
        .map((f) => f.imagePath)
        .toSet()
        .toList();
  }

  /// Get a face by ID
  Future<DetectedFace?> getFace(String faceId) async {
    if (!_isInitialized) await init();
    return _facesBox.get(faceId);
  }

  /// Update face's person assignment
  Future<void> updateFacePerson(String faceId, String? personId) async {
    if (!_isInitialized) await init();
    final face = _facesBox.get(faceId);
    if (face != null) {
      await _facesBox.put(faceId, face.copyWith(personId: personId));
    }
  }

  /// Delete a face
  Future<void> deleteFace(String faceId) async {
    if (!_isInitialized) await init();
    await _facesBox.delete(faceId);
  }

  /// Delete all faces for an image
  Future<void> deleteFacesForImage(String imagePath) async {
    if (!_isInitialized) await init();
    final facesToDelete = _facesBox.values
        .where((f) => f.imagePath == imagePath)
        .map((f) => f.id)
        .toList();
    for (final id in facesToDelete) {
      await _facesBox.delete(id);
    }
  }

  // ============================================================================
  // PERSON MANAGEMENT
  // ============================================================================

  /// Get all persons
  Future<List<Person>> getAllPersons() async {
    if (!_isInitialized) await init();
    return _personsBox.values.toList();
  }

  /// Get a person by ID
  Future<Person?> getPerson(String personId) async {
    if (!_isInitialized) await init();
    return _personsBox.get(personId);
  }

  /// Create a new person from a detected face (doesn't update face - use for new flow)
  Future<Person> createPersonForNewFace(DetectedFace face) async {
    if (!_isInitialized) await init();

    final person = Person(
      id: _uuid.v4(),
      name: 'Person ${_personsBox.length + 1}',
      averageEmbedding: face.embedding,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      faceCount: 1,
      thumbnailPath: face.thumbnailPath ?? face.imagePath,
    );

    await _personsBox.put(person.id, person);
    return person;
  }

  /// Increment face count for an existing person
  Future<void> incrementPersonFaceCount(String personId) async {
    if (!_isInitialized) await init();
    final person = _personsBox.get(personId);
    if (person != null) {
      await _personsBox.put(personId, person.copyWith(
        faceCount: person.faceCount + 1,
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// Create a new person from a detected face (legacy - updates face after)
  Future<Person> createPersonFromFace(DetectedFace face) async {
    if (!_isInitialized) await init();

    final person = Person(
      id: _uuid.v4(),
      name: 'Person ${_personsBox.length + 1}',
      averageEmbedding: face.embedding,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      faceCount: 1,
      thumbnailPath: face.thumbnailPath ?? face.imagePath,
    );

    await _personsBox.put(person.id, person);
    
    // Update face with person ID
    await updateFacePerson(face.id, person.id);

    return person;
  }

  /// Update person name
  Future<void> updatePersonName(String personId, String name) async {
    if (!_isInitialized) await init();
    final person = _personsBox.get(personId);
    if (person != null) {
      person.name = name;
      person.updatedAt = DateTime.now();
      await _personsBox.put(personId, person);
    }
  }

  /// Merge two persons (when user indicates they're the same)
  Future<void> mergePersons(String keepPersonId, String mergePersonId) async {
    if (!_isInitialized) await init();

    final keepPerson = _personsBox.get(keepPersonId);
    final mergePerson = _personsBox.get(mergePersonId);

    if (keepPerson == null || mergePerson == null) return;

    // Update all faces from merged person to point to kept person
    final facesToUpdate = _facesBox.values
        .where((f) => f.personId == mergePersonId)
        .toList();

    for (final face in facesToUpdate) {
      await _facesBox.put(face.id, face.copyWith(personId: keepPersonId));
    }

    // Update average embedding
    final allFaces = _facesBox.values
        .where((f) => f.personId == keepPersonId)
        .toList();
    
    if (allFaces.isNotEmpty) {
      final embeddings = allFaces.map((f) => f.embedding).toList();
      final newAverage = FaceEmbeddingService.instance.calculateAverageEmbedding(embeddings);
      
      await _personsBox.put(keepPersonId, keepPerson.copyWith(
        averageEmbedding: newAverage,
        faceCount: allFaces.length,
        updatedAt: DateTime.now(),
      ));
    }

    // Delete merged person
    await _personsBox.delete(mergePersonId);
  }

  /// Delete a person and unassign their faces
  Future<void> deletePerson(String personId) async {
    if (!_isInitialized) await init();

    // Unassign faces
    final faces = _facesBox.values
        .where((f) => f.personId == personId)
        .toList();

    for (final face in faces) {
      await _facesBox.put(face.id, face.copyWith(personId: null));
    }

    // Delete person
    await _personsBox.delete(personId);
  }

  /// Find matching person for an embedding
  Future<String?> findMatchingPerson(List<double> embedding) async {
    if (!_isInitialized) await init();

    final persons = _personsBox.values.toList();
    
    if (persons.isEmpty) return null;

    String? bestMatchId;
    double bestSimilarity = 0;

    for (final person in persons) {
      final similarity = FaceEmbeddingService.instance.calculateSimilarity(
        embedding,
        person.averageEmbedding,
      );

      if (similarity > bestSimilarity && 
          similarity >= FaceEmbeddingService.similarityThreshold) {
        bestSimilarity = similarity;
        bestMatchId = person.id;
      }
    }

    return bestMatchId;
  }

  /// Search persons by name (for autocomplete)
  Future<List<Person>> searchPersonsByName(String query) async {
    if (!_isInitialized) await init();
    
    if (query.isEmpty) return [];
    
    final lowerQuery = query.toLowerCase();
    return _personsBox.values
        .where((p) => p.name.toLowerCase().contains(lowerQuery))
        .toList();
  }

  // ============================================================================
  // PROCESSING STATE
  // ============================================================================

  /// Get processing state for an image
  Future<FaceProcessingState?> getProcessingState(String imagePath) async {
    if (!_isInitialized) await init();
    return _processingStateBox.get(imagePath);
  }

  /// Update processing state
  Future<void> updateProcessingState(
    String imagePath,
    FaceProcessingStatus status, {
    int? faceCount,
    String? errorMessage,
  }) async {
    if (!_isInitialized) await init();

    final existing = _processingStateBox.get(imagePath);
    final state = FaceProcessingState(
      imagePath: imagePath,
      status: status,
      processedAt: status == FaceProcessingStatus.completed || 
                   status == FaceProcessingStatus.noFaces
          ? DateTime.now()
          : existing?.processedAt,
      faceCount: faceCount ?? existing?.faceCount ?? 0,
      errorMessage: errorMessage,
    );

    await _processingStateBox.put(imagePath, state);
  }

  /// Get all pending images for processing
  Future<List<String>> getPendingImages() async {
    if (!_isInitialized) await init();
    return _processingStateBox.values
        .where((s) => s.status == FaceProcessingStatus.pending)
        .map((s) => s.imagePath)
        .toList();
  }

  // ============================================================================
  // S3 SYNC
  // ============================================================================

  /// Ensure the face metadata bucket exists
  Future<bool> _ensureBucketExists() async {
    if (_bucketChecked) return _bucketExists;
    
    try {
      // Try to create the bucket (will fail silently if exists)
      await FulaApiService.instance.createBucket(_faceMetadataBucket);
      _bucketExists = true;
    } catch (e) {
      // Check if bucket already exists by trying to list it
      try {
        await FulaApiService.instance.listObjects(_faceMetadataBucket);
        _bucketExists = true;
      } catch (_) {
        _bucketExists = false;
        debugPrint('Face metadata bucket not available - S3 sync disabled');
      }
    }
    
    _bucketChecked = true;
    return _bucketExists;
  }

  /// Sync face metadata to S3 (encrypted)
  /// This is optional - faces are stored locally regardless of S3 sync success
  Future<void> syncFaceMetadataToS3(String imagePath, List<DetectedFace> faces) async {
    if (!FulaApiService.instance.isConfigured) return;
    if (faces.isEmpty) return;
    
    // Check if bucket is available (only check once per session)
    if (!await _ensureBucketExists()) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      // Create metadata
      final metadata = ImageFaceMetadata(
        imageKey: imagePath,
        faces: faces.map((f) => FaceMetadataEntry(
          faceId: f.id,
          left: f.boundingBoxLeft,
          top: f.boundingBoxTop,
          width: f.boundingBoxWidth,
          height: f.boundingBoxHeight,
          embedding: f.embedding,
          personId: f.personId,
        )).toList(),
        processedAt: DateTime.now(),
      );

      // Convert to JSON and encrypt
      final jsonStr = jsonEncode(metadata.toJson());
      final data = Uint8List.fromList(utf8.encode(jsonStr));
      
      // Generate key from image path
      final metadataKey = _generateMetadataKey(imagePath);

      // Upload encrypted metadata
      await FulaApiService.instance.encryptAndUpload(
        _faceMetadataBucket,
        metadataKey,
        data,
        encryptionKey,
        originalFilename: 'face_metadata.json',
        contentType: 'application/json',
      );

      debugPrint('Face metadata synced to S3 for: $imagePath');
    } catch (e) {
      // Silently fail - S3 sync is optional, local storage is primary
      // Only log once to avoid spam
      if (_bucketExists) {
        debugPrint('Failed to sync face metadata to S3: $e');
        // Disable further attempts if bucket issue
        if (e.toString().contains('NoSuchBucket')) {
          _bucketExists = false;
        }
      }
    }
  }

  /// Load face metadata from S3
  Future<ImageFaceMetadata?> loadFaceMetadataFromS3(String imagePath) async {
    if (!FulaApiService.instance.isConfigured) return null;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return null;

      final metadataKey = _generateMetadataKey(imagePath);

      final data = await FulaApiService.instance.downloadAndDecrypt(
        _faceMetadataBucket,
        metadataKey,
        encryptionKey,
      );

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      return ImageFaceMetadata.fromJson(json);
    } catch (e) {
      debugPrint('Failed to load face metadata from S3: $e');
      return null;
    }
  }

  /// Restore faces from S3 metadata
  Future<void> restoreFacesFromS3(String imagePath) async {
    try {
      final metadata = await loadFaceMetadataFromS3(imagePath);
      if (metadata == null) return;

      for (final faceEntry in metadata.faces) {
        final face = DetectedFace(
          id: faceEntry.faceId,
          imagePath: imagePath,
          boundingBoxLeft: faceEntry.left,
          boundingBoxTop: faceEntry.top,
          boundingBoxWidth: faceEntry.width,
          boundingBoxHeight: faceEntry.height,
          embedding: faceEntry.embedding,
          personId: faceEntry.personId,
          detectedAt: metadata.processedAt,
        );

        await saveFace(face);
      }

      await updateProcessingState(
        imagePath,
        FaceProcessingStatus.completed,
        faceCount: metadata.faces.length,
      );

      debugPrint('Restored ${metadata.faces.length} faces from S3 for: $imagePath');
    } catch (e) {
      debugPrint('Failed to restore faces from S3: $e');
    }
  }

  String _generateMetadataKey(String imagePath) {
    // Create a unique key based on image path hash
    final hash = imagePath.hashCode.abs().toString();
    final fileName = imagePath.split('/').last.split('\\').last;
    return 'faces/$hash/$fileName.json';
  }

  // ============================================================================
  // STATISTICS
  // ============================================================================

  /// Get total number of detected faces
  Future<int> getTotalFaceCount() async {
    if (!_isInitialized) await init();
    return _facesBox.length;
  }

  /// Get total number of persons
  Future<int> getTotalPersonCount() async {
    if (!_isInitialized) await init();
    return _personsBox.length;
  }

  /// Get number of processed images
  Future<int> getProcessedImageCount() async {
    if (!_isInitialized) await init();
    return _processingStateBox.values
        .where((s) => s.status == FaceProcessingStatus.completed)
        .length;
  }

  // ============================================================================
  // CLEANUP
  // ============================================================================

  /// Clear all face data
  Future<void> clearAll() async {
    if (!_isInitialized) await init();
    await _facesBox.clear();
    await _personsBox.clear();
    await _processingStateBox.clear();
  }

  /// Clear processing states (to re-process images)
  Future<void> clearProcessingStates() async {
    if (!_isInitialized) await init();
    await _processingStateBox.clear();
  }
}
