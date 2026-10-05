import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:just_post/features/create/asset_service.dart';

void main() {
  group('supportedExtension', () {
    test('accepts the formats storage.rules allows, in any case', () {
      expect(AssetService.supportedExtension(XFile('/tmp/IMG_1.HEIC')), 'heic');
      expect(AssetService.supportedExtension(XFile('/tmp/a.jpeg')), 'jpeg');
      expect(AssetService.supportedExtension(XFile('/tmp/a.png')), 'png');
      expect(AssetService.supportedExtension(XFile('/tmp/a.webp')), 'webp');
    });

    test('rejects other formats and files without an extension', () {
      expect(AssetService.supportedExtension(XFile('/tmp/a.gif')), isNull);
      expect(AssetService.supportedExtension(XFile('/tmp/noext')), isNull);
    });
  });

  test('ReferenceAsset reads the ingest_asset response', () {
    final asset = ReferenceAsset.fromMap({
      'assetId': 'abcdefghij0123456789',
      'originalPath': 'uploads/u/abcdefghij0123456789/original.heic',
      'workingPath': 'uploads/u/abcdefghij0123456789/working.png',
      'analysisPath': 'uploads/u/abcdefghij0123456789/analysis.webp',
      'fileSize': 2481033,
      'status': 'ready',
      'width': 1179,
      'height': 2556,
      'orientation': 'portrait',
      'sourceFormat': 'HEIF',
      'mimeType': 'image/heif',
      'sourceWidth': 2556,
      'sourceHeight': 1179,
      'exifOrientation': 6,
      'hasAlpha': false,
      'colorProfile': null,
    });

    expect(asset.width, 1179);
    expect(asset.height, 2556);
    expect(asset.exifOrientation, 6);
    expect(asset.colorProfile, isNull);
    expect(asset.mimeType, 'image/heif');
  });
}
