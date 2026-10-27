import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Longest side a photo is sent at. A phone screen shows nothing past this,
/// and it keeps a camera photo comfortably inside the chunked
/// store-and-forward cap (PhantomCore.chunkedMediaMax).
const int sendImageMaxSide = 2048;

/// Normalizes a photo for sending: bakes in the EXIF orientation, scales the
/// longest side down to [maxSide] (never up) and re-encodes as JPEG.
///
/// Why it exists (field, 2026-10-26): the photo editor re-encoded every
/// picture — edited or not — as a full-resolution PNG. A 3000×2250 photo
/// became 9 MB, overflowed the 4 MB store-and-forward cap and fell back to an
/// IPFS pointer, which only resolves while the sender's node is reachable;
/// the receiver got "scaled_37200.jpg · 9.0 MB" and a download button. Every
/// real camera photo would have done the same.
///
/// Pure and synchronous so it can run under `compute`. Bytes that don't
/// decode as an image are returned unchanged.
Uint8List prepareImageForSend(Uint8List bytes,
    {int maxSide = sendImageMaxSide, int quality = 82}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  var im = img.bakeOrientation(decoded);
  final longest = im.width > im.height ? im.width : im.height;
  if (longest > maxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(im, height: maxSide, interpolation: img.Interpolation.average);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: quality));
}

/// [name] with its extension switched to `.jpg`, for the file name that
/// travels with the re-encoded bytes.
String jpgName(String name) {
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name}.jpg';
}
