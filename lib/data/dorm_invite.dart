import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/cloud.dart';
import '../domain/ledger.dart';
import 'ssh_vault.dart';

const maxDormInviteBytes = 64 * 1024;

class DormInvite {
  DormInvite(String repository)
    : this._(githubSshAddress(repository), null, null, null);

  const DormInvite._(
    this.repository,
    this._salt,
    this._credentials,
    this.directKey,
  );

  static const _format = 'dormos-invite';
  static const _version = 1;

  final String repository;
  final List<int>? _salt;
  final SecretBox? _credentials;
  final CloudKey? directKey;

  bool get requiresPassword => _credentials != null;

  factory DormInvite.read(List<int> bytes) {
    if (bytes.length > maxDormInviteBytes) {
      throw const InputException('.dorm 文件超过 64 KB');
    }
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic> || json['format'] != _format) {
        throw const FormatException();
      }
      if (json['version'] is! int || json['version'] != _version) {
        throw const InputException('此 .dorm 文件版本暂不受支持');
      }
      final repository = githubSshAddress(json['repository'] as String);
      if (json['access'] == 'repository' && json.length == 4) {
        return DormInvite._(repository, null, null, null);
      }
      if (json['access'] == 'direct-key' &&
          (json.length == 6 || json.length == 7)) {
        final key = CloudKey(
          json['key'] as String,
          json['passphrase'] as String,
        );
        return DormInvite._(repository, null, null, key);
      }
      if (json['access'] != 'shared-key' || json.length != 8) {
        throw const FormatException();
      }
      final salt = base64.decode(json['salt'] as String);
      final nonce = base64.decode(json['nonce'] as String);
      final mac = base64.decode(json['mac'] as String);
      final ciphertext = base64.decode(json['encryptedKey'] as String);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          mac.length != 16 ||
          ciphertext.isEmpty) {
        throw const FormatException();
      }
      return DormInvite._(
        repository,
        salt,
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        null,
      );
    } on FormatException {
      throw const InputException('.dorm 文件格式有误');
    } on TypeError {
      throw const InputException('.dorm 文件格式有误');
    }
  }

  Uint8List encode() {
    final credentials = _credentials;
    final direct = directKey;
    final access = credentials != null
        ? 'shared-key'
        : direct != null
        ? 'direct-key'
        : 'repository';
    final bytes = utf8.encode(
      jsonEncode({
        'format': _format,
        'version': _version,
        'repository': repository,
        'access': access,
        if (direct != null) ...{
          'key': direct.privateKey,
          'publicKey': direct.publicKey,
          'passphrase': direct.passphrase,
        },
        if (credentials != null) ...{
          'salt': base64.encode(_salt!),
          'nonce': base64.encode(credentials.nonce),
          'mac': base64.encode(credentials.mac.bytes),
          'encryptedKey': base64.encode(credentials.cipherText),
        },
      }),
    );
    if (bytes.length > maxDormInviteBytes) {
      throw const InputException('凭据过长，无法导出 .dorm 文件');
    }
    return bytes;
  }

  DormInvite withDirectKey(CloudKey key) =>
      DormInvite._(repository, null, null, key);

  Future<DormInvite> withSharedKey(CloudKey key, String password) {
    if (password.trim().runes.length < 12 || password.length > 256) {
      throw const InputException('邀请口令需为 12 至 256 个字符');
    }
    return Isolate.run(() async {
      final random = Random.secure();
      final salt = List.generate(16, (_) => random.nextInt(256));
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(
          jsonEncode({'key': key.privateKey, 'passphrase': key.passphrase}),
        ),
        secretKey: await _deriveKey(password, salt),
        aad: _associatedData,
      );
      return DormInvite._(repository, salt, box, null);
    });
  }

  Future<CloudKey> unlock(String password) async {
    final direct = directKey;
    if (direct != null) return direct;
    final credentials = _credentials;
    if (credentials == null) {
      throw const InputException('这份邀请只包含仓库地址');
    }
    if (password.isEmpty || password.length > 256) {
      throw const InputException('请输入有效的邀请口令');
    }
    try {
      return await _decryptWithPassword(credentials, password);
    } on SecretBoxAuthenticationError {
      final normalized = _normalizeInviteCode(password);
      if (normalized != null && normalized != password) {
        try {
          return await _decryptWithPassword(credentials, normalized);
        } on SecretBoxAuthenticationError {
          // Fall through to standard invalid password error below.
        } on FormatException {
          throw const InputException('.dorm 文件内的 SSH 凭据格式有误');
        } on TypeError {
          throw const InputException('.dorm 文件内的 SSH 凭据格式有误');
        }
      }
      throw const InputException('口令不正确，或 .dorm 文件已被修改');
    } on FormatException {
      throw const InputException('.dorm 文件内的 SSH 凭据格式有误');
    } on TypeError {
      throw const InputException('.dorm 文件内的 SSH 凭据格式有误');
    }
  }

  Future<CloudKey> _decryptWithPassword(
    SecretBox credentials,
    String password,
  ) => Isolate.run(() async {
    final bytes = await AesGcm.with256bits().decrypt(
      credentials,
      secretKey: await _deriveKey(password, _salt!),
      aad: _associatedData,
    );
    final data = jsonDecode(utf8.decode(bytes));
    return CloudKey(data['key'] as String, data['passphrase'] as String);
  });

  static String? _normalizeInviteCode(String input) {
    final compact = input.replaceAll(RegExp(r'[\s-]+'), '').toUpperCase();
    if (compact.length != 16 || !RegExp(r'^[A-Z0-9]{16}$').hasMatch(compact)) {
      return null;
    }
    return '${compact.substring(0, 4)}-${compact.substring(4, 8)}-'
        '${compact.substring(8, 12)}-${compact.substring(12, 16)}';
  }

  List<int> get _associatedData =>
      utf8.encode('$_format:$_version:$repository');

  static Future<SecretKey> _deriveKey(String password, List<int> salt) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 600000,
        bits: 256,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
}
