import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../domain/ledger.dart';
import 'dorm_invite.dart';
import 'qr_image.dart';

const _prefix = 'DORM-INVITE:';
const _maxQrText = 2000;

String newInviteCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(
    4,
    (_) => List.generate(
      4,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join(),
  ).join('-');
}

String inviteQrText(DormInvite invite) {
  final bytes = invite.encode();
  if (bytes.length + _prefix.length > _maxQrText) {
    throw const InputException('这把密钥较长，请使用 .dorm 文件分享');
  }
  return _prefix + utf8.decode(bytes);
}

DormInvite readInviteQrText(String text) {
  final value = text.trim();
  if (!value.startsWith(_prefix) || value.length > _maxQrText) {
    throw const InputException('这不是有效的 Dorm 邀请二维码');
  }
  return DormInvite.read(utf8.encode(value.substring(_prefix.length)));
}

Future<DormInvite> readInviteQrImage(Uint8List bytes) async =>
    readInviteQrText(await readQrImageText(bytes));
