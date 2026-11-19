import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/ledger.dart';

class CloudKey {
  factory CloudKey(String text, String passphrase) {
    final privateKey = text.trim().replaceAll('\r\n', '\n');
    const start = '-----BEGIN OPENSSH PRIVATE KEY-----';
    const end = '-----END OPENSSH PRIVATE KEY-----';
    if (privateKey.length > 24 * 1024 ||
        !privateKey.startsWith(start) ||
        !privateKey.endsWith(end) ||
        passphrase.contains('\u0000')) {
      throw const InputException('请粘贴完整的 OpenSSH 私钥，包含 BEGIN 和 END 两行');
    }
    try {
      final body = base64.decode(
        privateKey
            .substring(start.length, privateKey.length - end.length)
            .replaceAll(RegExp(r'\s'), ''),
      );
      const magic = 'openssh-key-v1\u0000';
      if (body.length <= magic.length ||
          utf8.decode(body.sublist(0, magic.length)) != magic) {
        throw const FormatException();
      }
      final data = ByteData.sublistView(body);
      var offset = magic.length;
      int readInt() {
        final value = data.getUint32(offset);
        offset += 4;
        return value;
      }

      Uint8List readBytes() {
        final length = readInt();
        final value = Uint8List.sublistView(body, offset, offset + length);
        offset += length;
        return value;
      }

      final cipher = utf8.decode(readBytes());
      readBytes(); // KDF name
      readBytes(); // KDF options
      if (readInt() != 1) throw const FormatException();
      final publicBytes = readBytes();
      final algorithmLength = ByteData.sublistView(publicBytes).getUint32(0);
      final algorithm = utf8.decode(
        publicBytes.sublist(4, 4 + algorithmLength),
      );
      if (readBytes().isEmpty ||
          offset != body.length ||
          !RegExp(r'^[a-zA-Z0-9@_.-]+$').hasMatch(algorithm)) {
        throw const FormatException();
      }
      if (cipher != 'none' && passphrase.isEmpty) {
        throw const InputException('此 SSH 私钥已加密，请填写私钥口令');
      }
      return CloudKey._(
        '$privateKey\n',
        '$algorithm ${base64.encode(publicBytes)}',
        passphrase,
      );
    } on FormatException {
      throw const InputException('SSH 私钥格式不正确');
    } on RangeError {
      throw const InputException('SSH 私钥内容不完整');
    }
  }

  const CloudKey._(this.privateKey, this.publicKey, this.passphrase);

  final String privateKey;
  final String publicKey;
  final String passphrase;
}

String cloudRepositoryId(String repository) =>
    sha256.convert(utf8.encode(repository)).toString();

class SshVault {
  SshVault(Directory appDirectory)
    : _directory = Directory(
        '${appDirectory.path}${Platform.pathSeparator}cloud-credentials',
      );

  final Directory _directory;

  File _file(String repository) => File(
    '${_directory.path}${Platform.pathSeparator}${cloudRepositoryId(repository)}.json',
  );

  Future<CloudKey?> read(String repository) async {
    final file = _file(repository);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return CloudKey(json['key'] as String, json['passphrase'] as String);
  }

  Future<void> save(String repository, CloudKey key) async {
    await _directory.create(recursive: true);
    if (Platform.isWindows) {
      final user = await Process.run('whoami.exe', [
        '/user',
        '/fo',
        'csv',
        '/nh',
      ]);
      final sid = RegExp(r'S-1-\d+(?:-\d+)+')
          .firstMatch(user.stdout.toString())
          ?.group(0);
      if (user.exitCode != 0 || sid == null) {
        throw const InputException('无法确定当前 Windows 用户，私钥未保存');
      }
      final acl = await Process.run('icacls.exe', [
        _directory.path,
        '/inheritance:r',
        '/grant:r',
        '*$sid:(OI)(CI)F',
      ]);
      if (acl.exitCode != 0) throw const InputException('无法限制私钥目录权限，私钥未保存');
    } else if (!Platform.isAndroid && !Platform.isIOS) {
      final permissions = await Process.run('chmod', ['700', _directory.path]);
      if (permissions.exitCode != 0) {
        throw const InputException('无法限制私钥目录权限，私钥未保存');
      }
    }
    final file = _file(repository);
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsString(
        jsonEncode({'key': key.privateKey, 'passphrase': key.passphrase}),
        flush: true,
      );
      if (!Platform.isWindows && !Platform.isAndroid && !Platform.isIOS) {
        final permissions = await Process.run('chmod', ['600', temp.path]);
        if (permissions.exitCode != 0) {
          throw const InputException('无法限制私钥文件权限，私钥未保存');
        }
      }
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> remove(String repository) async {
    final file = _file(repository);
    if (await file.exists()) await file.delete();
  }
}
