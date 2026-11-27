import 'dart:convert';

import 'package:dormos/data/dorm_invite.dart';
import 'package:dormos/data/invite_qr.dart';
import 'package:dormos/data/qr_image.dart';
import 'package:dormos/data/ssh_vault.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the QR image round trips the same encrypted repository key', () async {
    final key = await CloudKey.generate();
    final code = newInviteCode();
    final invite = await DormInvite('room/dorm').withSharedKey(key, code);
    final text = inviteQrText(invite);
    expect(text, isNot(contains(code)));
    expect(text, isNot(contains('PRIVATE KEY')));
    final image = await makeQrPng(text);
    final recovered = await readInviteQrImage(image);
    expect(recovered.repository, invite.repository);
    expect(recovered.requiresPassword, isTrue);
    expect((await recovered.unlock(code)).privateKey, key.privateKey);
    expect(
      () => readInviteQrText('http://invalid.example/qrcode'),
      throwsA(isA<InputException>()),
    );
  });

  test('a repository-only invite round trips without a credential', () {
    final encoded = DormInvite('https://github.com/Room/Dorm.git').encode();
    final invite = DormInvite.read(encoded);
    expect(invite.repository, 'git@github.com:room/dorm.git');
    expect(invite.requiresPassword, isFalse);
    final fields = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
    expect(
      fields.keys,
      unorderedEquals(['format', 'version', 'repository', 'access']),
    );
  });

  test(
    'rejects oversized files and invalid versions, hosts, and payload lengths',
    () {
      final inputError = throwsA(isA<InputException>());
      final fields = jsonDecode(
        utf8.decode(DormInvite('room/dorm').encode()),
      ) as Map<String, dynamic>;
      List<int> withFields(Map<String, dynamic> changes) =>
          utf8.encode(jsonEncode({...fields, ...changes}));

      expect(
        () => DormInvite.read(List.filled(maxDormInviteBytes + 1, 0)),
        inputError,
      );
      expect(() => DormInvite.read(withFields({'version': 2})), inputError);
      expect(
        () => DormInvite.read(
          withFields({'repository': 'https://example.com/room/dorm'}),
        ),
        inputError,
      );
      expect(
        () => DormInvite.read(
          withFields({
            'access': 'shared-key',
            'salt': 'AA==',
            'nonce': 'AA==',
            'mac': 'AA==',
            'encryptedKey': 'AA==',
          }),
        ),
        inputError,
      );
    },
  );

  test('encrypts private credentials and rejects wrong passwords or repository changes', () async {
    final key = await CloudKey.generate();
    final original = DormInvite('room/dorm');
    const password = 'local invite test passphrase';
    expect(
      () => original.withSharedKey(key, 'short'),
      throwsA(isA<InputException>()),
    );
    final encoded = (await original.withSharedKey(key, password)).encode();
    final contents = utf8.decode(encoded);
    expect(contents, isNot(contains('PRIVATE KEY')));
    expect(contents, isNot(contains(password)));
    final invite = DormInvite.read(encoded);
    expect(invite.requiresPassword, isTrue);
    final decoded = await invite.unlock(password);
    expect(decoded.publicKey, key.publicKey);
    expect(decoded.privateKey, key.privateKey);
    await expectLater(
      invite.unlock('a different password'),
      throwsA(isA<InputException>()),
    );

    final switched = DormInvite.read(
      utf8.encode(contents.replaceFirst('room/dorm.git', 'other/dorm.git')),
    );
    await expectLater(
      switched.unlock(password),
      throwsA(isA<InputException>()),
    );
  });

  test('direct-key .dorm invite and QR image work without password', () async {
    final key = await CloudKey.generate();
    final direct = DormInvite('room/dorm').withDirectKey(key);
    final encoded = direct.encode();
    final fields = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
    expect(fields['access'], 'direct-key');
    expect(fields['publicKey'], key.publicKey);
    final invite = DormInvite.read(encoded);
    expect(invite.requiresPassword, isFalse);
    expect(invite.directKey?.privateKey, key.privateKey);
    expect(invite.directKey?.publicKey, key.publicKey);

    final qrText = inviteQrText(direct);
    final qrImage = await makeQrPng(qrText);
    final qrRecovered = await readInviteQrImage(qrImage);
    expect(qrRecovered.requiresPassword, isFalse);
    expect(qrRecovered.directKey?.privateKey, key.privateKey);
    expect(qrRecovered.directKey?.publicKey, key.publicKey);
  });

  test('unlock accepts 16-char invite code without hyphens or uppercase', () async {
    final key = await CloudKey.generate();
    const code = 'SUKW-9WBZ-MG3A-A9FY';
    final invite = DormInvite.read(
      (await DormInvite('room/dorm').withSharedKey(key, code)).encode(),
    );
    final decoded = await invite.unlock('sukw9wbzmg3aa9fy');
    expect(decoded.privateKey, key.privateKey);
  });
}
