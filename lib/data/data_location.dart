import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../domain/ledger.dart';
import 'ssh_vault.dart';

typedef _LocationChoice = ({String active, String? pending});

/// Keeps the startup choice beside the default directory, even after relocation.
class DormDataLocation {
  DormDataLocation._(
    this._preferences,
    this._lock,
    _LocationChoice choice,
    this._migrationError,
  ) : directory = Directory(choice.active),
      _pending = choice.pending;

  static const databaseName = 'dormos.sqlite3';
  final Directory directory;
  String? _migrationError;
  final File _preferences;
  final RandomAccessFile _lock;
  String? _pending;

  String? get pending => _pending;
  String? get migrationError => _migrationError;

  static Future<DormDataLocation> open(Directory defaultDirectory) async {
    final base = defaultDirectory.absolute.path;
    final preferences = File('$base.location.json');
    await preferences.parent.create(recursive: true);
    final lock = await File('$base.location.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.shared);
      var choice = await _read(preferences, base);
      String? error;
      if (choice.pending != null) {
        await lock.unlock();
        try {
          await lock.lock(FileLock.exclusive);
        } on FileSystemException {
          throw const InputException('请关闭其他 Dorm 窗口，再重试配置目录迁移。');
        }
        choice = await _read(preferences, base);
        if (choice.pending case final target?) {
          try {
            await _migrate(
              preferences,
              Directory(choice.active),
              Directory(target),
            );
          } on InputException catch (failure) {
            error = failure.message;
          } on Exception {
            error = '迁移未完成，请检查目标目录的访问权限和可用空间。';
          }
        }
        await lock.unlock();
        await lock.lock(FileLock.shared);
        choice = await _read(preferences, base);
      }
      if (choice.active != base &&
          !await _dataFile(Directory(choice.active), databaseName).exists()) {
        throw InputException('配置目录不可用，请检查磁盘是否已连接。\n${choice.active}');
      }
      return DormDataLocation._(preferences, lock, choice, error);
    } catch (_) {
      await lock.close();
      rethrow;
    }
  }

  Future<void> schedule(Directory parent) async {
    final resolved = Directory(await parent.resolveSymbolicLinks());
    final destination = _dataFile(resolved, 'Dorm').path;
    final current = await directory.resolveSymbolicLinks();
    if (_insideOrEqual(destination, current)) {
      throw const InputException('请在当前配置目录之外选择新位置。');
    }
    await _requireUnused(destination);
    final probe = await resolved.createTemp('.dorm-check-');
    await probe.delete();
    await _write(_preferences, (active: directory.path, pending: destination));
    _pending = destination;
    _migrationError = null;
  }

  Future<void> cancel() async {
    await _write(_preferences, (active: directory.path, pending: null));
    _pending = null;
    _migrationError = null;
  }

  void close() => _lock.closeSync();

  static File _dataFile(Directory directory, String filename) =>
      File('${directory.path}${Platform.pathSeparator}$filename');

  static bool _insideOrEqual(String path, String directory) {
    String comparable(String value) {
      final normalized = value
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'/+$'), '');
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final target = comparable(path);
    final parent = comparable(directory);
    return target == parent || target.startsWith('$parent/');
  }

  static Future<void> _requireUnused(String destination) async {
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const InputException('这个位置已有 Dorm 文件夹，请选择其他位置。');
    }
  }

  static Future<_LocationChoice> _read(File file, String base) async {
    if (!await file.exists()) return (active: base, pending: null);
    try {
      final value = jsonDecode(await file.readAsString());
      if (value case {
        'active': final String active,
        'pending': final String? pending,
      }) {
        if (active.isNotEmpty && pending != '') {
          return (active: active, pending: pending);
        }
      }
    } on FormatException {
      // A malformed location record must not cause a silent switch of data.
    }
    throw const InputException('配置目录记录无法读取。');
  }

  static Future<void> _write(File file, _LocationChoice choice) async {
    final staging = await file.parent.createTemp('.dorm-location-');
    final temp = _dataFile(staging, 'location.json');
    try {
      await temp.writeAsString(
        jsonEncode({'active': choice.active, 'pending': choice.pending}),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
      await staging.delete();
    }
  }

  static Future<void> _migrate(
    File preferences,
    Directory source,
    Directory destination,
  ) async {
    final parent = Directory(await destination.parent.resolveSymbolicLinks());
    final target = _dataFile(parent, 'Dorm').path;
    if (_insideOrEqual(target, await source.resolveSymbolicLinks())) {
      throw const InputException('目标位置位于当前配置目录内。');
    }
    await _requireUnused(target);
    final staging = await parent.createTemp('.dorm-data-');
    try {
      await _copyDatabase(
        _dataFile(source, databaseName),
        _dataFile(staging, databaseName),
      );
      final identity = _dataFile(source, '$databaseName.identity');
      if (await identity.exists()) {
        await _copyDatabase(
          identity,
          _dataFile(staging, '$databaseName.identity'),
        );
      }
      await SshVault(source).copyTo(staging);
      await _requireUnused(target);
      // Rename the complete data directory before recording it as active.
      await staging.rename(target);
      await _write(preferences, (active: target, pending: null));
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static Future<void> _copyDatabase(File source, File target) async {
    final input = sqlite3.open(source.path, mode: OpenMode.readOnly);
    try {
      final output = sqlite3.open(target.path);
      try {
        await input.backup(output).drain<void>();
      } finally {
        output.close();
      }
    } finally {
      input.close();
    }
  }
}
