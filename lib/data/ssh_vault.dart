import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' show Ed25519;

import '../domain/ledger.dart';
import 'cloud_proxy.dart';

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

  static Future<CloudKey> generate() async {
    final random = Random.secure();
    final pair = await Ed25519().newKeyPairFromSeed(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final material = await pair.extract();
    final algorithm = utf8.encode('ssh-ed25519');
    final public = material.publicKey.bytes;
    final publicBlob = [..._sshField(algorithm), ..._sshField(public)];
    final check = List.generate(4, (_) => random.nextInt(256));
    // OpenSSH expects the secret seed followed by the public key.
    final privateBlob = [
      ...check,
      ...check,
      ...publicBlob,
      ..._sshField([...material.bytes, ...public]),
      ..._sshField(utf8.encode('DormOS')),
    ];
    final padding = (8 - privateBlob.length % 8) % 8;
    final encoded = base64.encode([
      ...utf8.encode('openssh-key-v1\u0000'),
      ..._sshField(utf8.encode('none')),
      ..._sshField(utf8.encode('none')),
      ..._sshField([]),
      0,
      0,
      0,
      1,
      ..._sshField(publicBlob),
      ..._sshField([...privateBlob, for (var i = 1; i <= padding; i++) i]),
    ]);
    final lines = RegExp('.{1,70}')
        .allMatches(encoded)
        .map((m) => m[0])
        .join('\n');
    return CloudKey(
      '-----BEGIN OPENSSH PRIVATE KEY-----\n$lines\n-----END OPENSSH PRIVATE KEY-----',
      '',
    );
  }

  static List<int> _sshField(List<int> bytes) {
    final length = ByteData(4)..setUint32(0, bytes.length);
    return [...length.buffer.asUint8List(), ...bytes];
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
  Future<CloudKey>? _generation;

  File get _deviceFile =>
      File('${_directory.path}${Platform.pathSeparator}device-key.json');

  File get _proxyFile =>
      File('${_directory.path}${Platform.pathSeparator}proxy.json');

  Future<CloudKey?> readDevice() => _read(_deviceFile);

  Future<CloudProxy?> readProxy() async {
    final json = await _readJson(_proxyFile);
    if (json == null) return null;
    return CloudProxy(
      kind: CloudProxyKind.values.byName(json['kind'] as String),
      host: json['host'] as String,
      port: json['port'] as int,
      username: json['username'] as String,
      password: json['password'] as String,
    );
  }

  Future<void> saveProxy(CloudProxy? proxy) async {
    if (proxy == null) {
      if (await _proxyFile.exists()) await _proxyFile.delete();
      return;
    }
    await _save(_proxyFile, {
      'kind': proxy.kind.name,
      'host': proxy.host,
      'port': proxy.port,
      'username': proxy.username,
      'password': proxy.password,
    });
  }

  Future<CloudKey> generateDevice() async {
    final pending = _generation ??= _generateDevice();
    try {
      return await pending;
    } finally {
      if (identical(_generation, pending)) _generation = null;
    }
  }

  Future<CloudKey> _generateDevice() async {
    await _directory.create(recursive: true);
    // Separate app processes must reuse the same key if both request generation.
    final lock = await File('${_deviceFile.path}.lock')
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final existing = await readDevice();
      if (existing != null) return existing;
      final key = await CloudKey.generate();
      await _saveKey(_deviceFile, key);
      return key;
    } finally {
      await lock.close();
    }
  }

  File _file(String repository) => File(
    '${_directory.path}${Platform.pathSeparator}${cloudRepositoryId(repository)}.json',
  );

  Future<CloudKey?> read(String repository) => _read(_file(repository));

  Future<CloudKey?> _read(File file) async {
    final json = await _readJson(file);
    return json == null
        ? null
        : CloudKey(json['key'] as String, json['passphrase'] as String);
  }

  Future<Map<String, dynamic>?> _readJson(File file) async {
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> save(String repository, CloudKey key) =>
      _saveKey(_file(repository), key);

  Future<void> _saveKey(File file, CloudKey key) =>
      _save(file, {'key': key.privateKey, 'passphrase': key.passphrase});

  Future<void> _save(File file, Map<String, Object?> payload) async {
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
        throw const InputException('无法确定当前 Windows 用户，凭据未保存');
      }
      final acl = await Process.run('icacls.exe', [
        _directory.path,
        '/inheritance:r',
        '/grant:r',
        '*$sid:(OI)(CI)F',
      ]);
      if (acl.exitCode != 0) throw const InputException('无法限制凭据目录权限，设置未保存');
    } else if (!Platform.isAndroid && !Platform.isIOS) {
      final permissions = await Process.run('chmod', ['700', _directory.path]);
      if (permissions.exitCode != 0) {
        throw const InputException('无法限制凭据目录权限，设置未保存');
      }
    }
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsString(jsonEncode(payload), flush: true);
      if (!Platform.isWindows && !Platform.isAndroid && !Platform.isIOS) {
        final permissions = await Process.run('chmod', ['600', temp.path]);
        if (permissions.exitCode != 0) {
          throw const InputException('无法限制凭据文件权限，设置未保存');
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
