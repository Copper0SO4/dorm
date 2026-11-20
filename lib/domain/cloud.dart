import 'dart:convert';

import 'ledger.dart';

const cloudBranch = 'dormos-data';
const cloudFileName = 'dormos.json';
const maxCloudBytes = 8 * 1024 * 1024;

String githubSshAddress(String input) {
  final match = RegExp(
    r'^(?:https://github\.com/|ssh://git@github\.com/|ssh://git@ssh\.github\.com:443/|git@github\.com:|github\.com/)?([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9_.-]{1,100})/?$',
    caseSensitive: false,
  ).firstMatch(input.trim());
  if (match != null) {
    final owner = match[1]!.toLowerCase();
    final repo = match[2]!
        .replaceFirst(RegExp(r'\.git$', caseSensitive: false), '')
        .toLowerCase();
    if (repo.isNotEmpty &&
        repo != '.' &&
        repo != '..' &&
        !repo.startsWith('-')) {
      return 'git@github.com:$owner/$repo.git';
    }
  }
  throw const InputException('请输入 GitHub 仓库地址，例如 https://github.com/账号/仓库');
}

class CloudSettings {
  CloudSettings({
    required String repository,
    required String operator,
    String email = '',
    this.useDeviceKey = false,
  }) : repository = githubSshAddress(repository),
       operator = operator.trim(),
       email = email.trim() {
    if (this.operator.isEmpty ||
        this.operator.runes.length > 50 ||
        RegExp(r'[\x00-\x1f\x7f<>]').hasMatch(this.operator)) {
      throw const InputException('请输入 1 至 50 字的操作者名称');
    }
    if (this.email.isNotEmpty &&
        (this.email.length > 254 ||
            !RegExp(r'^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$')
                .hasMatch(this.email))) {
      throw const InputException('请输入有效的 Git 提交邮箱，或留空');
    }
  }

  final String repository;
  final String operator;
  final String email;
  final bool useDeviceKey;

  String get commitEmail =>
      email.isEmpty ? 'dormos@users.noreply.github.com' : email;
}

class CloudTable {
  const CloudTable(
    this.name,
    this.label,
    this.columns, {
    this.references = const {},
    this.keyColumns = const [],
  });

  final String name;
  final String label;
  final List<String> columns;
  final Map<String, String> references;
  final List<String> keyColumns;

  bool get hasSyncId => keyColumns.isEmpty;
  String keyOf(Map<String, Object?> row) =>
      keyColumns.map((column) => row[column]).join('/');
}

const cloudTables = [
  CloudTable('members', '成员', ['name', 'active']),
  CloudTable('supplies', '物资', [
    'name',
    'category',
    'quantity',
    'location',
    'note',
    'status',
    'deleted',
  ]),
  CloudTable(
    'bills',
    '账单',
    ['title', 'total', 'payer_id', 'created_at', 'supply_id', 'supply_name'],
    references: {'payer_id': 'members', 'supply_id': 'supplies'},
  ),
  CloudTable(
    'shares',
    '分摊',
    ['bill_id', 'member_id', 'amount'],
    references: {'bill_id': 'bills', 'member_id': 'members'},
    keyColumns: ['bill_id', 'member_id'],
  ),
  CloudTable(
    'transfers',
    '转账',
    ['bill_id', 'member_id', 'amount', 'created_at'],
    references: {'bill_id': 'bills', 'member_id': 'members'},
  ),
  CloudTable(
    'chores',
    '卫生任务',
    ['title', 'cadence', 'next_day', 'last_member_id', 'active'],
    references: {'last_member_id': 'members'},
  ),
  CloudTable(
    'shifts',
    '排班',
    ['task_id', 'day', 'member_id', 'completed_at'],
    references: {'task_id': 'chores', 'member_id': 'members'},
    keyColumns: ['task_id', 'day'],
  ),
];

typedef CloudRow = Map<String, Object?>;
typedef CloudRows = Map<String, CloudRow>;

class CloudSnapshot {
  CloudSnapshot(Map<String, CloudRows> input)
    : tables = Map<String, CloudRows>.unmodifiable({
        for (final table in cloudTables)
          table.name: Map<String, CloudRow>.unmodifiable({
            for (final key
                in (input[table.name]?.keys.toList() ?? <String>[])..sort())
              key: Map<String, Object?>.unmodifiable({
                for (final column in table.columns)
                  column: input[table.name]![key]![column],
              }),
          }),
      });

  factory CloudSnapshot.decode(String encoded) {
    if (utf8.encode(encoded).length > maxCloudBytes) {
      throw const InputException('云端快照超过 8 MB，无法读取');
    }
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic> ||
        value['format'] != 1 ||
        value['tables'] is! Map<String, dynamic>) {
      throw const InputException('云端文件格式不受支持');
    }
    final rawTables = value['tables'] as Map<String, dynamic>;
    if (rawTables.length != cloudTables.length) {
      throw const InputException('云端文件表结构不完整');
    }
    final tables = <String, CloudRows>{};
    final syncId = RegExp(r'^[a-f0-9]{32}$');
    for (final table in cloudTables) {
      final rows = rawTables[table.name];
      if (rows is! Map<String, dynamic>) {
        throw const InputException('云端文件表结构不完整');
      }
      final decoded = <String, CloudRow>{};
      for (final entry in rows.entries) {
        final row = entry.value;
        if (row is! Map<String, dynamic> ||
            row.length != table.columns.length ||
            !table.columns.every(row.containsKey) ||
            row.values.any(
              (value) => value != null && value is! int && value is! String,
            ) ||
            (table.hasSyncId
                ? !syncId.hasMatch(entry.key)
                : entry.key != table.keyOf(row))) {
          throw InputException('云端${table.label}记录格式不正确');
        }
        for (final column in table.references.keys) {
          final value = row[column];
          if (value == null &&
              (column == 'supply_id' || column == 'last_member_id')) {
            continue;
          }
          if (value is! String || !syncId.hasMatch(value)) {
            throw InputException('云端${table.label}的关联记录格式不正确');
          }
        }
        for (final column in table.columns.where(
          (column) => column == 'day' || column == 'next_day',
        )) {
          final value = row[column];
          if (value is! String ||
              !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
              DateTime.tryParse(value) == null) {
            throw InputException('云端${table.label}的日期格式不正确');
          }
        }
        decoded[entry.key] = row;
      }
      tables[table.name] = decoded;
    }
    return CloudSnapshot(tables);
  }

  final Map<String, CloudRows> tables;

  late final String encoded = jsonEncode({'format': 1, 'tables': tables});
  bool get isEmpty => tables.values.every((rows) => rows.isEmpty);
  bool sameAs(CloudSnapshot other) => encoded == other.encoded;
}

enum CloudSide { local, remote }

typedef CloudRowConflict = ({
  CloudTable table,
  String key,
  CloudRow? base,
  CloudRow? local,
  CloudRow? remote,
});

class CloudMerge {
  CloudMerge(this.local, this.remote, CloudSnapshot base) {
    for (final table in cloudTables) {
      final baseRows = base.tables[table.name]!;
      final localRows = local.tables[table.name]!;
      final remoteRows = remote.tables[table.name]!;
      final result = _merged[table.name] = {};
      for (final key in {
        ...baseRows.keys,
        ...localRows.keys,
        ...remoteRows.keys,
      }) {
        final original = baseRows[key];
        final here = localRows[key];
        final there = remoteRows[key];
        if (_sameRow(here, there) || _sameRow(there, original)) {
          if (here != null) result[key] = here;
        } else if (_sameRow(here, original)) {
          if (there != null) result[key] = there;
        } else {
          conflicts.add((
            table: table,
            key: key,
            base: original,
            local: here,
            remote: there,
          ));
        }
      }
    }
  }

  final CloudSnapshot local;
  final CloudSnapshot remote;
  final conflicts = <CloudRowConflict>[];
  final _merged = <String, CloudRows>{};

  CloudSnapshot resolve(Map<int, CloudSide> choices) {
    final result = {
      for (final entry in _merged.entries)
        entry.key: Map<String, CloudRow>.of(entry.value),
    };
    for (final (index, conflict) in conflicts.indexed) {
      final choice = choices[index];
      if (choice == null) throw const InputException('请选择每条冲突记录要保留的版本');
      final row = choice == CloudSide.local ? conflict.local : conflict.remote;
      if (row != null) result[conflict.table.name]![conflict.key] = row;
    }
    return CloudSnapshot(result);
  }

  static bool _sameRow(CloudRow? a, CloudRow? b) =>
      jsonEncode(a) == jsonEncode(b);
}

abstract interface class CloudStore {
  CloudSettings? get settings;
  void saveSettings(CloudSettings? settings);
  CloudSnapshot? get base;
  CloudSnapshot snapshot();
  void accept(CloudSnapshot data, CloudSnapshot base);
  void rememberBase(CloudSnapshot base);
}
