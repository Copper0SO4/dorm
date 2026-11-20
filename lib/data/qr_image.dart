import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:zxing2/qrcode.dart' as qr;

import '../domain/ledger.dart';

Future<Uint8List> makeQrPng(String text) async {
  final matrix = qr.Encoder.encode(text, qr.ErrorCorrectionLevel.m).matrix!;
  const padding = 4;
  const scale = 7;
  final size = (matrix.width + padding * 2) * scale;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final ink = ui.Paint()
    ..color = const ui.Color(0xff000000)
    ..isAntiAlias = false;
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) == 1) {
        canvas.drawRect(
          ui.Rect.fromLTWH(
            ((x + padding) * scale).toDouble(),
            ((y + padding) * scale).toDouble(),
            scale.toDouble(),
            scale.toDouble(),
          ),
          ink,
        );
      }
    }
  }
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size, size);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw const InputException('无法生成二维码图片');
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Future<String> readQrImageText(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) {
      const maxSide = 1800;
      if (max(width, height) <= maxSide) return const ui.TargetImageSize();
      return width >= height
          ? const ui.TargetImageSize(width: maxSide)
          : const ui.TargetImageSize(height: maxSide);
    },
  );
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final rgba = await image.toByteData();
      if (rgba == null) throw const InputException('无法读取图片');
      final pixels = Int32List(image.width * image.height);
      for (var index = 0; index < pixels.length; index++) {
        final offset = index * 4;
        pixels[index] =
            rgba.getUint8(offset) << 16 |
            rgba.getUint8(offset + 1) << 8 |
            rgba.getUint8(offset + 2);
      }
      final luminance = qr.RGBLuminanceSource(
        image.width,
        image.height,
        pixels,
      );
      final bitmap = qr.BinaryBitmap(qr.HybridBinarizer(luminance));
      try {
        return qr.QRCodeReader().decode(bitmap).text;
      } on qr.ReaderException {
        throw const InputException('找不到可读二维码，请选择清晰的截图');
      }
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
