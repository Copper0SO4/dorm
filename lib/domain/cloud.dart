import 'dart:convert';

import 'identity.dart';
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
    this.nullableReferences = const {},
    this.keyColumns = const [],
  });

  final String name;
  final String label;
  final List<String> columns;
  final Map<String, String> references;
  final Set<String> nullableReferences;
  final List<String> keyColumns;

  bool get hasSyncId => keyColumns.isEmpty;

  bool inFormat(int format) => switch (name) {
    'matters' => format >= 3,
    'identity_claims' || 'audit_entries' => format >= 5,
    _ => true,
  };

  List<String> wireColumns(int format) => switch (name) {
    'members' when format < 5 => const ['name', 'active'],
    'bills' when format < 5 =>
      columns
          .where(
            (column) =>
                column != 'edit_version' &&
                (column != 'deleted' || format >= 4),
          )
          .toList(),
    'shares' when format == 1 => const ['bill_id', 'member_id', 'amount'],
    'shares' when format < 5 => const [
      'bill_id',
      'member_id',
      'amount',
      'personal_amount',
    ],
    'transfers' when format < 3 => const [
      'bill_id',
      'member_id',
      'amount',
      'created_at',
    ],
    _ => columns,
  };
  String keyOf(Map<String, Object?> row) =>
      keyColumns.map((column) => row[column]).join('/');
}

const cloudTables = [
  CloudTable('members', '成员', ['name', 'active', 'avatar']),
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
    [
      'title',
      'total',
      'payer_id',
      'created_at',
      'supply_id',
      'supply_name',
      'deleted',
      'edit_version',
    ],
    references: {'payer_id': 'members', 'supply_id': 'supplies'},
    nullableReferences: {'supply_id'},
  ),
  CloudTable(
    'shares',
    '分摊',
    ['bill_id', 'member_id', 'amount', 'personal_amount', 'shared'],
    references: {'bill_id': 'bills', 'member_id': 'members'},
    keyColumns: ['bill_id', 'member_id'],
  ),
  CloudTable(
    'transfers',
    '转账',
    ['bill_id', 'member_id', 'amount', 'created_at', 'batch_id'],
    references: {'bill_id': 'bills', 'member_id': 'members'},
  ),
  CloudTable(
    'chores',
    '卫生任务',
    ['title', 'cadence', 'next_day', 'last_member_id', 'active'],
    references: {'last_member_id': 'members'},
    nullableReferences: {'last_member_id'},
  ),
  CloudTable(
    'shifts',
    '排班',
    ['task_id', 'day', 'member_id', 'completed_at'],
    references: {'task_id': 'chores', 'member_id': 'members'},
    keyColumns: ['task_id', 'day'],
  ),
  CloudTable(
    'matters',
    '寝室事务',
    [
      'title',
      'note',
      'owner_id',
      'due_day',
      'urgent',
      'status',
      'created_at',
      'completed_at',
      'archived',
    ],
    references: {'owner_id': 'members'},
    nullableReferences: {'owner_id'},
  ),
  CloudTable('identity_claims', '身份认领', [
    'member_key',
    'device_code',
    'state',
    'created_at',
  ]),
  CloudTable('audit_entries', '操作日志', [
    'target_kind',
    'target_key',
    'device_code',
    'claim_key',
    'action',
    'created_at',
    'detail',
  ]),
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
                  column: column == 'personal_amount' || column == 'deleted'
                      ? input[table.name]![key]![column] ?? 0
                      : input[table.name]![key]![column],
              }),
          }),
      });

  factory CloudSnapshot.decode(String encoded) {
    if (utf8.encode(encoded).length > maxCloudBytes) {
      throw const InputException('云端快照超过 8 MB，无法读取');
    }
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic> ||
        value['tables'] is! Map<String, dynamic>) {
      throw const InputException('云端文件格式不受支持');
    }
    final format = value['format'];
    if (format is! int || (format < 1 || format > 5)) {
      throw const InputException('云端文件版本不受支持，请检查 Dorm 更新');
    }
    final rawTables = value['tables'] as Map<String, dynamic>;
    final wireTables = cloudTables.where((table) => table.inFormat(format));
    if (rawTables.length != wireTables.length) {
      throw const InputException('云端文件表结构不完整');
    }
    final tables = <String, CloudRows>{};
    final syncId = RegExp(r'^[a-f0-9]{32}$');
    for (final table in wireTables) {
      final rows = rawTables[table.name];
      final columns = table.wireColumns(format);
      if (rows is! Map<String, dynamic>) {
        throw const InputException('云端文件表结构不完整');
      }
      final decoded = <String, CloudRow>{};
      for (final entry in rows.entries) {
        final row = entry.value;
        if (row is! Map<String, dynamic> ||
            row.length != columns.length ||
            !columns.every(row.containsKey) ||
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
          if (value == null && table.nullableReferences.contains(column)) {
            continue;
          }
          if (value is! String || !syncId.hasMatch(value)) {
            throw InputException('云端${table.label}的关联记录格式不正确');
          }
        }
        for (final column in table.columns.where(
          (column) => column == 'day' || column.endsWith('_day'),
        )) {
          final value = row[column];
          if (value == null && column == 'due_day') continue;
          if (value is! String ||
              !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
              DateTime.tryParse(value)?.toIso8601String().startsWith(value) !=
                  true) {
            throw InputException('云端${table.label}的日期格式不正确');
          }
        }
        if (format >= 2 && table.name == 'shares') {
          final amount = row['amount'];
          final personal = row['personal_amount'];
          if (amount is! int ||
              personal is! int ||
              personal < 0 ||
              personal > amount) {
            throw const InputException('云端账单的个人费用无效');
          }
        }
        if (format >= 4 &&
            table.name == 'bills' &&
            row['deleted'] != 0 &&
            row['deleted'] != 1) {
          throw const InputException('云端账单的删除标记无效');
        }
        final batch = row['batch_id'];
        if (table.name == 'transfers' && batch != null) {
          if (batch is! String || !syncId.hasMatch(batch)) {
            throw const InputException('云端批量结算标识无效');
          }
        }
        if (format >= 5) _validateIdentityFields(table, row);
        decoded[entry.key] = row;
      }
      tables[table.name] = decoded;
    }
    return CloudSnapshot(tables);
  }

  final Map<String, CloudRows> tables;

  late final String encoded = _encode();

  String _encode() {
    final hasNewRecords =
        tables['matters']!.isNotEmpty ||
        tables['transfers']!.values.any((row) => row['batch_id'] != null);
    final hasPersonal = tables['shares']!.values.any(
      (row) => row['personal_amount'] != 0,
    );
    final hasDeletedBills = tables['bills']!.values.any(
      (row) => row['deleted'] != 0,
    );
    final hasIdentityData =
        tables['identity_claims']!.isNotEmpty ||
        tables['audit_entries']!.isNotEmpty ||
        tables['members']!.values.any((row) => row['avatar'] != null) ||
        tables['bills']!.values.any((row) => row['edit_version'] != null) ||
        tables['shares']!.values.any((row) => row['shared'] != null);
    final format = hasIdentityData
        ? 5
        : (hasDeletedBills ? 4 : (hasNewRecords ? 3 : (hasPersonal ? 2 : 1)));
    final encoder = format >= 5
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    return encoder.convert({
      'format': format,
      'tables': {
        for (final table in cloudTables)
          if (table.inFormat(format))
            table.name: {
              for (final entry in tables[table.name]!.entries)
                entry.key: {
                  for (final column in table.wireColumns(format))
                    column: entry.value[column],
                },
            },
      },
    });
  }

  /// Keeps both devices' permanent audit events and claim history even when
  /// the user chooses a complete version of the business data.
  CloudSnapshot withIdentityHistory(CloudSnapshot local, CloudSnapshot remote) {
    final claims = _reconcileClaims(
      local.tables['identity_claims']!,
      remote.tables['identity_claims']!,
    );
    for (final entry in claims.entries.toList()) {
      if (entry.value['state'] == ClaimState.active.index &&
          tables['members']![entry.value['member_key']]?['active'] != 1) {
        claims[entry.key] = {
          ...entry.value,
          'state': ClaimState.released.index,
        };
      }
    }
    final events = <String, CloudRow>{...local.tables['audit_entries']!};
    for (final entry in remote.tables['audit_entries']!.entries) {
      final previous = events[entry.key];
      if (previous != null && jsonEncode(previous) != jsonEncode(entry.value)) {
        throw const InputException('同一条操作日志有不同内容，无法确认设备记录');
      }
      events[entry.key] = entry.value;
    }
    return CloudSnapshot({
      ...tables,
      'identity_claims': claims,
      'audit_entries': events,
    });
  }

  CloudSnapshot withClaimConflicts(CloudSnapshot other) {
    final claims = _reconcileClaims(
      tables['identity_claims']!,
      other.tables['identity_claims']!,
    );
    return CloudSnapshot({
      ...tables,
      'identity_claims': {
        ...tables['identity_claims']!,
        for (final entry in claims.entries)
          if (entry.value['state'] == ClaimState.conflict.index)
            entry.key: entry.value,
      },
    });
  }

  bool sameBusinessData(CloudSnapshot other) => cloudTables
      .where((table) => !_isHistoryTable(table.name))
      .every(
        (table) =>
            jsonEncode(tables[table.name]) ==
            jsonEncode(other.tables[table.name]),
      );

  bool get hasBusinessData => cloudTables.any(
    (table) => !_isHistoryTable(table.name) && tables[table.name]!.isNotEmpty,
  );

  bool get isEmpty => tables.values.every((rows) => rows.isEmpty);
  bool sameAs(CloudSnapshot other) => encoded == other.encoded;
}

CloudRows _reconcileClaims(CloudRows local, CloudRows remote) {
  final claims = _mergeClaimRows(local, remote);
  final open = claims.entries
      .where((entry) => entry.value['state'] == ClaimState.active.index)
      .toList();
  final byMember = <Object?, int>{};
  final byDevice = <Object?, int>{};
  for (final entry in open) {
    byMember.update(
      entry.value['member_key'],
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    byDevice.update(
      entry.value['device_code'],
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  for (final entry in open) {
    final memberKey = entry.value['member_key'];
    final deviceCode = entry.value['device_code'];
    if (byMember[memberKey]! > 1 || byDevice[deviceCode]! > 1) {
      claims[entry.key] = {...entry.value, 'state': ClaimState.conflict.index};
    }
  }
  return claims;
}

void _validateIdentityFields(CloudTable table, CloudRow row) {
  switch (table.name) {
    case 'members':
      final avatar = row['avatar'];
      if (avatar != null) {
        if (avatar is! String) throw const InputException('云端头像格式不正确');
        decodeAvatar(avatar);
      }
    case 'bills':
      final version = row['edit_version'];
      if (version != null && !isIdentityCode(version)) {
        throw const InputException('云端账单版本无效');
      }
    case 'shares':
      if (![null, 0, 1].contains(row['shared'])) {
        throw const InputException('云端公共分摊标记无效');
      }
    case 'identity_claims':
      if (!isIdentityCode(row['member_key']) ||
          !isIdentityCode(row['device_code']) ||
          !ClaimState.values.any((state) => state.index == row['state']) ||
          !_validTimestamp(row['created_at'])) {
        throw const InputException('云端成员认领记录无效');
      }
    case 'audit_entries':
      final detail = row['detail'];
      if (!isIdentityCode(row['target_key']) ||
          !isIdentityCode(row['device_code']) ||
          (row['claim_key'] != null && !isIdentityCode(row['claim_key'])) ||
          !AuditTarget.values.any(
            (target) => target.name == row['target_kind'],
          ) ||
          !AuditAction.values.any((action) => action.name == row['action']) ||
          !_validTimestamp(row['created_at']) ||
          detail is! String ||
          detail.length > 2048) {
        throw const InputException('云端操作日志格式无效');
      }
  }
}

bool _validTimestamp(Object? value) =>
    value is String && DateTime.tryParse(value) != null;

bool _isHistoryTable(String name) =>
    name == 'identity_claims' || name == 'audit_entries';

CloudRows _mergeClaimRows(CloudRows local, CloudRows remote) {
  final result = <String, CloudRow>{...local};
  for (final entry in remote.entries) {
    final prior = result[entry.key];
    final row = entry.value;
    if (prior == null) {
      result[entry.key] = row;
      continue;
    }
    if (row.keys.any(
      (column) => column != 'state' && row[column] != prior[column],
    )) {
      throw const InputException('同一条认领记录对应不同设备或成员');
    }
    if ((row['state'] as int) > (prior['state'] as int)) {
      result[entry.key] = row;
    }
  }
  return result;
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
    final bills = cloudTables.firstWhere((table) => table.name == 'bills');
    final baseVersions = _billVersions(base);
    final localVersions = _billVersions(local);
    final remoteVersions = _billVersions(remote);
    for (final key in {...localVersions.keys, ...remoteVersions.keys}) {
      final original = baseVersions[key];
      final here = localVersions[key];
      final there = remoteVersions[key];
      if (here != there && here != original && there != original) {
        _billConflicts.add(key);
        conflicts.add((
          table: bills,
          key: key,
          base: base.tables['bills']![key],
          local: local.tables['bills']![key],
          remote: remote.tables['bills']![key],
        ));
      }
    }
    for (final table in cloudTables.where(
      (table) => !_isHistoryTable(table.name),
    )) {
      final baseRows = base.tables[table.name]!;
      final localRows = local.tables[table.name]!;
      final remoteRows = remote.tables[table.name]!;
      final result = _merged[table.name] = {};
      for (final key in {
        ...baseRows.keys,
        ...localRows.keys,
        ...remoteRows.keys,
      }) {
        if ((table.name == 'bills' && _billConflicts.contains(key)) ||
            (table.name == 'shares' &&
                _billConflicts.contains(key.split('/').first))) {
          continue;
        }
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
  final _billConflicts = <String>{};

  static Map<String, String> _billVersions(CloudSnapshot snapshot) {
    final shares = <Object?, List<CloudRow>>{};
    for (final row in snapshot.tables['shares']!.values) {
      shares.putIfAbsent(row['bill_id'], () => []).add(row);
    }
    return {
      for (final entry in snapshot.tables['bills']!.entries)
        entry.key: jsonEncode([entry.value, shares[entry.key]]),
    };
  }

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
      if (conflict.table.name == 'bills' &&
          _billConflicts.contains(conflict.key)) {
        final snapshot = choice == CloudSide.local ? local : remote;
        result['shares']!.addEntries(
          snapshot.tables['shares']!.entries.where(
            (entry) => entry.value['bill_id'] == conflict.key,
          ),
        );
      }
    }
    return CloudSnapshot(result).withIdentityHistory(local, remote);
  }

  static bool _sameRow(CloudRow? a, CloudRow? b) =>
      jsonEncode(a) == jsonEncode(b);
}

abstract interface class CloudStore {
  CloudSettings? get settings;
  void saveSettings(CloudSettings? settings);
  CloudSnapshot? get base;
  CloudSnapshot snapshot();
  void accept(CloudSnapshot data, CloudSnapshot? base);
  void rememberBase(CloudSnapshot base);
}
