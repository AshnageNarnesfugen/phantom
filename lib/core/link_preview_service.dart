import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Sender-side link preview generation (Signal-style).
///
/// Privacy model: only the SENDER contacts the site (and only when the opt-in
/// setting is enabled and they typed a URL — the site already sees them the
/// moment they visit it). The preview travels INSIDE the encrypted message, so
/// the receiver renders a card without any network fetch — receiving a message
/// never leaks the receiver's IP to the linked site.
///
/// The wire content of a [MessageType.linkPreview] message is UTF-8 JSON:
///   {v:1, text, url, title, desc?, img?}   (img = base64 JPEG/PNG, ≤40 KB)
class LinkPreviewService {
  LinkPreviewService._();

  static final _urlRe = RegExp(r'https?://[^\s]+');

  /// First http(s) URL in [text], or null.
  static String? firstUrl(String text) => _urlRe.firstMatch(text)?.group(0);

  /// Everything is capped so a hostile page can't balloon the message:
  /// HTML read cut at 128 KB, image accepted only if ≤40 KB (fits comfortably
  /// inside the 64 KB inline envelope with the text and padding).
  static const _htmlCap = 128 * 1024;
  static const _imgCap = 40 * 1024;
  static const _timeout = Duration(seconds: 6);

  /// Builds the linkPreview JSON content for [text], or null when there is no
  /// URL / the fetch fails / nothing useful was found. Never throws.
  static Future<Uint8List?> buildContent(String text) async {
    final url = firstUrl(text);
    if (url == null) return null;
    try {
      final resp = await http
          .get(Uri.parse(url), headers: {'accept': 'text/html'})
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final body = resp.body.length > _htmlCap
          ? resp.body.substring(0, _htmlCap)
          : resp.body;

      final title = _meta(body, 'og:title') ?? _titleTag(body);
      final desc = _meta(body, 'og:description') ?? _meta(body, 'description');
      if (title == null && desc == null) return null;

      String? imgB64;
      final imgUrl = _meta(body, 'og:image');
      if (imgUrl != null) {
        try {
          final abs = Uri.parse(url).resolve(imgUrl).toString();
          final img = await http.get(Uri.parse(abs)).timeout(_timeout);
          if (img.statusCode == 200 && img.bodyBytes.length <= _imgCap) {
            imgB64 = base64Encode(img.bodyBytes);
          }
        } catch (_) {/* image is optional */}
      }

      return Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'text': text,
        'url': url,
        if (title != null) 'title': title,
        if (desc != null) 'desc': desc,
        if (imgB64 != null) 'img': imgB64,
      })));
    } catch (_) {
      return null;
    }
  }

  /// Parsed view of a linkPreview content blob (receiver side). Null when the
  /// JSON is malformed — callers fall back to rendering it as plain text.
  static ({String text, String url, String? title, String? desc, Uint8List? img})?
      parse(Uint8List content) {
    try {
      final j = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
      return (
        text: j['text'] as String,
        url: j['url'] as String,
        title: j['title'] as String?,
        desc: j['desc'] as String?,
        img: j['img'] != null ? base64Decode(j['img'] as String) : null,
      );
    } catch (_) {
      return null;
    }
  }

  // <meta property="og:title" content="..."> — property/name in either order,
  // single or double quotes. Regex over capped HTML; good enough for cards.
  static String? _meta(String html, String key) {
    for (final attr in ['property', 'name']) {
      final re = RegExp(
          '<meta[^>]+$attr\\s*=\\s*["\']$key["\'][^>]*content\\s*=\\s*["\']([^"\']+)["\']',
          caseSensitive: false);
      final re2 = RegExp(
          '<meta[^>]+content\\s*=\\s*["\']([^"\']+)["\'][^>]*$attr\\s*=\\s*["\']$key["\']',
          caseSensitive: false);
      final m = re.firstMatch(html) ?? re2.firstMatch(html);
      if (m != null) return _unescape(m.group(1)!);
    }
    return null;
  }

  static String? _titleTag(String html) {
    final m = RegExp('<title[^>]*>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html);
    return m != null ? _unescape(m.group(1)!.trim()) : null;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}
