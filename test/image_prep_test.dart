import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:phantom_messenger/core/image_prep.dart';
import 'package:phantom_messenger/core/phantom_core.dart';

/// Campo, 2026-10-26: una foto de 3000×2250 salió del editor como PNG de
/// 9 MB (re-codificaba SIEMPRE a PNG a resolución completa, editada o no),
/// pasó el tope de 4 MB del store-and-forward por fragmentos y cayó al
/// puntero IPFS — el receptor vio "scaled_37200.jpg 9.0 MB" con un botón de
/// descarga que depende de que el emisor siga en línea.
void main() {
  // Ruido: comprime tan mal como una foto real, el peor caso para PNG.
  img.Image noisy(int w, int h) {
    final im = img.Image(width: w, height: h);
    var seed = 7;
    for (final p in im) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      p
        ..r = seed & 0xff
        ..g = (seed >> 8) & 0xff
        ..b = (seed >> 16) & 0xff;
    }
    return im;
  }

  test('una foto grande en PNG sale como JPEG ≤ 2048 px, apta para S&F', () {
    final png = Uint8List.fromList(img.encodePng(noisy(3000, 2250)));
    expect(png.length, greaterThan(PhantomCore.chunkedMediaMax),
        reason: 'el caso de campo: el PNG solo no cabe en el S&F');

    final out = prepareImageForSend(png);
    expect(out.length, lessThan(PhantomCore.chunkedMediaMax));
    final decoded = img.decodeJpg(out);
    expect(decoded, isNotNull, reason: 'debe salir un JPEG válido');
    expect(decoded!.width, 2048);
    expect(decoded.height, 1536, reason: 'conserva la proporción');
  });

  test('una imagen chica no se agranda', () {
    final small = Uint8List.fromList(img.encodePng(noisy(640, 480)));
    final out = prepareImageForSend(small);
    final decoded = img.decodeJpg(out)!;
    expect((decoded.width, decoded.height), (640, 480));
  });

  test('bytes que no son imagen pasan sin tocar', () {
    final junk = Uint8List.fromList(List.generate(100, (i) => i));
    expect(prepareImageForSend(junk), junk);
  });
}
