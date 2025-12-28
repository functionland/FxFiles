import 'package:hive_flutter/hive_flutter.dart';

part 'face_data.g.dart';

/// Represents a detected face in an image
@HiveType(typeId: 10)
class DetectedFace extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String imagePath;

  @HiveField(2)
  final double boundingBoxLeft;

  @HiveField(3)
  final double boundingBoxTop;

  @HiveField(4)
  final double boundingBoxWidth;

  @HiveField(5)
  final double boundingBoxHeight;

  @HiveField(6)
  final List<double> embedding;

  @HiveField(7)
  final String? personId;

  @HiveField(8)
  final DateTime detectedAt;

  @HiveField(9)
  final double? confidence;

  @HiveField(10)
  final String? thumbnailPath;

  DetectedFace({
    required this.id,
    required this.imagePath,
    required this.boundingBoxLeft,
    required this.boundingBoxTop,
    required this.boundingBoxWidth,
    required this.boundingBoxHeight,
    required this.embedding,
    this.personId,
    required this.detectedAt,
    this.confidence,
    this.thumbnailPath,
  });

  DetectedFace copyWith({
    String? id,
    String? imagePath,
    double? boundingBoxLeft,
    double? boundingBoxTop,
    double? boundingBoxWidth,
    double? boundingBoxHeight,
    List<double>? embedding,
    String? personId,
    DateTime? detectedAt,
    double? confidence,
    String? thumbnailPath,
  }) {
    return DetectedFace(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      boundingBoxLeft: boundingBoxLeft ?? this.boundingBoxLeft,
      boundingBoxTop: boundingBoxTop ?? this.boundingBoxTop,
      boundingBoxWidth: boundingBoxWidth ?? this.boundingBoxWidth,
      boundingBoxHeight: boundingBoxHeight ?? this.boundingBoxHeight,
      embedding: embedding ?? this.embedding,
      personId: personId ?? this.personId,
      detectedAt: detectedAt ?? this.detectedAt,
      confidence: confidence ?? this.confidence,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'imagePath': imagePath,
      'boundingBox': {
        'left': boundingBoxLeft,
        'top': boundingBoxTop,
        'width': boundingBoxWidth,
        'height': boundingBoxHeight,
      },
      'embedding': embedding,
      'personId': personId,
      'detectedAt': detectedAt.toIso8601String(),
      'confidence': confidence,
      'thumbnailPath': thumbnailPath,
    };
  }

  factory DetectedFace.fromJson(Map<String, dynamic> json) {
    final bbox = json['boundingBox'] as Map<String, dynamic>;
    return DetectedFace(
      id: json['id'] as String,
      imagePath: json['imagePath'] as String,
      boundingBoxLeft: (bbox['left'] as num).toDouble(),
      boundingBoxTop: (bbox['top'] as num).toDouble(),
      boundingBoxWidth: (bbox['width'] as num).toDouble(),
      boundingBoxHeight: (bbox['height'] as num).toDouble(),
      embedding: (json['embedding'] as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
      personId: json['personId'] as String?,
      detectedAt: DateTime.parse(json['detectedAt'] as String),
      confidence: (json['confidence'] as num?)?.toDouble(),
      thumbnailPath: json['thumbnailPath'] as String?,
    );
  }
}

/// Represents a person (collection of faces)
@HiveType(typeId: 11)
class Person extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  final List<double> averageEmbedding;

  @HiveField(3)
  final DateTime createdAt;

  @HiveField(4)
  DateTime updatedAt;

  @HiveField(5)
  final int faceCount;

  @HiveField(6)
  final String? thumbnailPath;

  Person({
    required this.id,
    required this.name,
    required this.averageEmbedding,
    required this.createdAt,
    required this.updatedAt,
    this.faceCount = 1,
    this.thumbnailPath,
  });

  Person copyWith({
    String? id,
    String? name,
    List<double>? averageEmbedding,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? faceCount,
    String? thumbnailPath,
  }) {
    return Person(
      id: id ?? this.id,
      name: name ?? this.name,
      averageEmbedding: averageEmbedding ?? this.averageEmbedding,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      faceCount: faceCount ?? this.faceCount,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'averageEmbedding': averageEmbedding,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'faceCount': faceCount,
      'thumbnailPath': thumbnailPath,
    };
  }

  factory Person.fromJson(Map<String, dynamic> json) {
    return Person(
      id: json['id'] as String,
      name: json['name'] as String,
      averageEmbedding: (json['averageEmbedding'] as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      faceCount: json['faceCount'] as int? ?? 1,
      thumbnailPath: json['thumbnailPath'] as String?,
    );
  }
}

/// Metadata for face data stored with images in S3
class ImageFaceMetadata {
  final String imageKey;
  final List<FaceMetadataEntry> faces;
  final DateTime processedAt;
  final String version;

  ImageFaceMetadata({
    required this.imageKey,
    required this.faces,
    required this.processedAt,
    this.version = '1.0',
  });

  Map<String, dynamic> toJson() {
    return {
      'imageKey': imageKey,
      'faces': faces.map((f) => f.toJson()).toList(),
      'processedAt': processedAt.toIso8601String(),
      'version': version,
    };
  }

  factory ImageFaceMetadata.fromJson(Map<String, dynamic> json) {
    return ImageFaceMetadata(
      imageKey: json['imageKey'] as String,
      faces: (json['faces'] as List<dynamic>)
          .map((f) => FaceMetadataEntry.fromJson(f as Map<String, dynamic>))
          .toList(),
      processedAt: DateTime.parse(json['processedAt'] as String),
      version: json['version'] as String? ?? '1.0',
    );
  }
}

/// Individual face entry in image metadata
class FaceMetadataEntry {
  final String faceId;
  final double left;
  final double top;
  final double width;
  final double height;
  final List<double> embedding;
  final String? personId;

  FaceMetadataEntry({
    required this.faceId,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.embedding,
    this.personId,
  });

  Map<String, dynamic> toJson() {
    return {
      'faceId': faceId,
      'bbox': {'left': left, 'top': top, 'width': width, 'height': height},
      'embedding': embedding,
      'personId': personId,
    };
  }

  factory FaceMetadataEntry.fromJson(Map<String, dynamic> json) {
    final bbox = json['bbox'] as Map<String, dynamic>;
    return FaceMetadataEntry(
      faceId: json['faceId'] as String,
      left: (bbox['left'] as num).toDouble(),
      top: (bbox['top'] as num).toDouble(),
      width: (bbox['width'] as num).toDouble(),
      height: (bbox['height'] as num).toDouble(),
      embedding: (json['embedding'] as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
      personId: json['personId'] as String?,
    );
  }
}

/// Processing status for an image
@HiveType(typeId: 12)
class FaceProcessingState extends HiveObject {
  @HiveField(0)
  final String imagePath;

  @HiveField(1)
  final FaceProcessingStatus status;

  @HiveField(2)
  final DateTime? processedAt;

  @HiveField(3)
  final int faceCount;

  @HiveField(4)
  final String? errorMessage;

  FaceProcessingState({
    required this.imagePath,
    required this.status,
    this.processedAt,
    this.faceCount = 0,
    this.errorMessage,
  });

  FaceProcessingState copyWith({
    String? imagePath,
    FaceProcessingStatus? status,
    DateTime? processedAt,
    int? faceCount,
    String? errorMessage,
  }) {
    return FaceProcessingState(
      imagePath: imagePath ?? this.imagePath,
      status: status ?? this.status,
      processedAt: processedAt ?? this.processedAt,
      faceCount: faceCount ?? this.faceCount,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

@HiveType(typeId: 13)
enum FaceProcessingStatus {
  @HiveField(0)
  pending,

  @HiveField(1)
  processing,

  @HiveField(2)
  completed,

  @HiveField(3)
  failed,

  @HiveField(4)
  noFaces,
}
