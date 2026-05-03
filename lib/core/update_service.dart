import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_file_plus/open_file_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
  });
}

class UpdateService {
  static const String _apiUrl =
      'https://api.github.com/repos/AshnageNarnesfugen/phantom/releases/latest';

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await http.get(Uri.parse(_apiUrl));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String).replaceFirst(RegExp(r'^v'), '');
      final releaseNotes = (data['body'] as String?) ?? '';

      if (!_isNewer(tag, currentVersion)) return null;

      final assets = data['assets'] as List<dynamic>;
      final apkAsset = assets.cast<Map<String, dynamic>>().firstWhere(
        (a) => (a['name'] as String).endsWith('.apk'),
        orElse: () => {},
      );

      if (apkAsset.isEmpty) return null;

      return UpdateInfo(
        version: tag,
        downloadUrl: apkAsset['browser_download_url'] as String,
        releaseNotes: releaseNotes,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> downloadAndInstall(
    String url,
    void Function(double progress) onProgress,
  ) async {
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      final total = response.contentLength ?? 0;
      var received = 0;

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/phantom_update.apk');
      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress(received / total);
        }
      }

      await sink.flush();
      await sink.close();
      client.close();

      await OpenFile.open(file.path);
    } catch (_) {}
  }

  static bool _isNewer(String latest, String current) {
    final latestParts = latest.split('.').map(int.tryParse).toList();
    final currentParts = current.split('.').map(int.tryParse).toList();

    final length = latestParts.length > currentParts.length
        ? latestParts.length
        : currentParts.length;

    for (var i = 0; i < length; i++) {
      final l = i < latestParts.length ? (latestParts[i] ?? 0) : 0;
      final c = i < currentParts.length ? (currentParts[i] ?? 0) : 0;
      if (l > c) return true;
      if (l < c) return false;
    }

    return false;
  }
}
