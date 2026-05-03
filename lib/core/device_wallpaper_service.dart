import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class DeviceWallpaperService {
  static const _channel = MethodChannel('phantom/system');
  static String? _cachedPath;

  static Future<String?> getWallpaperPath() async {
    if (_cachedPath != null && await File(_cachedPath!).exists()) {
      return _cachedPath;
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('getDeviceWallpaper');
      if (bytes == null) return null;
      final dir  = await getTemporaryDirectory();
      final path = '${dir.path}/ph_device_wallpaper.jpg';
      await File(path).writeAsBytes(bytes);
      _cachedPath = path;
      return path;
    } catch (_) {
      return null;
    }
  }

  static void clearCache() => _cachedPath = null;
}
