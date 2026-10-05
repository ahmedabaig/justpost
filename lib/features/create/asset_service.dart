import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// A reference slide after the backend has stored and normalized it.
@immutable
class ReferenceAsset {
  const ReferenceAsset({
    required this.assetId,
    required this.originalPath,
    required this.workingPath,
    required this.analysisPath,
    required this.width,
    required this.height,
    required this.orientation,
    required this.sourceFormat,
    required this.mimeType,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.fileSize,
    required this.exifOrientation,
    required this.hasAlpha,
    required this.colorProfile,
  });

  factory ReferenceAsset.fromMap(Map<String, dynamic> map) {
    return ReferenceAsset(
      assetId: map['assetId'] as String,
      originalPath: map['originalPath'] as String,
      workingPath: map['workingPath'] as String,
      analysisPath: map['analysisPath'] as String,
      width: (map['width'] as num).toInt(),
      height: (map['height'] as num).toInt(),
      orientation: map['orientation'] as String,
      sourceFormat: map['sourceFormat'] as String,
      mimeType: map['mimeType'] as String?,
      sourceWidth: (map['sourceWidth'] as num).toInt(),
      sourceHeight: (map['sourceHeight'] as num).toInt(),
      fileSize: (map['fileSize'] as num).toInt(),
      exifOrientation: (map['exifOrientation'] as num?)?.toInt(),
      hasAlpha: map['hasAlpha'] as bool,
      colorProfile: map['colorProfile'] as String?,
    );
  }

  final String assetId;
  final String originalPath;
  final String workingPath;
  final String analysisPath;

  /// Upright dimensions of the working copy, after the EXIF rotation fix.
  final int width;
  final int height;
  final String orientation;
  final String sourceFormat;
  final String? mimeType;
  final int sourceWidth;
  final int sourceHeight;
  final int fileSize;
  final int? exifOrientation;
  final bool hasAlpha;
  final String? colorProfile;
}

/// A failure the user can act on, with a message safe to show on screen.
class AssetIngestException implements Exception {
  const AssetIngestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Uploads one reference slide unchanged and asks the backend to ingest it.
class AssetService {
  static const int maxUploadBytes = 20 * 1024 * 1024;

  /// Must match the `original.*` names allowed by `storage.rules`.
  static const Map<String, String> contentTypes = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
  };

  // Resolved on use so widgets can create the service before Firebase starts
  // (for example in widget tests).
  FirebaseStorage get _storage => FirebaseStorage.instance;

  /// Returns the lowercase extension if [file] is a supported upload type.
  static String? supportedExtension(XFile file) {
    final name = file.name.isNotEmpty ? file.name : file.path;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    return contentTypes.containsKey(ext) ? ext : null;
  }

  Future<ReferenceAsset> ingestReference(XFile file) async {
    final ext = supportedExtension(file);
    if (ext == null) {
      throw const AssetIngestException(
        'Use a JPEG, PNG, WebP or HEIC image as the reference.',
      );
    }
    if (await file.length() > maxUploadBytes) {
      throw const AssetIngestException('The image is larger than 20 MB.');
    }

    try {
      final uid = await _signIn();
      final assetId = FirebaseFirestore.instance.collection('assets').doc().id;

      await _storage
          .ref('uploads/$uid/$assetId/original.$ext')
          .putFile(
            File(file.path),
            SettableMetadata(contentType: contentTypes[ext]),
          );

      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(
            'ingest_asset',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 90)),
          );
      final result = await callable.call<Map<String, dynamic>>({
        'assetId': assetId,
      });
      return ReferenceAsset.fromMap(Map<String, dynamic>.from(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: ingest_asset failed — ${error.code}');
      throw AssetIngestException(_functionsMessage(error));
    } on FirebaseException catch (error) {
      debugPrint('JustPost: upload failed — ${error.plugin}/${error.code}');
      throw const AssetIngestException(
        'We could not upload this slide. Check your connection and try again.',
      );
    }
  }

  Future<String> downloadUrl(String path) =>
      _storage.ref(path).getDownloadURL();

  Future<String> _signIn() async {
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user;
    if (user == null) {
      throw const AssetIngestException('Could not sign in. Please try again.');
    }
    return user.uid;
  }

  static String _functionsMessage(FirebaseFunctionsException error) {
    return switch (error.code) {
      // These come from the backend's checks and are written for users.
      'invalid-argument' => error.message ?? 'This image cannot be used.',
      'deadline-exceeded' => 'Processing took too long. Please try again.',
      'unavailable' => 'The server is unavailable. Please try again.',
      _ => 'Processing failed. Please try again.',
    };
  }
}
