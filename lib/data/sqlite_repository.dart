import 'package:sqlite3/sqlite3.dart';

import '../domain/cloud.dart';
import '../domain/ledger.dart';
import '../domain/models.dart';
import '../domain/repository.dart';
import '../domain/schedule.dart';
import 'schema.dart';

part 'sqlite_cloud.dart';

class SqliteDormRepository implements DormRepository {
  SqliteDormRepository._(this._db);

  factory SqliteDormRepository.open(String path) {
    final repo = SqliteDormRepository._(sqlite3.open(path));
    try {
      repo._db.execute('PRAGMA busy_timeout = 2000');
      repo._db.execute('PRAGMA foreign_keys = ON');
      repo._transaction(() {
        final version = repo._db
            .select('PRAGMA user_version')
            .single['user_version'];
        if (version == 0) {
          for (final statement in schema) {
            repo._db.execute(statement);
          }
        } else if (version != 1 && version != 2 && version != 3) {
          throw const InputException('数据库版本较新，请升级 DormOS 后重试');
        }
        if (version == 0 || version == 1) {
          _SqliteCloudStore.migrate(repo._db);
        }
        if (version != 3) {
          repo._db.execute(
            'ALTER TABLE cloud_settings ADD COLUMN use_device_key '
            'INTEGER NOT NULL DEFAULT 0 CHECK(use_device_key IN (0, 1))',
          );
          repo._db.execute('PRAGMA user_version = 3');
        }
      });
      return repo;
    } catch (_) {
      repo.close();
      rethrow;
    }
  }

  final Database _db;

  CloudStore get cloud => _SqliteCloudStore(this);

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

  String _timestamp() => DateTime.now().toUtc().toIso8601String();

  void _requireActiveMember(int id) {
    _requireRow('SELECT id FROM members WHERE id = ? AND active = 1', [
      id,
    ], '所选成员已停用或不存在');
  }

  @override
  List<Member> members() => [
    for (final row in _db.select(
      'SELECT * FROM members ORDER BY active DESC, id',
    ))
      (
        id: row['id'] as int,
        name: row['name'] as String,
        active: row['active'] == 1,
      ),
  ];

  @override
  void saveMember(String name, {int? id}) {
    final cleaned = _required(name, '成员姓名', 40);
    _transaction(() {
      final duplicates = _db.select(
        'SELECT id FROM members WHERE name = ? AND id <> ?',
        [cleaned, id ?? 0],
      );
      if (duplicates.isNotEmpty) throw const InputException('这个成员姓名已存在');
      if (id == null) {
        _db.execute('INSERT INTO members (name) VALUES (?)', [cleaned]);
      } else {
        _db.execute('UPDATE members SET name = ? WHERE id = ?', [cleaned, id]);
        _requireUpdate('成员不存在');
      }
    });
  }

  @override
  void setMemberActive(int id, bool active) {
    _transaction(() {
      final member = _requireRow('SELECT active FROM members WHERE id = ?', [
        id,
      ], '成员不存在');
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
      _db.execute('UPDATE members SET active = ? WHERE id = ?', [
        active ? 1 : 0,
        id,
      ]);
    });
  }

  static const _billQuery = '''SELECT b.*, m.name AS payer,
    COALESCE((SELECT SUM(o.outstanding) FROM obligations o WHERE o.bill_id = b.id), 0) AS outstanding
    FROM bills b JOIN members m ON m.id = b.payer_id''';

  Bill _bill(Row row) => (
    id: row['id'] as int,
    title: row['title'] as String,
    total: row['total'] as int,
    payerId: row['payer_id'] as int,
    payer: row['payer'] as String,
    createdAt: row['created_at'] as String,
    supplyName: row['supply_name'] as String?,
    outstanding: row['outstanding'] as int,
  );

  @override
  List<Bill> bills({int? supplyId}) {
    final filter = supplyId == null ? '' : 'WHERE b.supply_id = ?';
    return _db
        .select('$_billQuery $filter ORDER BY b.created_at DESC, b.id DESC', [
          ?supplyId,
        ])
        .map(_bill)
        .toList();
  }

  @override
  BillDetail billDetail(int id) {
    final bill = _bill(
      _requireRow('$_billQuery WHERE b.id = ?', [id], '账单不存在'),
    );
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
      shares: [
        for (final row in shares)
          (
            memberId: row['member_id'] as int,
            member: row['name'] as String,
            amount: row['amount'] as int,
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
      '''WITH movements AS (
      SELECT payer_id AS member_id, amount AS receivable, 0 AS payable,
        outstanding AS open_receivable, 0 AS open_payable FROM obligations
      UNION ALL
      SELECT member_id, 0, amount, 0, outstanding FROM obligations
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
  int addBill(BillDraft draft) {
    final title = _required(draft.title, '账单名称');
    final shares = splitEvenly(draft.total, draft.participantIds);
    return _transaction(() {
      _requireActiveMember(draft.payerId);
      for (final memberId in shares.keys) {
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
          draft.total,
          draft.payerId,
          _timestamp(),
          supplyId,
          supply?['name'],
        ],
      );
      final billId = _db.lastInsertRowId;
      for (final entry in shares.entries) {
        _db.execute(
          'INSERT INTO shares (bill_id,member_id,amount) VALUES (?,?,?)',
          [billId, entry.key, entry.value],
        );
      }
      if (supplyId != null) {
        _db.execute(
          "UPDATE supplies SET status = 'ordered' WHERE id = ? AND status = 'needed'",
          [supplyId],
        );
      }
      return billId;
    });
  }

  @override
  void recordTransfer(int billId, int memberId, int amount) {
    if (amount <= 0) throw const InputException('转账金额必须大于零');
    _transaction(() {
      final obligation = _requireRow(
        'SELECT outstanding FROM obligations WHERE bill_id = ? AND member_id = ?',
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
    });
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
        draft.quantity > 999999 ||
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
  void close() => _db.close();
}
