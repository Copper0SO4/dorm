import 'dart:io';

import 'package:dormos/data/data_location.dart';
import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/data/ssh_vault.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

String _child(Directory directory, String name) =>
    '${directory.path}${Platform.pathSeparator}$name';

SqliteDormRepository _openRepository(Directory directory) =>
    SqliteDormRepository.open(_child(directory, DormDataLocation.databaseName));

void main() {
  test(
    'next startup moves the latest data, device code and SSH configuration',
    () async {
      final root = await Directory.systemTemp.createTemp('dorm-data-location-');
      addTearDown(() => root.delete(recursive: true));
      final base = await Directory(_child(root, 'original')).create();
      final target = await Directory(_child(root, '新位置 with spaces')).create();
      final note = await File(_child(target, 'note.txt')).writeAsString('keep');
      final destination = Directory(_child(target, 'Dorm'));
      final settings = CloudSettings(repository: 'example/room', operator: '甲');

      final first = await DormDataLocation.open(base);
      late final String deviceCode;
      late final CloudKey key;
      try {
        final repo = _openRepository(first.directory);
        try {
          repo.saveMember('甲');
          repo.saveAppearanceMode(AppearanceMode.dark);
          repo.cloud.saveSettings(settings);
          deviceCode = repo.deviceCode;
          final vault = SshVault(first.directory);
          key = await vault.generateDevice();
          await vault.save(settings.repository, key);
          await Directory(_child(first.directory, 'cloud-git')).create();

          await first.schedule(target);
          expect(first.directory.path, base.path);
          expect(first.pending, isNotNull);
          expect(await destination.exists(), isFalse);
          if (Platform.isWindows) {
            await expectLater(
              DormDataLocation.open(base),
              throwsA(isA<InputException>()),
            );
          }
          repo.saveMember('选择后新增');
        } finally {
          repo.close();
        }
      } finally {
        first.close();
      }

      final moved = await DormDataLocation.open(base);
      try {
        expect(moved.pending, isNull);
        expect(moved.migrationError, isNull);
        expect(
          await moved.directory.resolveSymbolicLinks(),
          await destination.resolveSymbolicLinks(),
        );
        final repo = _openRepository(moved.directory);
        try {
          expect(repo.members().map((member) => member.name), ['甲', '选择后新增']);
          expect(repo.appearanceMode, AppearanceMode.dark);
          expect(repo.cloud.settings?.repository, settings.repository);
          expect(repo.deviceCode, deviceCode);
        } finally {
          repo.close();
        }
        final vault = SshVault(moved.directory);
        expect((await vault.readDevice())?.publicKey, key.publicKey);
        expect(
          (await vault.read(settings.repository))?.publicKey,
          key.publicKey,
        );
        expect(
          await Directory(_child(moved.directory, 'cloud-git')).exists(),
          isFalse,
        );
        expect(await note.readAsString(), 'keep');
        expect(
          await File(_child(base, DormDataLocation.databaseName)).exists(),
          isTrue,
        );
      } finally {
        moved.close();
      }

      final reopened = await DormDataLocation.open(base);
      try {
        expect(reopened.directory.path, moved.directory.path);
        expect(reopened.pending, isNull);
      } finally {
        reopened.close();
      }
    },
  );

  test(
    'a newly occupied destination leaves current data and allows cancellation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dorm-location-collision-',
      );
      addTearDown(() => root.delete(recursive: true));
      final base = await Directory(_child(root, 'original')).create();
      final target = await Directory(_child(root, 'other')).create();

      final first = await DormDataLocation.open(base);
      try {
        final repo = _openRepository(first.directory);
        try {
          repo.saveMember('原数据');
        } finally {
          repo.close();
        }
        await expectLater(first.schedule(base), throwsA(isA<InputException>()));
        await first.schedule(target);
      } finally {
        first.close();
      }

      final unrelated = await Directory(_child(target, 'Dorm')).create();
      final note = await File(_child(unrelated, 'note.txt'))
          .writeAsString('existing');
      final reopened = await DormDataLocation.open(base);
      try {
        expect(reopened.directory.path, base.path);
        expect(reopened.pending, unrelated.path);
        expect(reopened.migrationError, contains('已有 Dorm 文件夹'));
        expect(await note.readAsString(), 'existing');
        final repo = _openRepository(reopened.directory);
        try {
          expect(repo.members().single.name, '原数据');
        } finally {
          repo.close();
        }
        await reopened.cancel();
        expect(reopened.pending, isNull);
      } finally {
        reopened.close();
      }

      final cancelled = await DormDataLocation.open(base);
      try {
        expect(cancelled.directory.path, base.path);
        expect(cancelled.pending, isNull);
        expect(cancelled.migrationError, isNull);
      } finally {
        cancelled.close();
      }
    },
  );
}
