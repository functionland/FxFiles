import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'package:crypto/crypto.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// Service that orchestrates the website generation pipeline:
/// upload assets (unencrypted) → parse content (ML Kit) → call AI → store result
class WebsiteService {
  WebsiteService._();
  static final WebsiteService instance = WebsiteService._();

  late Box<WebsiteGeneration> _generationsBox;
  bool _isInitialized = false;

  final _statusController = StreamController<WebsiteGeneration>.broadcast();
  Stream<WebsiteGeneration> get statusStream => _statusController.stream;

  static const _uuid = Uuid();
  static const String _assetBucket = 'website-assets';
  static const String _websiteMetadataBucket = 'website-metadata';
  static const int _maxFileSizeBytes = 50 * 1024 * 1024; // 50MB per file
  static const int _maxParsedContentBytes = 100000; // 100KB backend limit

  // Cloud sync state
  bool _metaBucketChecked = false;
  bool _metaBucketExists = false;
  DateTime? _lastSyncTime;
  bool _syncScheduled = false;
  static const Duration _syncDebounce = Duration(seconds: 5);

  // Default endpoints (used when nothing is configured in SecureStorage)
  static const String _defaultAiEndpoint = 'https://ai.cloud.fx.land';
  static const String _defaultIpfsGateway = 'https://ipfs.cloud.fx.land/gateway/';
  static const String _defaultApiGateway = 'https://s3.cloud.fx.land';

  /// System instructions auto-prepended to every user prompt.
  /// These ensure the backend produces compact, valid output.
  static const String _systemInstructions = '''
=== SYSTEM CONSTRAINTS (auto-added, do not repeat) ===
Output budget: Your TOTAL JSON response must be UNDER 40KB (~10,000 tokens). Plan accordingly — do NOT start generating a large site that will get cut off mid-output.

File strategy:
- Generate 1-3 files MAX (index.html, style.css, optionally script.js).
- For simple sites, inline CSS in a <style> tag to save file count and output size.
- Write clean but concise code. Avoid verbose comments or redundant CSS resets.

Hosting constraints (IPFS — static only):
- Use ONLY relative paths for internal refs (e.g. href="./style.css", src="./script.js").
- NO external CDN links, NO server-side code, NO forms with action URLs.
- All provided asset URLs are already hosted — use them exactly as-is (img src="https://...").

Design:
- Mobile-responsive layout with clean typography.
- Visually appealing with good use of whitespace and color.
- The user will provide a "Website Name" and "Category" at the start of their request. Use the website name as the site title/heading. Tailor the layout, color scheme, and content structure to fit the specified category.
=== END SYSTEM CONSTRAINTS ===

User request:
''';

  /// Initialize Hive box and register adapters
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      if (!Hive.isAdapterRegistered(25)) {
        Hive.registerAdapter(WebsiteGenerationAdapter());
      }
      if (!Hive.isAdapterRegistered(26)) {
        Hive.registerAdapter(WebsiteGenStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(27)) {
        Hive.registerAdapter(WebsiteAssetAdapter());
      }

      _generationsBox = await Hive.openBox<WebsiteGeneration>('website_generations');
      _isInitialized = true;
      debugPrint('WebsiteService initialized with ${_generationsBox.length} generations');
    } catch (e) {
      debugPrint('Failed to initialize WebsiteService: $e');
    }
  }

  // ============================================================================
  // GENERATION QUERIES
  // ============================================================================

  /// Get all generations for a specific website tag
  List<WebsiteGeneration> getGenerationsForTag(String tagId) {
    if (!_isInitialized) return [];
    return _generationsBox.values
        .where((g) => g.tagId == tagId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Get all generations
  List<WebsiteGeneration> getAllGenerations() {
    if (!_isInitialized) return [];
    return _generationsBox.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Delete all generations for a tag
  Future<void> deleteGenerationsForTag(String tagId) async {
    if (!_isInitialized) await init();
    final toRemove = _generationsBox.values
        .where((g) => g.tagId == tagId)
        .map((g) => g.id)
        .toList();
    for (final id in toRemove) {
      await _generationsBox.delete(id);
    }
  }

  // ============================================================================
  // GENERATION PIPELINE
  // ============================================================================

  /// Start the full website generation pipeline
  Future<WebsiteGeneration> startGeneration({
    required String tagId,
    required String tagName,
    required String prompt,
    required List<TaggedFile> files,
  }) async {
    if (!_isInitialized) await init();

    // Sanitize tagName for use as S3 key prefix
    final websiteName = tagName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

    // Build asset list
    final assets = files
        .where((f) => f.localPath != null)
        .map((f) => WebsiteAsset(
              localPath: f.localPath!,
              fileName: f.fileName,
              type: file_utils.classifyFileType(f.fileName),
            ))
        .toList();

    // Create generation record
    final generation = WebsiteGeneration(
      id: _uuid.v4(),
      tagId: tagId,
      tagName: tagName,
      prompt: prompt,
      status: WebsiteGenStatus.uploading,
      statusMessage: 'Starting upload...',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      totalAssets: assets.length,
      uploadedAssets: 0,
      assets: assets,
    );

    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    // Run pipeline asynchronously
    _runPipeline(generation, websiteName);

    return generation;
  }

  /// Run the full pipeline: upload → parse → generate
  Future<void> _runPipeline(WebsiteGeneration generation, String websiteName) async {
    try {
      // Phase 1: Upload assets
      await _uploadPhase(generation, websiteName);

      // Phase 2: Parse content
      await _parsePhase(generation);

      // Phase 3: Call AI endpoint
      await _generatePhase(generation);
    } catch (e) {
      generation.status = WebsiteGenStatus.error;
      generation.errorMessage = e.toString();
      generation.updatedAt = DateTime.now();
      await _generationsBox.put(generation.id, generation);
      _statusController.add(generation);
      debugPrint('Website generation failed: $e');
    }
  }

  /// Phase 1: Upload each asset unencrypted to S3
  Future<void> _uploadPhase(WebsiteGeneration generation, String websiteName) async {
    // M4: Create bucket once at the start of upload phase
    await _ensureBucket();

    int failedCount = 0;

    for (var i = 0; i < generation.assets.length; i++) {
      final asset = generation.assets[i];

      // M5: Check file size before reading into memory
      try {
        final fileSize = File(asset.localPath).lengthSync();
        if (fileSize > _maxFileSizeBytes) {
          debugPrint('Asset ${asset.fileName} too large (${fileSize ~/ (1024 * 1024)}MB), skipping');
          asset.uploaded = false;
          failedCount++;
          continue;
        }
      } catch (e) {
        debugPrint('Cannot stat asset ${asset.fileName}: $e');
        asset.uploaded = false;
        failedCount++;
        continue;
      }

      generation.statusMessage = 'Uploading asset ${i + 1}/${generation.totalAssets}...';
      generation.updatedAt = DateTime.now();
      await _generationsBox.put(generation.id, generation);
      _statusController.add(generation);

      try {
        final cid = await _uploadAssetUnencrypted(
          asset.localPath,
          asset.fileName,
          websiteName,
        );
        asset.cid = cid;
        asset.gatewayUrl = await _buildGatewayUrl(cid);
        asset.uploaded = true;
        generation.uploadedAssets = i + 1;
        await _generationsBox.put(generation.id, generation);
        _statusController.add(generation);
      } catch (e) {
        debugPrint('Failed to upload asset ${asset.fileName}: $e');
        asset.uploaded = false;
        failedCount++;
      }
    }

    // M2: Inform user about failed uploads
    if (failedCount > 0) {
      generation.statusMessage =
          '$failedCount of ${generation.totalAssets} assets failed to upload';
      generation.updatedAt = DateTime.now();
      await _generationsBox.put(generation.id, generation);
      _statusController.add(generation);
    }
  }

  /// Phase 2: Parse content from each asset using ML Kit
  Future<void> _parsePhase(WebsiteGeneration generation) async {
    generation.status = WebsiteGenStatus.parsing;
    generation.statusMessage = 'Parsing content...';
    generation.updatedAt = DateTime.now();
    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    for (final asset in generation.assets) {
      try {
        final content = await _parseContent(asset.localPath, asset.type);
        if (content != null && content.isNotEmpty) {
          // M6: Truncate to backend's 100KB limit per asset
          asset.parsedContent = content.length > _maxParsedContentBytes
              ? content.substring(0, _maxParsedContentBytes)
              : content;
        }
      } catch (e) {
        debugPrint('Failed to parse content for ${asset.fileName}: $e');
      }
    }

    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);
  }

  /// Phase 3: Call AI endpoint to generate the website
  Future<void> _generatePhase(WebsiteGeneration generation) async {
    generation.status = WebsiteGenStatus.generating;
    generation.statusMessage = 'Generating website...';
    generation.updatedAt = DateTime.now();
    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    // H4: Filter out assets where gatewayUrl is null or empty
    final uploadedAssets = generation.assets.where((a) => a.uploaded).toList();
    final validAssets = uploadedAssets
        .where((a) => a.gatewayUrl != null && a.gatewayUrl!.isNotEmpty)
        .toList();
    final droppedCount = uploadedAssets.length - validAssets.length;
    if (droppedCount > 0) {
      debugPrint('Warning: Dropped $droppedCount assets with empty gateway URLs');
    }

    final assetPayloads = validAssets.map((a) => a.toAiPayload()).toList();

    // M3: _callAiEndpoint sets resultCid and resultGatewayUrl on generation
    await _callAiEndpoint(generation.prompt, assetPayloads, generation);

    generation.status = WebsiteGenStatus.completed;
    generation.statusMessage = 'Website generated successfully';
    generation.updatedAt = DateTime.now();
    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    // Sync completed generation to cloud
    _scheduleSyncToCloud();
  }

  // ============================================================================
  // UPLOAD (direct HTTP, bypasses fula_client encryption)
  // ============================================================================

  /// Ensure the S3 bucket exists (called once per upload batch)
  Future<void> _ensureBucket() async {
    final apiGateway = await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl) ??
        _defaultApiGateway;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (jwt == null || jwt.isEmpty) return;

    try {
      await http.put(
        Uri.parse('$apiGateway/$_assetBucket'),
        headers: {'Authorization': 'Bearer $jwt'},
      );
    } catch (e) {
      debugPrint('Bucket creation note: $e');
    }
  }

  /// Upload a file unencrypted to S3 via direct HTTP PUT
  Future<String> _uploadAssetUnencrypted(
    String localPath,
    String fileName,
    String websiteName,
  ) async {
    final apiGateway = await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl) ??
        _defaultApiGateway;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured. Please set your API key in Settings.');
    }

    final key = '$websiteName/$fileName';
    final fileBytes = await File(localPath).readAsBytes();
    final contentType = lookupMimeType(localPath) ?? 'application/octet-stream';

    // Upload the file
    final response = await http.put(
      Uri.parse('$apiGateway/$_assetBucket/$key'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': contentType,
      },
      body: fileBytes,
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          'Upload failed (${response.statusCode}): ${response.body}');
    }

    // The etag header contains the IPFS CID
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw Exception('Upload succeeded but no CID returned in etag header');
    }

    // Clean etag (remove quotes if present)
    return etag.replaceAll('"', '');
  }

  // ============================================================================
  // CONTENT PARSING (ML Kit)
  // ============================================================================

  /// Parse content from a file based on its type
  Future<String?> _parseContent(String localPath, String type) async {
    switch (type) {
      case 'image':
        return _parseImage(localPath);
      case 'document':
        return _parseDocument(localPath);
      case 'video':
        return _parseVideo(localPath);
      case 'audio':
        return _parseAudio(localPath);
      default:
        return null;
    }
  }

  /// Parse image: use ImageLabeler for content description + TextRecognizer for any text
  Future<String?> _parseImage(String localPath) async {
    // ML Kit is only available on mobile platforms
    if (!PlatformCapabilities.isMobile) {
      return 'Image: ${p.basename(localPath)}';
    }

    final results = <String>[];

    try {
      final inputImage = InputImage.fromFilePath(localPath);

      // Image labeling
      final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
      try {
        final labels = await labeler.processImage(inputImage);
        if (labels.isNotEmpty) {
          results.add('Labels: ${_formatLabels(labels)}');
        }
      } finally {
        await labeler.close();
      }

      // Text recognition
      final textRecognizer = TextRecognizer();
      try {
        final recognizedText = await textRecognizer.processImage(inputImage);
        if (recognizedText.text.isNotEmpty) {
          // Limit text length
          final text = recognizedText.text.length > 500
              ? '${recognizedText.text.substring(0, 500)}...'
              : recognizedText.text;
          results.add('Text: $text');
        }
      } finally {
        await textRecognizer.close();
      }
    } catch (e) {
      debugPrint('Image parsing error for $localPath: $e');
    }

    return results.isEmpty ? null : results.join('\n');
  }

  /// Parse document: read text content directly
  Future<String?> _parseDocument(String localPath) async {
    try {
      final ext = p.extension(localPath).toLowerCase();

      // For text-based files, read directly
      if (['.txt', '.md', '.json', '.xml', '.yaml', '.yml', '.log', '.csv', '.html', '.css', '.js']
          .contains(ext)) {
        final content = await File(localPath).readAsString();
        // Limit content length
        return content.length > 2000
            ? '${content.substring(0, 2000)}...'
            : content;
      }

      // For PDF and image-based documents, try text recognition
      if (['.pdf'].contains(ext)) {
        return 'PDF document: ${p.basename(localPath)}';
      }

      // For other document types with embedded images (docx etc.), try text recognition on first page
      if (PlatformCapabilities.isMobile && ['.png', '.jpg', '.jpeg', '.bmp', '.webp'].contains(ext)) {
        final inputImage = InputImage.fromFilePath(localPath);
        final textRecognizer = TextRecognizer();
        try {
          final recognizedText = await textRecognizer.processImage(inputImage);
          if (recognizedText.text.isNotEmpty) {
            return recognizedText.text.length > 2000
                ? '${recognizedText.text.substring(0, 2000)}...'
                : recognizedText.text;
          }
        } finally {
          await textRecognizer.close();
        }
      }

      return 'Document: ${p.basename(localPath)}';
    } catch (e) {
      debugPrint('Document parsing error for $localPath: $e');
      return 'Document: ${p.basename(localPath)}';
    }
  }

  /// Parse video: extract a thumbnail frame and label it
  Future<String?> _parseVideo(String localPath) async {
    // ML Kit labeling is only available on mobile
    if (!PlatformCapabilities.isMobile) {
      return 'Video: ${p.basename(localPath)}';
    }

    try {
      // Extract thumbnail frame
      final thumbnailBytes = await VideoThumbnail.thumbnailData(
        video: localPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 512,
        maxHeight: 512,
        quality: 75,
      );

      if (thumbnailBytes == null) {
        return 'Video: ${p.basename(localPath)}';
      }

      // Save thumbnail to temp file for ML Kit
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, 'website_video_thumb_${DateTime.now().millisecondsSinceEpoch}.jpg'));
      await tempFile.writeAsBytes(thumbnailBytes);

      try {
        final inputImage = InputImage.fromFilePath(tempFile.path);
        final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
        try {
          final labels = await labeler.processImage(inputImage);
          if (labels.isNotEmpty) {
            return 'Video content: ${_formatLabels(labels)}';
          }
        } finally {
          await labeler.close();
        }
      } finally {
        // Clean up temp file
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      return 'Video: ${p.basename(localPath)}';
    } catch (e) {
      debugPrint('Video parsing error for $localPath: $e');
      return 'Video: ${p.basename(localPath)}';
    }
  }

  /// Parse audio: return metadata (filename, type)
  Future<String?> _parseAudio(String localPath) async {
    final fileName = p.basename(localPath);
    final ext = p.extension(localPath).toLowerCase().replaceAll('.', '');
    return 'Audio file: $fileName (format: $ext)';
  }

  // ============================================================================
  // AI ENDPOINT
  // ============================================================================

  /// Call the AI endpoint to generate a website (async polling model).
  /// Sets resultCid and resultGatewayUrl directly on [generation].
  Future<void> _callAiEndpoint(
    String prompt,
    List<Map<String, dynamic>> assets,
    WebsiteGeneration generation,
  ) async {
    final aiEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.aiEndpointUrl) ??
        _defaultAiEndpoint;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured');
    }

    // 1. POST /api/v1/generate → get jobId (202 Accepted)
    // H2: Add timeout to prevent indefinite hang
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$aiEndpoint/api/v1/generate'),
        headers: {
          'Authorization': 'Bearer $jwt',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
        'prompt': '$_systemInstructions$prompt',
        'assets': assets,
      }),
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    }

    // H1: Handle 402 with fallback for missing fields
    if (response.statusCode == 402) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final required = body['required'];
      final balance = body['balance'];
      if (required != null && balance != null) {
        throw Exception(
          'Insufficient credits: need $required FULA, have $balance FULA',
        );
      } else {
        throw Exception('Insufficient credits. Please top up your FULA balance.');
      }
    }
    if (response.statusCode == 429) {
      throw Exception('Rate limit exceeded. Please try again later.');
    }
    if (response.statusCode != 202) {
      throw Exception(
        'Generation request failed (${response.statusCode}): ${response.body}',
      );
    }

    final jobId =
        (jsonDecode(response.body) as Map<String, dynamic>)['jobId'] as String;

    // 2. Poll /api/v1/status/:jobId with exponential backoff (L1)
    Duration pollInterval = const Duration(seconds: 2);
    const maxPollInterval = Duration(seconds: 10);
    const timeout = Duration(minutes: 5);
    final deadline = DateTime.now().add(timeout);
    int consecutiveErrors = 0;

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);

      // L1: Exponential backoff — increase interval up to max
      if (pollInterval < maxPollInterval) {
        pollInterval = Duration(
          milliseconds: (pollInterval.inMilliseconds * 1.5)
              .toInt()
              .clamp(0, maxPollInterval.inMilliseconds),
        );
      }

      final statusResponse = await http.get(
        Uri.parse('$aiEndpoint/api/v1/status/$jobId'),
        headers: {'Authorization': 'Bearer $jwt'},
      );

      // H3: Handle poll errors — break on auth/not-found, count consecutive failures
      if (statusResponse.statusCode != 200) {
        consecutiveErrors++;
        if (statusResponse.statusCode == 401 ||
            statusResponse.statusCode == 403) {
          throw Exception('Authentication expired. Please log in again.');
        }
        if (statusResponse.statusCode == 404) {
          throw Exception('Generation job not found.');
        }
        if (consecutiveErrors >= 5) {
          throw Exception(
            'Status check failed after $consecutiveErrors consecutive errors',
          );
        }
        continue;
      }

      consecutiveErrors = 0;

      final status =
          jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final serverStatus = status['status'] as String?;
      final statusMsg = status['statusMessage'] as String?;

      // Relay server-side status to UI
      if (statusMsg != null) {
        generation.statusMessage = statusMsg;
        generation.updatedAt = DateTime.now();
        await _generationsBox.put(generation.id, generation);
        _statusController.add(generation);
      }

      if (serverStatus == 'completed') {
        // M3: Store CID and gateway URL separately
        generation.resultCid = status['resultCid'] as String?;
        generation.resultGatewayUrl = status['gatewayUrl'] as String?;
        return;
      }
      if (serverStatus == 'error') {
        throw Exception(
          (status['errorMessage'] as String?) ?? 'Generation failed',
        );
      }
      // Still pending/generating/publishing — continue polling
    }

    throw Exception('Generation timed out after 5 minutes');
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  /// Build an IPFS gateway URL from a CID
  Future<String> _buildGatewayUrl(String cid) async {
    final gateway = await SecureStorageService.instance
            .read(SecureStorageKeys.ipfsGatewayUrl) ??
        _defaultIpfsGateway;

    // Ensure gateway ends with /
    final base = gateway.endsWith('/') ? gateway : '$gateway/';
    return '$base$cid';
  }

  /// L4: Format ML Kit labels into a readable string
  String _formatLabels(List<ImageLabel> labels) {
    return labels
        .take(10)
        .map((l) => '${l.label} (${(l.confidence * 100).toInt()}%)')
        .join(', ');
  }

  // ============================================================================
  // CLOUD SYNC
  // ============================================================================

  void _scheduleSyncToCloud() {
    if (_syncScheduled) return;
    _syncScheduled = true;

    Future.delayed(_syncDebounce, () async {
      _syncScheduled = false;
      await syncToCloud();
    });
  }

  /// Ensure the website metadata bucket exists
  Future<bool> _ensureMetadataBucketExists() async {
    if (_metaBucketChecked && _metaBucketExists) return true;

    try {
      await FulaApiService.instance.createBucket(_websiteMetadataBucket);
      _metaBucketExists = true;
      _metaBucketChecked = true;
      return true;
    } catch (e) {
      final errorStr = e.toString();

      if (errorStr.contains('BucketAlreadyExists') ||
          errorStr.contains('BucketAlreadyOwnedByYou')) {
        _metaBucketExists = true;
        _metaBucketChecked = true;
        return true;
      }

      try {
        await FulaApiService.instance.listObjects(_websiteMetadataBucket);
        _metaBucketExists = true;
        _metaBucketChecked = true;
        return true;
      } catch (listError) {
        final listErrorStr = listError.toString();
        if (listErrorStr.contains('AccountProblem') ||
            listErrorStr.contains('AccessDenied') ||
            listErrorStr.contains('QuotaExceeded')) {
          _metaBucketExists = false;
          _metaBucketChecked = true;
          return false;
        }

        _metaBucketExists = false;
        _metaBucketChecked = false;
        return false;
      }
    }
  }

  /// Get user ID for cloud storage key
  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;

      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      debugPrint('WebsiteService: Failed to get user ID: $e');
      return null;
    }
  }

  /// Sync all completed generations to cloud
  Future<void> syncToCloud() async {
    if (_metaBucketChecked && !_metaBucketExists) return;
    if (!FulaApiService.instance.isConfigured) return;

    final now = DateTime.now();
    if (_lastSyncTime != null &&
        now.difference(_lastSyncTime!) < const Duration(seconds: 2)) {
      return;
    }
    _lastSyncTime = now;

    if (!await _ensureMetadataBucketExists()) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      // Only sync completed generations
      final completed = _generationsBox.values
          .where((g) => g.status == WebsiteGenStatus.completed)
          .map((g) => g.toJson())
          .toList();

      final jsonStr = jsonEncode({'generations': completed, 'updatedAt': DateTime.now().toIso8601String()});
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      final key = '.fula/websites/$userId.json';
      await FulaApiService.instance.encryptAndUpload(
        _websiteMetadataBucket,
        key,
        data,
        encryptionKey,
        contentType: 'application/json',
      );

      debugPrint('Website generations synced to cloud: ${completed.length} generations');
    } catch (e) {
      debugPrint('WebsiteService: syncToCloud error: $e');
      final errorStr = e.toString();

      if (errorStr.contains('NoSuchBucket') || errorStr.contains('bucket not found')) {
        _metaBucketChecked = false;
        _metaBucketExists = false;
        return;
      }

      if (errorStr.contains('AccountProblem') ||
          errorStr.contains('QuotaExceeded') ||
          errorStr.contains('AccessDenied')) {
        _metaBucketExists = false;
        _metaBucketChecked = true;
      }
    }
  }

  /// Restore generations from cloud after reinstall
  Future<void> restoreFromCloud() async {
    if (!_isInitialized) await init();
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final key = '.fula/websites/$userId.json';
      final data = await FulaApiService.instance.downloadAndDecrypt(
        _websiteMetadataBucket,
        key,
        encryptionKey,
      );

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final generationsList = json['generations'] as List<dynamic>? ?? [];

      if (_generationsBox.isEmpty || generationsList.isNotEmpty) {
        // Preserve any in-progress local generations
        final localInProgress = _generationsBox.values
            .where((g) => g.status != WebsiteGenStatus.completed)
            .toList();

        await _generationsBox.clear();

        // Restore completed generations from cloud
        for (final genJson in generationsList) {
          final gen = WebsiteGeneration.fromJson(genJson as Map<String, dynamic>);
          await _generationsBox.put(gen.id, gen);
        }

        // Re-add local in-progress generations
        for (final gen in localInProgress) {
          await _generationsBox.put(gen.id, gen);
        }

        debugPrint('Restored ${generationsList.length} website generations from cloud');
      }
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('NoSuchKey') || errorStr.contains('Object not found') || errorStr.contains('404')) {
        debugPrint('Website restore: no cloud data found (new user or never synced)');
      } else {
        debugPrint('Failed to restore website generations from cloud: $e');
      }
    }
  }

  /// Dispose resources
  void dispose() {
    _statusController.close();
  }
}
