part of 'sqlite_repository.dart';

class _SqliteCloudStore implements CloudStore {
  _SqliteCloudStore(this.repository);

  final SqliteDormRepository repository;
  Database get _db => repository._db;

  static void migrate(Database db) {
    for (final table in cloudTables.where((table) => table.hasSyncId)) {
      final name = table.name;
      db.execute('ALTER TABLE $name ADD COLUMN sync_id TEXT');
      db.execute('UPDATE $name SET sync_id = lower(hex(randomblob(16)))');
      db.execute('CREATE UNIQUE INDEX ${name}_sync_id ON $name(sync_id)');
      db.execute('''CREATE TRIGGER ${name}_assign_sync_id AFTER INSERT ON $name
        WHEN NEW.sync_id IS NULL BEGIN
          UPDATE $name SET sync_id = lower(hex(randomblob(16))) WHERE id = NEW.id;
        END''');
    }
    db.execute('''CREATE TABLE cloud_settings (
      id INTEGER PRIMARY KEY CHECK(id = 1), repository TEXT NOT NULL,
      operator TEXT NOT NULL, email TEXT NOT NULL, base TEXT
    ) STRICT''');
  }

  @override
  CloudSettings? get settings {
    final row = _db
        .select('SELECT repository, operator, email FROM cloud_settings')
        .firstOrNull;
    return row == null
        ? null
        : CloudSettings(
            repository: row['repository'] as String,
            operator: row['operator'] as String,
            email: row['email'] as String,
          );
  }

  @override
  void saveSettings(CloudSettings? settings) {
    if (settings == null) {
      _db.execute('DELETE FROM cloud_settings');
    } else {
      _db.execute(
        '''INSERT INTO cloud_settings (id, repository, operator, email) VALUES (1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET base = CASE WHEN repository = excluded.repository THEN base END,
          repository = excluded.repository, operator = excluded.operator, email = excluded.email''',
        [settings.repository, settings.operator, settings.email],
      );
    }
  }

  @override
  CloudSnapshot? get base {
    final value = _db
        .select('SELECT base FROM cloud_settings')
        .firstOrNull?['base'];
    return value is String ? CloudSnapshot.decode(value) : null;
  }

  @override
  void rememberBase(CloudSnapshot base) => _db.execute(
    'UPDATE cloud_settings SET base = ? WHERE id = 1',
    [base.encoded],
  );

  @override
  CloudSnapshot snapshot() => repository._transaction(() {
    final ids = <String, Map<int, String>>{};
    final data = <String, CloudRows>{};
    for (final table in cloudTables) {
      final rows = _db.select('SELECT * FROM ${table.name}');
      if (table.hasSyncId) {
        ids[table.name] = {
          for (final row in rows) row['id'] as int: row['sync_id'] as String,
        };
      }
      final exported = data[table.name] = {};
      for (final row in rows) {
        final values = <String, Object?>{
          for (final column in table.columns)
            column: table.references.containsKey(column)
                ? ids[table.references[column]]![row[column]]
                : row[column],
        };
        exported[table.hasSyncId
                ? row['sync_id'] as String
                : table.keyOf(values)] =
            values;
      }
    }
    return CloudSnapshot(data);
  });

  @override
  void accept(
    CloudSnapshot data,
    CloudSnapshot base,
  ) => repository._transaction(() {
    final ids = <String, Map<String, int>>{};
    final shiftIds = <String, int>{};
    for (final table in cloudTables.where((table) => table.hasSyncId)) {
      final existing = _db.select(
        'SELECT id, sync_id FROM ${table.name} ORDER BY id',
      );
      final previous = {
        for (final row in existing) row['sync_id'] as String: row['id'] as int,
      };
      var next = existing.lastOrNull?['id'] as int? ?? 0;
      ids[table.name] = {
        for (final id in data.tables[table.name]!.keys)
          id: previous[id] ?? ++next,
      };
    }
    final shifts = _db.select(
      '''SELECT shifts.id, chores.sync_id, shifts.day FROM shifts
      JOIN chores ON chores.id = shifts.task_id ORDER BY shifts.id''',
    );
    final existingShifts = {
      for (final row in shifts)
        '${row['sync_id']}/${row['day']}': row['id'] as int,
    };
    var nextShift = shifts.lastOrNull?['id'] as int? ?? 0;
    for (final key in data.tables['shifts']!.keys) {
      shiftIds[key] = existingShifts[key] ?? ++nextShift;
    }
    for (final table in cloudTables.reversed) {
      _db.execute('DELETE FROM ${table.name}');
    }
    for (final table in cloudTables) {
      final columns = [
        if (table.hasSyncId || table.name == 'shifts') 'id',
        if (table.hasSyncId) 'sync_id',
        ...table.columns,
      ];
      final statement = _db.prepare(
        'INSERT INTO ${table.name} (${columns.join(',')}) VALUES (${List.filled(columns.length, '?').join(',')})',
      );
      try {
        for (final entry in data.tables[table.name]!.entries) {
          final values = <Object?>[
            if (table.hasSyncId) ...[
              ids[table.name]![entry.key],
              entry.key,
            ] else if (table.name == 'shifts')
              shiftIds[entry.key],
          ];
          for (final column in table.columns) {
            final target = table.references[column];
            final value = entry.value[column];
            if (target != null && value != null) {
              final id = ids[target]![value];
              if (id == null) throw InputException('${table.label}引用的记录不存在');
              values.add(id);
            } else {
              if (value != null &&
                  (column.endsWith('_at') ||
                      column == 'day' ||
                      column == 'next_day') &&
                  (value is! String || DateTime.tryParse(value) == null)) {
                throw InputException('${table.label}的日期格式不正确');
              }
              values.add(value);
            }
          }
          statement.execute(values);
        }
      } finally {
        statement.close();
      }
    }
    if (_db.select(
      '''SELECT b.id FROM bills b LEFT JOIN shares s ON b.id = s.bill_id
      GROUP BY b.id HAVING COALESCE(SUM(s.amount), 0) != b.total LIMIT 1''',
    ).isNotEmpty) {
      throw const InputException('合并后的账单金额与分摊合计不一致');
    }
    if (_db
            .select('SELECT 1 FROM obligations WHERE outstanding < 0 LIMIT 1')
            .isNotEmpty ||
        _db.select('''SELECT 1 FROM transfers t JOIN bills b ON b.id = t.bill_id
          WHERE t.member_id = b.payer_id LIMIT 1''').isNotEmpty) {
      throw const InputException('合并后的转账记录超出应付金额，或转给了付款人自己');
    }
    if (_db
            .select('SELECT 1 FROM chores WHERE active = 1 LIMIT 1')
            .isNotEmpty &&
        _db.select('SELECT 1 FROM members WHERE active = 1 LIMIT 1').isEmpty) {
      throw const InputException('有启用的卫生任务时，至少需要一位在用成员');
    }
    rememberBase(base);
  });
}
