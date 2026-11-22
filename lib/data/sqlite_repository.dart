import 'package:sqlite3/sqlite3.dart';

import '../domain/cloud.dart';
import '../domain/identity.dart';
import '../domain/ledger.dart';
import '../domain/matters.dart';
import '../domain/models.dart';
import '../domain/preferences.dart';
import '../domain/repository.dart';
import '../domain/schedule.dart';
import '../domain/settlement.dart';
import 'schema.dart';

part 'sqlite_cloud.dart';
part 'sqlite_identity.dart';

class SqliteDormRepository with _SqliteIdentity implements DormRepository {
  SqliteDormRepository._(this._db, this._path);

  factory SqliteDormRepository.open(String path) {
    final repo = SqliteDormRepository._(sqlite3.open(path), path);
    try {
      repo._db.execute('PRAGMA busy_timeout = 2000');
      repo._db.execute('PRAGMA foreign_keys = ON');
      repo._migrate();
      return repo;
    } catch (_) {
      repo.close();
      rethrow;
    }
  }

  @override
  final Database _db;
  final String _path;
  @override
  late final String deviceCode = _installationCode(_path);

  static const _currentSchemaVersion = 7;

  int get _schemaVersion =>
      _db.select('PRAGMA user_version').single['user_version'] as int;

  void _migrate() {
    if (_schemaVersion == _currentSchemaVersion) return;
    _transaction(() {
      final version = _schemaVersion;
      if (version == _currentSchemaVersion) return;
      if (version == 0) {
        for (final statement in schema) {
          _db.execute(statement);
        }
      } else if (version < 0 || version > _currentSchemaVersion) {
        throw const InputException('数据库版本较新，请升级 Dorm 后重试');
      }
      if (version == 0 || version == 1) {
        _SqliteCloudStore.migrate(_db);
      }
      if (version < 3) {
        _db.execute(
          'ALTER TABLE cloud_settings ADD COLUMN use_device_key '
          'INTEGER NOT NULL DEFAULT 0 CHECK(use_device_key IN (0, 1))',
        );
      }
      if (version < 4) {
        _db.execute(
          'ALTER TABLE shares ADD COLUMN personal_amount '
          'INTEGER NOT NULL DEFAULT 0 CHECK(personal_amount BETWEEN 0 AND amount)',
        );
      }
      if (version < 5) {
        _db.execute(
          "ALTER TABLE transfers ADD COLUMN batch_id TEXT "
          "CHECK(batch_id IS NULL OR (length(batch_id)=32 AND batch_id NOT GLOB '*[^a-f0-9]*'))",
        );
        _db.execute(
          'CREATE INDEX transfers_batch ON transfers(batch_id) WHERE batch_id IS NOT NULL',
        );
        _db.execute(mattersSchema);
        _SqliteCloudStore.addSyncIds(_db, 'matters');
      }
      if (version < 6) {
        _db.execute(
          'ALTER TABLE bills ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0 '
          'CHECK(deleted IN (0, 1))',
        );
      }
      if (version < 7) {
        for (final statement in identitySchema) {
          _db.execute(statement);
        }
        _SqliteCloudStore.addSyncIds(_db, 'identity_claims');
        _SqliteCloudStore.addSyncIds(_db, 'audit_entries');
      }
      _db.execute(
        'CREATE TABLE IF NOT EXISTS local_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT',
      );
      _db.execute('PRAGMA user_version = $_currentSchemaVersion');
    });
  }

  CloudStore get cloud => _SqliteCloudStore(this);

  @override
  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Row _requireRow(String sql, List<Object?> parameters, String message) {
    final rows = _db.select(sql, parameters);
    if (rows.isEmpty) throw InputException(message);
    return rows.single;
  }

  void _requireUpdate(String message) {
    if (_db.updatedRows != 1) throw InputException(message);
  }

  String _required(String value, String label, [int limit = 80]) {
    final cleaned = value.trim();
    if (cleaned.isEmpty || cleaned.runes.length > limit) {
      throw InputException('$label须为 1 至 $limit 个字');
    }
    return cleaned;
  }

  @override
  String _timestamp() => DateTime.now().toUtc().toIso8601String();

  void _requireActiveMember(int id) {
    _requireRow('SELECT id FROM members WHERE id = ? AND active = 1', [
      id,
    ], '所选成员已停用或不存在');
  }

  @override
  List<Member> members() => [
    for (final row in _db.select('''SELECT m.*, c.device_code FROM members m
      LEFT JOIN identity_claims c ON c.member_key=m.sync_id AND c.state=0
      ORDER BY m.active DESC, m.id'''))
      (
        id: row['id'] as int,
        name: row['name'] as String,
        active: row['active'] == 1,
        identityCode: row['sync_id'] as String,
        avatar: row['avatar'] as String?,
        deviceCode: row['device_code'] as String?,
      ),
  ];

  @override
  void saveMember(
    String name, {
    int? id,
    String? avatar,
    bool clearAvatar = false,
    String? expectedIdentityCode,
  }) {
    if (avatar != null) decodeAvatar(avatar);
    final cleaned = _required(name, '成员姓名', 40);
    _transaction(() {
      final duplicates = _db.select(
        'SELECT id FROM members WHERE name = ? AND id <> ?',
        [cleaned, id ?? 0],
      );
      if (duplicates.isNotEmpty) throw const InputException('这个成员姓名已存在');
      if (id == null) {
        _db.execute('INSERT INTO members (name,avatar) VALUES (?,?)', [
          cleaned,
          avatar,
        ]);
        _audit(
          AuditTarget.member,
          _db.lastInsertRowId,
          AuditAction.create,
          '添加成员',
        );
      } else {
        final old = _requireRow(
          'SELECT name,avatar,sync_id FROM members WHERE id=?',
          [id],
          '成员不存在',
        );
        if (expectedIdentityCode != null &&
            old['sync_id'] != expectedIdentityCode) {
          throw const InputException('成员记录已变化，请重新打开后编辑');
        }
        final nextAvatar = clearAvatar ? null : avatar ?? old['avatar'];
        final changes = [
          if (old['name'] != cleaned) '姓名 ${old['name']} → $cleaned',
          if (old['avatar'] != nextAvatar)
            (nextAvatar == null ? '恢复默认头像' : '更换头像'),
        ];
        if (changes.isEmpty) return;
        _db.execute('UPDATE members SET name=?,avatar=? WHERE id=?', [
          cleaned,
          nextAvatar,
          id,
        ]);
        _audit(AuditTarget.member, id, AuditAction.update, changes.join(' · '));
      }
    });
  }

  @override
  void setMemberActive(int id, bool active) {
    _transaction(() {
      final member = _requireRow(
        'SELECT active,sync_id FROM members WHERE id = ?',
        [id],
        '成员不存在',
      );
      if (!active &&
          member['active'] == 1 &&
          _db
              .select('SELECT id FROM chores WHERE active = 1 LIMIT 1')
              .isNotEmpty &&
          _db.select(
            'SELECT id FROM members WHERE active = 1 AND id <> ? LIMIT 1',
            [id],
          ).isEmpty) {
        throw const InputException('有启用的卫生任务，至少保留一位在用成员');
      }
      if ((member['active'] == 1) == active) return;
      _db.execute('UPDATE members SET active = ? WHERE id = ?', [
        active ? 1 : 0,
        id,
      ]);
      _audit(
        AuditTarget.member,
        id,
        AuditAction.update,
        active ? '启用成员' : '停用成员',
      );
      if (!active) {
        _db.execute(
          'UPDATE identity_claims SET state=1 WHERE member_key=? AND state=0',
          [member['sync_id']],
        );
      }
    });
  }

  @override
  void deleteMember(int id) => _transaction(() {
    final member = _requireRow('SELECT id, sync_id FROM members WHERE id = ?', [
      id,
    ], '成员不存在');
    if (_db
            .select('SELECT id FROM chores WHERE active = 1 LIMIT 1')
            .isNotEmpty &&
        _db.select(
          'SELECT id FROM members WHERE active = 1 AND id <> ? LIMIT 1',
          [id],
        ).isEmpty) {
      throw const InputException('有启用的卫生任务，至少保留一位在用成员');
    }
    final hasActiveBills = _db
        .select(
          '''SELECT 1 FROM bills WHERE payer_id = ? AND deleted = 0
      UNION ALL
      SELECT 1 FROM shares s JOIN bills b ON b.id = s.bill_id
      WHERE s.member_id = ? AND b.deleted = 0 LIMIT 1''',
          [id, id],
        )
        .isNotEmpty;
    if (hasActiveBills) {
      throw const InputException('该成员仍有未删除的账单记录，无法删除；请先删除相关账单，或改用「停用成员」');
    }
    if (_db.select(
      'SELECT 1 FROM shifts WHERE member_id = ? AND completed_at IS NOT NULL LIMIT 1',
      [id],
    ).isNotEmpty) {
      throw const InputException('该成员已有已打卡的卫生记录，无法删除；若不再参与后续排班，请改用「停用成员」');
    }

    // Purge tombstoned (deleted = 1) bills referencing this member so SQLite FKs
    // and CloudSnapshot share-sum invariants stay consistent.
    final deletedBills = _db.select(
      '''SELECT DISTINCT b.id, b.sync_id FROM bills b
      LEFT JOIN shares s ON s.bill_id = b.id
      WHERE b.deleted = 1 AND (b.payer_id = ? OR s.member_id = ?)''',
      [id, id],
    );
    for (final bill in deletedBills) {
      final billId = bill['id'] as int;
      final billSyncId = bill['sync_id'] as String?;
      _db.execute('DELETE FROM transfers WHERE bill_id = ?', [billId]);
      _db.execute('DELETE FROM shares WHERE bill_id = ?', [billId]);
      if (billSyncId != null) {
        _db.execute(
          "DELETE FROM audit_entries WHERE target_kind = 'bill' AND target_key = ?",
          [billSyncId],
        );
      }
      _db.execute('DELETE FROM bills WHERE id = ?', [billId]);
    }

    _db.execute(
      'DELETE FROM shifts WHERE member_id = ? AND completed_at IS NULL',
      [id],
    );
    _db.execute('UPDATE matters SET owner_id = NULL WHERE owner_id = ?', [id]);
    _db.execute(
      'UPDATE chores SET last_member_id = NULL WHERE last_member_id = ?',
      [id],
    );
    final syncId = member['sync_id'] as String;
    _db.execute('DELETE FROM identity_claims WHERE member_key = ?', [syncId]);
    _db.execute(
      "DELETE FROM audit_entries WHERE target_kind = 'member' AND target_key = ?",
      [syncId],
    );
    _db.execute('DELETE FROM members WHERE id = ?', [id]);
  });

  static const _billQuery = '''SELECT b.*, m.name AS payer,
    COALESCE((SELECT SUM(o.outstanding) FROM obligations o WHERE o.bill_id = b.id), 0) AS outstanding,
    COALESCE((SELECT SUM(s.personal_amount) FROM shares s WHERE s.bill_id = b.id), 0) AS personal_amount
    FROM bills b JOIN members m ON m.id = b.payer_id WHERE b.deleted = 0''';

  Bill _bill(Row row) => (
    id: row['id'] as int,
    title: row['title'] as String,
    total: row['total'] as int,
    payerId: row['payer_id'] as int,
    payer: row['payer'] as String,
    createdAt: row['created_at'] as String,
    supplyName: row['supply_name'] as String?,
    outstanding: row['outstanding'] as int,
    personalAmount: row['personal_amount'] as int,
  );

  @override
  List<Bill> bills({int? supplyId}) {
    final filter = supplyId == null ? '' : 'AND b.supply_id = ?';
    return _db
        .select('$_billQuery $filter ORDER BY b.created_at DESC, b.id DESC', [
          ?supplyId,
        ])
        .map(_bill)
        .toList();
  }

  @override
  BillDetail billDetail(int id) {
    final row = _requireRow('$_billQuery AND b.id = ?', [id], '账单不存在或已删除');
    final bill = _bill(row);
    final shares = _db.select(
      '''SELECT s.*, m.name,
      COALESCE((SELECT SUM(t.amount) FROM transfers t WHERE t.bill_id = s.bill_id AND t.member_id = s.member_id), 0) AS paid
      FROM shares s JOIN members m ON m.id = s.member_id WHERE s.bill_id = ? ORDER BY s.member_id''',
      [id],
    );
    final transfers = _db.select(
      '''SELECT m.name, t.amount, t.created_at FROM transfers t
      JOIN members m ON m.id = t.member_id WHERE t.bill_id = ? ORDER BY t.created_at DESC, t.id DESC''',
      [id],
    );
    return (
      bill: bill,
      version: _billVersion(row),
      participants: [
        for (final share in shares)
          if (share['shared'] == 1 ||
              (share['shared'] == null &&
                  ((share['personal_amount'] as int) == 0 ||
                      (share['amount'] as int) >
                          (share['personal_amount'] as int))))
            share['member_id'] as int,
      ],
      activity: _activity(AuditTarget.bill, id),
      shares: [
        for (final row in shares)
          (
            memberId: row['member_id'] as int,
            member: row['name'] as String,
            amount: row['amount'] as int,
            personalAmount: row['personal_amount'] as int,
            paid: row['paid'] as int,
          ),
      ],
      transfers: [
        for (final row in transfers)
          (
            member: row['name'] as String,
            amount: row['amount'] as int,
            createdAt: row['created_at'] as String,
          ),
      ],
    );
  }

  @override
  List<Balance> balances() {
    final rows = _db.select(
      '''WITH active_obligations AS (
      SELECT o.* FROM obligations o JOIN bills b ON b.id = o.bill_id WHERE b.deleted = 0
    ), movements AS (
      SELECT payer_id AS member_id, amount AS receivable, 0 AS payable,
        outstanding AS open_receivable, 0 AS open_payable FROM active_obligations
      UNION ALL
      SELECT member_id, 0, amount, 0, outstanding FROM active_obligations
    ) SELECT m.name, COALESCE(SUM(receivable), 0) AS receivable,
      COALESCE(SUM(payable), 0) AS payable, COALESCE(SUM(open_receivable), 0) AS open_receivable,
      COALESCE(SUM(open_payable), 0) AS open_payable
    FROM members m LEFT JOIN movements v ON v.member_id = m.id GROUP BY m.id ORDER BY m.active DESC, m.id''',
    );
    return [
      for (final row in rows)
        (
          name: row['name'] as String,
          receivable: row['receivable'] as int,
          payable: row['payable'] as int,
          openReceivable: row['open_receivable'] as int,
          openPayable: row['open_payable'] as int,
        ),
    ];
  }

  @override
  int addBill(BillDraft draft, {String? browserDevice}) {
    final title = _required(draft.title, '账单名称');
    final allocation = allocateBill(
      draft.sharedAmount,
      draft.participantIds,
      draft.personalAmounts,
    );
    return _transaction(() {
      _requireActiveMember(draft.payerId);
      for (final memberId in allocation.shares.keys) {
        _requireActiveMember(memberId);
      }
      final supplyId = draft.supplyId;
      final supply = supplyId == null
          ? null
          : _requireRow(
              'SELECT name FROM supplies WHERE id = ? AND deleted = 0',
              [supplyId],
              '关联物资已删除',
            );
      _db.execute(
        'INSERT INTO bills (title,total,payer_id,created_at,supply_id,supply_name) VALUES (?,?,?,?,?,?)',
        [
          title,
          allocation.total,
          draft.payerId,
          _timestamp(),
          supplyId,
          supply?['name'],
        ],
      );
      final billId = _db.lastInsertRowId;
      _writeShares(billId, draft, allocation.shares);
      _audit(
        AuditTarget.bill,
        billId,
        AuditAction.create,
        '账单合计 ${formatCents(allocation.total)}',
        browserDevice: browserDevice,
      );
      if (supplyId != null) {
        _db.execute(
          "UPDATE supplies SET status = 'ordered' WHERE id = ? AND (status = 'needed' OR ? = 1)",
          [supplyId, draft.markSupplyOrdered ? 1 : 0],
        );
      }
      return billId;
    });
  }

  String _billVersion(Row row) =>
      "${row['sync_id']}/${row['edit_version'] ?? ''}";

  void _writeShares(int billId, BillDraft draft, Map<int, int> shares) {
    final participants = draft.participantIds.toSet();
    for (final entry in shares.entries) {
      _db.execute(
        '''
        INSERT INTO shares (bill_id,member_id,amount,personal_amount,shared)
        VALUES (?,?,?,?,?) ON CONFLICT(bill_id,member_id) DO UPDATE SET
        amount=excluded.amount, personal_amount=excluded.personal_amount, shared=excluded.shared''',
        [
          billId,
          entry.key,
          entry.value,
          draft.personalAmounts[entry.key] ?? 0,
          draft.sharedAmount > 0 && participants.contains(entry.key) ? 1 : 0,
        ],
      );
    }
  }

  @override
  void updateBill(
    int id,
    BillDraft draft, {
    required String expectedVersion,
    String? browserDevice,
  }) {
    final title = _required(draft.title, '账单名称');
    final allocation = allocateBill(
      draft.sharedAmount,
      draft.participantIds,
      draft.personalAmounts,
    );
    _transaction(() {
      final current = billDetail(id);
      if (current.version != expectedVersion) {
        throw const InputException('账单已经更新，请重新打开后编辑');
      }
      final old = current.bill;
      final oldShared = old.total - old.personalAmount;
      final oldParticipants = current.participants.toSet();
      final newParticipants = draft.sharedAmount == 0
          ? <int>{}
          : draft.participantIds.toSet();
      final oldPersonal = {
        for (final share in current.shares)
          if (share.personalAmount != 0) share.memberId: share.personalAmount,
      };
      final changedParticipants =
          oldParticipants.length != newParticipants.length ||
          !oldParticipants.containsAll(newParticipants);
      final changedPersonal =
          oldPersonal.length != draft.personalAmounts.length ||
          draft.personalAmounts.entries.any(
            (entry) => oldPersonal[entry.key] != entry.value,
          );
      final changedPayer = old.payerId != draft.payerId;
      final changedShares =
          oldShared != draft.sharedAmount ||
          changedParticipants ||
          changedPersonal;
      final changes = [
        if (old.title != title) '名称 ${old.title} → $title',
        if (changedPayer) '调整付款人',
        if (oldShared != draft.sharedAmount)
          '公共费用 ${formatCents(oldShared)} → ${formatCents(draft.sharedAmount)}',
        if (changedParticipants) '调整公共费用参与成员',
        if (changedPersonal) '调整个人费用',
        if (old.total != allocation.total)
          '合计 ${formatCents(old.total)} → ${formatCents(allocation.total)}',
      ];
      if (changes.isEmpty) return;

      if (changedPayer) {
        _requireActiveMember(draft.payerId);
        if (current.transfers.isNotEmpty) {
          throw const InputException('已有实际转账，不能更换付款人');
        }
      }
      if (changedShares) {
        final oldIds = {for (final share in current.shares) share.memberId};
        for (final member in allocation.shares.keys.where(
          (id) => !oldIds.contains(id),
        )) {
          _requireActiveMember(member);
        }
        for (final share in current.shares.where((share) => share.paid > 0)) {
          if ((allocation.shares[share.memberId] ?? 0) < share.paid) {
            throw const InputException('新的分摊低于已转账金额，请保留相应成员和足够的金额');
          }
        }
        _writeShares(id, draft, allocation.shares);
        for (final member in oldIds.where(
          (member) => !allocation.shares.containsKey(member),
        )) {
          _db.execute('DELETE FROM shares WHERE bill_id=? AND member_id=?', [
            id,
            member,
          ]);
        }
      }
      _db.execute(
        'UPDATE bills SET title=?,total=?,payer_id=?,edit_version=? WHERE id=?',
        [title, allocation.total, draft.payerId, newIdentityCode(), id],
      );
      _audit(
        AuditTarget.bill,
        id,
        AuditAction.update,
        changes.join(' · '),
        browserDevice: browserDevice,
      );
    });
  }

  @override
  void deleteBill(int id, {String? browserDevice}) => _transaction(() {
    _db.execute('UPDATE bills SET deleted = 1 WHERE id = ? AND deleted = 0', [
      id,
    ]);
    _requireUpdate('账单不存在或已删除');
    _audit(
      AuditTarget.bill,
      id,
      AuditAction.remove,
      '删除账单',
      browserDevice: browserDevice,
    );
  });

  @override
  void recordTransfer(
    int billId,
    int memberId,
    int amount, {
    String? browserDevice,
  }) {
    if (amount <= 0) throw const InputException('转账金额必须大于零');
    _transaction(() {
      final obligation = _requireRow(
        '''SELECT o.outstanding FROM obligations o JOIN bills b ON b.id = o.bill_id
          WHERE o.bill_id = ? AND o.member_id = ? AND b.deleted = 0''',
        [billId, memberId],
        '这位成员无须向付款人转账',
      );
      if (amount > (obligation['outstanding'] as int)) {
        throw const InputException('转账金额超过当前未结清金额');
      }
      _db.execute(
        'INSERT INTO transfers (bill_id,member_id,amount,created_at) VALUES (?,?,?,?)',
        [billId, memberId, amount, _timestamp()],
      );
      _audit(
        AuditTarget.bill,
        billId,
        AuditAction.transfer,
        '实际转账 ${formatCents(amount)}',
        browserDevice: browserDevice,
      );
    });
  }

  static const _openCharges = '''
    SELECT b.id AS bill_id, b.title, b.created_at, o.outstanding AS amount,
      o.member_id AS debtor_id, debtor.name AS debtor, o.payer_id, payer.name AS payer
    FROM obligations o
    JOIN bills b ON b.id = o.bill_id
    JOIN members debtor ON debtor.id = o.member_id
    JOIN members payer ON payer.id = o.payer_id
    WHERE o.outstanding > 0 AND b.deleted = 0''';

  OpenCharge _charge(Row row) => (
    billId: row['bill_id'] as int,
    title: row['title'] as String,
    createdAt: row['created_at'] as String,
    amount: row['amount'] as int,
  );

  @override
  List<SettlementPair> openSettlements() {
    final pairs = <(int, int), SettlementPair>{};
    for (final row in _db.select(
      '$_openCharges ORDER BY debtor.name, payer.name, b.created_at, b.id',
    )) {
      final direction = (row['debtor_id'] as int, row['payer_id'] as int);
      final pair = pairs.putIfAbsent(
        direction,
        () => (
          debtorId: direction.$1,
          debtor: row['debtor'] as String,
          payerId: direction.$2,
          payer: row['payer'] as String,
          charges: [],
        ),
      );
      pair.charges.add(_charge(row));
    }
    return pairs.values.toList();
  }

  @override
  void recordSettlement(
    int debtorId,
    int payerId,
    Map<int, int> expected,
    int amount,
  ) => _transaction(() {
    if (expected.isEmpty) throw const InputException('至少选择一笔待结清账单');
    final selected = [
      for (final row in _db.select(
        '$_openCharges AND o.member_id=? AND o.payer_id=? ORDER BY b.created_at,b.id',
        [debtorId, payerId],
      ))
        if (expected.containsKey(row['bill_id'])) _charge(row),
    ];
    if (selected.length != expected.length ||
        selected.any((bill) => expected[bill.billId] != bill.amount)) {
      throw const InputException('账单余额已经变化，请关闭并重新选择待结清账单');
    }
    final allocations = allocateSettlement(selected, amount);
    final batch = _db
        .select('SELECT lower(hex(randomblob(16))) AS id')
        .single['id'];
    final time = _timestamp();
    for (final allocation in allocations.entries) {
      _db.execute(
        'INSERT INTO transfers (bill_id,member_id,amount,created_at,batch_id) VALUES (?,?,?,?,?)',
        [allocation.key, debtorId, allocation.value, time, batch],
      );
      _audit(
        AuditTarget.bill,
        allocation.key,
        AuditAction.settlement,
        '入账 ${formatCents(allocation.value)}',
      );
    }
  });

  @override
  List<SettlementBatch> settlementHistory() {
    final batches = <String, SettlementBatch>{};
    for (final row in _db.select('''
      SELECT t.batch_id, t.bill_id, t.amount, t.created_at, b.title,
        debtor.name AS debtor, payer.name AS payer
      FROM transfers t JOIN bills b ON t.bill_id=b.id
      JOIN members debtor ON t.member_id=debtor.id
      JOIN members payer ON b.payer_id=payer.id
      WHERE t.batch_id IS NOT NULL AND b.deleted = 0
      ORDER BY t.created_at DESC, t.batch_id, b.created_at, b.id
    ''')) {
      final id = row['batch_id'] as String;
      final batch = batches.putIfAbsent(
        id,
        () => (
          id: id,
          debtor: row['debtor'] as String,
          payer: row['payer'] as String,
          createdAt: row['created_at'] as String,
          allocations: [],
        ),
      );
      batch.allocations.add(_charge(row));
    }
    return batches.values.toList();
  }

  @override
  List<Matter> matters() => [
    for (final row in _db.select('''
      SELECT t.*, m.name AS owner FROM matters t LEFT JOIN members m ON t.owner_id=m.id
      ORDER BY t.archived, t.urgent DESC, t.due_day IS NULL, t.due_day, t.created_at DESC, t.id DESC
    '''))
      (
        id: row['id'] as int,
        title: row['title'] as String,
        note: row['note'] as String,
        ownerId: row['owner_id'] as int?,
        owner: row['owner'] as String?,
        dueDay: row['due_day'] as String?,
        urgent: row['urgent'] == 1,
        status: MatterStatus.values.byName(row['status'] as String),
        createdAt: row['created_at'] as String,
        completedAt: row['completed_at'] as String?,
        archived: row['archived'] == 1,
      ),
  ];

  @override
  int saveMatter(MatterDraft draft, {int? id}) => _transaction(() {
    final title = _required(draft.title, '事务标题');
    final note = draft.note.trim();
    if (note.runes.length > 600) throw const InputException('事务说明最多 600 字');
    final previous = id == null
        ? null
        : _requireRow(
            'SELECT owner_id FROM matters WHERE id=? AND archived=0',
            [id],
            '事务已归档或不存在',
          );
    final owner = draft.ownerId;
    if (owner != null && owner != previous?['owner_id']) {
      _requireActiveMember(owner);
    }
    final due = draft.due;
    if (due != null && (due.year < 1900 || due.year > 9999)) {
      throw const InputException('请选择有效的截止日期');
    }
    final values = [
      title,
      note,
      owner,
      due == null ? null : dayKey(due),
      draft.urgent ? 1 : 0,
    ];
    if (id == null) {
      _db.execute(
        'INSERT INTO matters (title,note,owner_id,due_day,urgent,created_at) VALUES (?,?,?,?,?,?)',
        [...values, _timestamp()],
      );
      return _db.lastInsertRowId;
    }
    _db.execute(
      'UPDATE matters SET title=?,note=?,owner_id=?,due_day=?,urgent=? WHERE id=?',
      [...values, id],
    );
    return id;
  });

  @override
  void setMatterStatus(int id, MatterStatus status) {
    _db.execute(
      '''
      UPDATE matters SET status=?, completed_at=
        CASE WHEN ?='done' THEN COALESCE(completed_at, ?) ELSE NULL END
      WHERE id=? AND archived=0
    ''',
      [status.name, status.name, _timestamp(), id],
    );
    _requireUpdate('事务已归档或不存在');
  }

  @override
  void archiveMatter(int id, bool archived) {
    _db.execute('UPDATE matters SET archived=? WHERE id=?', [
      archived ? 1 : 0,
      id,
    ]);
    _requireUpdate('事务不存在');
  }

  @override
  List<Chore> chores() => [
    for (final row in _db.select(
      'SELECT id,title,cadence,active FROM chores ORDER BY active DESC,id',
    ))
      (
        id: row['id'] as int,
        title: row['title'] as String,
        cadence: Cadence.values.byName(row['cadence'] as String),
        active: row['active'] == 1,
      ),
  ];

  @override
  void addChore(String title, Cadence cadence, DateTime start) {
    _transaction(() {
      if (_db
          .select('SELECT id FROM members WHERE active = 1 LIMIT 1')
          .isEmpty) {
        throw const InputException('请先添加寝室成员');
      }
      _db.execute(
        'INSERT INTO chores (title,cadence,next_day) VALUES (?,?,?)',
        [_required(title, '任务名称'), cadence.name, dayKey(start)],
      );
    });
  }

  @override
  void renameChore(int id, String title) {
    _db.execute('UPDATE chores SET title = ? WHERE id = ? AND active = 1', [
      _required(title, '任务名称'),
      id,
    ]);
    _requireUpdate('任务已归档或不存在');
  }

  @override
  void archiveChore(int id, DateTime from) {
    _transaction(() {
      _db.execute('UPDATE chores SET active = 0 WHERE id = ? AND active = 1', [
        id,
      ]);
      _requireUpdate('任务已归档或不存在');
      _db.execute(
        'DELETE FROM shifts WHERE task_id = ? AND day >= ? AND completed_at IS NULL',
        [id, dayKey(from)],
      );
    });
  }

  @override
  void generateShiftsThrough(DateTime through) {
    final end = civilDay(through);
    _transaction(() {
      final syncEnabled = _db.select('SELECT 1 FROM cloud_settings').isNotEmpty;
      final members = _db.select(
        'SELECT id, sync_id, active FROM members ORDER BY ${syncEnabled ? 'sync_id' : 'id'}',
      );
      final active = [
        for (final row in members)
          if (row['active'] == 1) row['id'] as int,
      ];
      if (active.isEmpty) return;
      final ranks = {
        for (final (index, row) in members.indexed) row['id'] as int: index,
      };
      final activeRanks = active.map((id) => ranks[id]!).toList();
      final tasks = _db.select(
        'SELECT * FROM chores WHERE active = 1 AND next_day <= ? ORDER BY id',
        [dayKey(end)],
      );
      for (final task in tasks) {
        final taskId = task['id'] as int;
        final cadence = Cadence.values.byName(task['cadence'] as String);
        final start = DateTime.parse('${task['next_day']}T00:00:00Z');
        var day = start;
        var member = task['last_member_id'] as int?;
        while (!day.isAfter(end)) {
          member =
              members[nextAssignee(activeRanks, ranks[member])]['id'] as int;
          _db.execute(
            'INSERT INTO shifts (task_id, day, member_id) VALUES (?,?,?)',
            [taskId, dayKey(day), member],
          );
          day = day.add(Duration(days: cadence.days));
        }
        _db.execute(
          'UPDATE chores SET next_day = ?, last_member_id = ? WHERE id = ?',
          [dayKey(day), member, taskId],
        );
      }
    });
  }

  @override
  List<Shift> shifts(DateTime from, DateTime through) {
    final rows = _db.select(
      '''SELECT s.*, c.title, m.name, m.active FROM shifts s
      JOIN chores c ON c.id = s.task_id JOIN members m ON m.id = s.member_id
      WHERE s.day BETWEEN ? AND ? ORDER BY s.day, s.task_id''',
      [dayKey(from), dayKey(through)],
    );
    return [
      for (final row in rows)
        (
          id: row['id'] as int,
          taskId: row['task_id'] as int,
          title: row['title'] as String,
          day: row['day'] as String,
          memberId: row['member_id'] as int,
          member: row['name'] as String,
          memberActive: row['active'] == 1,
          completedAt: row['completed_at'] as String?,
        ),
    ];
  }

  @override
  void completeShift(int id) {
    _db.execute(
      'UPDATE shifts SET completed_at = ? WHERE id = ? AND completed_at IS NULL AND day <= ?',
      [_timestamp(), id, dayKey(today())],
    );
    _requireUpdate('只可打卡今天或过去的待完成班次');
  }

  @override
  void reassignShift(int id, int memberId) {
    _transaction(() {
      _requireActiveMember(memberId);
      _db.execute(
        'UPDATE shifts SET member_id = ? WHERE id = ? AND completed_at IS NULL',
        [memberId, id],
      );
      _requireUpdate('班次已完成或不存在');
    });
  }

  @override
  void swapShifts(int first, int second) {
    if (first == second) throw const InputException('请选择另一个班次');
    _transaction(() {
      const query =
          'SELECT s.* FROM shifts s JOIN members m ON m.id = s.member_id '
          'WHERE s.id = ? AND s.completed_at IS NULL AND m.active = 1';
      final a = _requireRow(query, [first], '原班次不可交换');
      final b = _requireRow(query, [second], '目标班次不可交换');
      if (a['task_id'] != b['task_id'] || a['member_id'] == b['member_id']) {
        throw const InputException('需选择同任务且由不同成员负责的待完成班次');
      }
      _db.execute('UPDATE shifts SET member_id = ? WHERE id = ?', [
        b['member_id'],
        first,
      ]);
      _db.execute('UPDATE shifts SET member_id = ? WHERE id = ?', [
        a['member_id'],
        second,
      ]);
    });
  }

  @override
  List<Supply> supplies() => [
    for (final row in _db.select(
      'SELECT * FROM supplies WHERE deleted = 0 ORDER BY id DESC',
    ))
      (
        id: row['id'] as int,
        name: row['name'] as String,
        category: row['category'] as String,
        quantity: row['quantity'] as int,
        location: row['location'] as String,
        note: row['note'] as String,
        status: PurchaseStatus.values.byName(row['status'] as String),
      ),
  ];

  @override
  void saveSupply(SupplyDraft draft, {int? id}) {
    if (draft.quantity < 0 ||
        draft.quantity > maxStockQuantity ||
        draft.location.runes.length > 80 ||
        draft.note.runes.length > 500) {
      throw const InputException('请检查库存数量、存放位置或备注长度');
    }
    final values = [
      _required(draft.name, '物资名称'),
      _required(draft.category, '分类标签', 40),
      draft.quantity,
      draft.location.trim(),
      draft.note.trim(),
      draft.status.name,
    ];
    if (id == null) {
      _db.execute(
        'INSERT INTO supplies (name,category,quantity,location,note,status) VALUES (?,?,?,?,?,?)',
        values,
      );
    } else {
      _db.execute(
        'UPDATE supplies SET name=?,category=?,quantity=?,location=?,note=?,status=? WHERE id=? AND deleted=0',
        [...values, id],
      );
      _requireUpdate('物资已删除或不存在');
    }
  }

  @override
  void deleteSupply(int id) {
    _db.execute(
      'UPDATE supplies SET deleted = 1 WHERE id = ? AND deleted = 0',
      [id],
    );
    _requireUpdate('物资已删除或不存在');
  }

  @override
  void markSupplyOrdered(int id) {
    _db.execute(
      "UPDATE supplies SET status='ordered' WHERE id=? AND deleted=0",
      [id],
    );
    _requireUpdate('物资已删除或不存在');
  }

  @override
  void receiveSupply(int id, int units) {
    if (units <= 0 || units > maxStockQuantity) {
      throw const InputException('入库数量必须为 1 至 999999 的整数');
    }
    _db.execute(
      "UPDATE supplies SET quantity=quantity+?, status='stocked' "
      "WHERE id=? AND deleted=0 AND quantity<=?",
      [units, id, maxStockQuantity - units],
    );
    _requireUpdate('物资已删除，或入库后库存将超过 999999');
  }

  @override
  DormPreferences get preferences => DormPreferences.fromValues({
    for (final row in _db.select('SELECT key,value FROM local_preferences'))
      row['key'] as String: row['value'] as String,
  });

  @override
  void savePreferences(DormPreferences preferences) {
    if (preferences.lanPort < 1 || preferences.lanPort > 65535) {
      throw const InputException('请输入 1 至 65535 之间的端口');
    }
    if (preferences.monthlyBudget < 0 ||
        preferences.monthlyBudget > maxAmountCents ||
        preferences.stockThreshold < 0 ||
        preferences.stockThreshold > maxStockQuantity) {
      throw const InputException('月度预算或库存阈值超出范围');
    }
    _transaction(() {
      for (final entry in preferences.toValues().entries) {
        _saveLocalPreference(entry.key, entry.value);
      }
    });
  }

  void _saveLocalPreference(String key, String value) => _db.execute(
    'INSERT INTO local_preferences VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  @override
  AppearanceMode get appearanceMode {
    final value = _db
        .select("SELECT value FROM local_preferences WHERE key = 'appearance'")
        .firstOrNull?['value'];
    return AppearanceMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AppearanceMode.system,
    );
  }

  @override
  void saveAppearanceMode(AppearanceMode mode) =>
      _saveLocalPreference('appearance', mode.name);

  @override
  Future<void> writeBackup(String path) async {
    final copy = sqlite3.open(path);
    try {
      await _db.backup(copy).drain<void>();
      copy.execute('PRAGMA secure_delete = ON');
      copy.execute('DELETE FROM cloud_settings');
      copy.execute(
        "DELETE FROM local_preferences WHERE key IN ('botApiKey', 'botApiEnabled')",
      );
      copy.execute('VACUUM');
    } finally {
      copy.close();
    }
  }

  @override
  void resetFactory({
    bool keepCloudSettings = false,
    bool rememberEmptyCloudBase = false,
  }) => _transaction(() {
    for (final table in cloudTables.reversed) {
      _db.execute('DELETE FROM ${table.name}');
    }
    _db.execute('DELETE FROM local_preferences');
    if (!keepCloudSettings) {
      _db.execute('DELETE FROM cloud_settings');
    } else {
      _db.execute('UPDATE cloud_settings SET base = ? WHERE id = 1', [
        rememberEmptyCloudBase ? CloudSnapshot({}).encoded : null,
      ]);
    }
  });

  @override
  void close() => _db.close();
}
