import 'dart:async';

import 'package:dormos/domain/lan_link.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/ui/camera_qr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  test('camera accepts a Dorm address and rejects unrelated QR content', () {
    expect(
      readLanQrLink('http://192.168.1.12:8765/').toString(),
      'http://192.168.1.12:8765',
    );
    expect(readLanQrLink('http://10.0.0.3').port, 80);
    for (final text in [
      'DORM-INVITE:other',
      'https://example.org',
      'http://example.org',
      'http://192.168.1.12:70000',
      'http://192.168.1.12/api/ledger',
      'http://192.168.1.12?other',
      'http://user@192.168.1.12',
      'http://0.0.0.0:8765',
      'http://127.0.0.1:8765',
    ]) {
      expect(() => readLanQrLink(text), throwsA(isA<InputException>()));
    }
  });

  testWidgets('camera view ignores unrelated codes and returns a valid scan', (
    tester,
  ) async {
    final original = MobileScannerPlatform.instance;
    final camera = _TestCamera();
    MobileScannerPlatform.instance = camera;
    addTearDown(() async {
      MobileScannerPlatform.instance = original;
      await camera.captures.close();
    });
    Uri? scanned;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                scanned = await scanWithCamera(
                  context,
                  title: '扫描局域网二维码',
                  instruction: '扫描访问地址',
                  read: readLanQrLink,
                );
              },
              child: const Text('打开相机'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开相机'));
    await tester.pumpAndSettle();
    expect(camera.requested?.formats, [BarcodeFormat.qrCode]);
    expect(find.text('扫描局域网二维码'), findsOneWidget);

    camera.detect('DORM-INVITE:wrong-kind');
    await tester.pumpAndSettle();
    expect(find.text('请扫描 Dorm 局域网访问地址的二维码'), findsOneWidget);
    expect(scanned, isNull);

    camera.detect('http://192.168.1.12:8765');
    await tester.pumpAndSettle();
    expect(scanned, Uri.parse('http://192.168.1.12:8765'));
    expect(find.text('打开相机'), findsOneWidget);
    expect(camera.releases, 1);
    expect(tester.takeException(), isNull);
  });
}

class _TestCamera extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  StartOptions? requested;
  int releases = 0;

  void detect(String text) => captures.add(
    BarcodeCapture(
      barcodes: [Barcode(format: BarcodeFormat.qrCode, rawValue: text)],
    ),
  );

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;

  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    requested = startOptions;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    releases++;
  }
}
