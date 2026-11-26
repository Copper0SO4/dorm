import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

import '../domain/ledger.dart';

Future<bool> saveDocument(
  XFile source, {
  required String name,
  required String extension,
  required String label,
  String mimeType = 'application/octet-stream',
}) async {
  if (Platform.isAndroid) {
    final folder = await (await getTemporaryDirectory()).createTemp(
      'dorm-document-',
    );
    try {
      final path = '${folder.path}${Platform.pathSeparator}$name';
      await source.saveTo(path);
      return await const MethodChannel('org.dormos.dormos/documents')
              .invokeMethod<bool>('save', {
                'name': name,
                'path': path,
                'mimeType': mimeType,
              }) ??
          false;
    } finally {
      await folder.delete(recursive: true);
    }
  }

  final destination = await getSaveLocation(
    acceptedTypeGroups: [
      XTypeGroup(label: label, extensions: [extension]),
    ],
    suggestedName: name,
  );
  if (destination == null) return false;
  var targetPath = destination.path;
  if (!targetPath.toLowerCase().endsWith('.$extension')) {
    final fileName = targetPath.split(RegExp(r'[/\\]')).last;
    if (fileName.contains('.')) {
      throw InputException('请用 .$extension 作为文件扩展名');
    }
    targetPath = '$targetPath.$extension';
  }
  await source.saveTo(targetPath);
  return true;
}
