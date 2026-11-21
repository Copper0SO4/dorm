import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/ledger.dart';

Future<T?> scanWithCamera<T>(
  BuildContext context, {
  required String title,
  required String instruction,
  required T Function(String) read,
}) => Navigator.of(context).push<T>(
  MaterialPageRoute(
    builder: (_) =>
        _QrCameraPage<T>(title: title, instruction: instruction, read: read),
  ),
);

class _QrCameraPage<T> extends StatefulWidget {
  const _QrCameraPage({
    required this.title,
    required this.instruction,
    required this.read,
  });

  final String title;
  final String instruction;
  final T Function(String) read;

  @override
  State<_QrCameraPage<T>> createState() => _QrCameraPageState<T>();
}

class _QrCameraPageState<T> extends State<_QrCameraPage<T>>
    with WidgetsBindingObserver {
  final _camera = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _accepted = false;
  String? _rejection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera permission dialog can change lifecycle state before startup.
    if (_accepted || !_camera.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_camera.start());
    } else if (state == AppLifecycleState.inactive) {
      unawaited(_camera.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera.dispose());
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_accepted || !mounted) return;
    String? rejected;
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text == null || text.isEmpty) continue;
      try {
        final result = widget.read(text);
        _accepted = true;
        Navigator.pop(context, result);
        return;
      } on InputException catch (error) {
        rejected = error.message;
      } on FormatException {
        rejected = '二维码内容无法读取，请扫描 Dorm 的二维码';
      }
    }
    if (rejected != null && _rejection != rejected) {
      setState(() => _rejection = rejected);
    }
  }

  Widget _cameraError(BuildContext context, MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            const Icon(Icons.no_photography_outlined, size: 36),
            Text(
              denied ? '请在 Android 的应用权限设置中允许 Dorm 使用相机。' : '无法启动相机，请检查相机是否可用。',
              textAlign: TextAlign.center,
            ),
            OutlinedButton(
              onPressed: () => unawaited(_camera.start()),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _camera,
              onDetect: _detected,
              errorBuilder: _cameraError,
              overlayBuilder: (context, constraints) {
                final side =
                    min(constraints.maxWidth, constraints.maxHeight) * 0.72;
                return IgnorePointer(
                  child: Center(
                    child: SizedBox.square(
                      dimension: side,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _rejection ?? widget.instruction,
                textAlign: TextAlign.center,
                style: _rejection == null
                    ? null
                    : TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
