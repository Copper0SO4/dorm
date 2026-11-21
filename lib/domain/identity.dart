import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'ledger.dart';

final _identityPattern = RegExp(r'^[a-f0-9]{32}$');

bool isIdentityCode(Object? value) =>
    value is String && _identityPattern.hasMatch(value);

String newIdentityCode() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

const avatarSize = 96;

Uint8List decodeAvatar(String encoded) {
  try {
    if (encoded.length <= 52000) {
      final bytes = base64Decode(encoded);
      const pngPrefix = [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
      ];
      if (bytes.length >= 33 &&
          pngPrefix.indexed.every((item) => bytes[item.$1] == item.$2)) {
        final data = ByteData.sublistView(bytes);
        if (data.getUint32(16) == avatarSize &&
            data.getUint32(20) == avatarSize) {
          return bytes;
        }
      }
    }
  } on FormatException {
    // All unsupported image payloads use the same validation message.
  }
  throw const InputException('头像图片格式无效');
}

enum ClaimState { active, released, conflict }

typedef MyIdentity = ({String deviceCode, int? memberId, bool conflicted});

enum AuditTarget { member, bill }

enum AuditAction {
  create('新增'),
  update('编辑'),
  remove('删除'),
  transfer('记录转账'),
  settlement('批量结算');

  const AuditAction(this.label);
  final String label;
}

typedef AuditEntry = ({
  String deviceCode,
  String? memberName,
  String date,
  AuditAction action,
  String detail,
});
