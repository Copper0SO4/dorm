part of 'sqlite_repository.dart';

String _installationCode(String path) {
  if (path == ':memory:') return newIdentityCode();
  // The installation identity stays outside the shared data and its backups.
  final db = sqlite3.open('$path.identity');
  try {
    db.execute('PRAGMA busy_timeout = 2000');
    db.execute('''CREATE TABLE IF NOT EXISTS installation (
      id INTEGER PRIMARY KEY CHECK(id=1), code TEXT NOT NULL
    ) STRICT''');
    final previous = db
        .select('SELECT code FROM installation WHERE id=1')
        .firstOrNull?['code'];
    if (previous is String && isIdentityCode(previous)) return previous;
    db.execute('INSERT OR IGNORE INTO installation (id,code) VALUES (1,?)', [
      newIdentityCode(),
    ]);
    final code = db
        .select('SELECT code FROM installation WHERE id=1')
        .single['code'];
    if (code is! String || !isIdentityCode(code)) {
      throw const InputException('本机设备码无法读取');
    }
    return code;
  } finally {
    db.close();
  }
}

mixin _SqliteIdentity {
  Database get _db;
  String get deviceCode;
  T _transaction<T>(T Function() body);
  String _timestamp();
  Row _requireRow(String sql, List<Object?> parameters, String message);

  MyIdentity get identity {
    final claim = _db
        .select(
          '''SELECT c.state,m.id FROM identity_claims c
      LEFT JOIN members m ON m.sync_id=c.member_key AND m.active=1
      WHERE c.device_code=? ORDER BY c.state=0 DESC,c.created_at DESC,c.sync_id DESC LIMIT 1''',
          [deviceCode],
        )
        .firstOrNull;
    return (
      deviceCode: deviceCode,
      memberId: claim?['state'] == ClaimState.active.index
          ? (claim?['id'] as int?)
          : null,
      conflicted: claim?['state'] == ClaimState.conflict.index,
    );
  }

  void claimMember(int id) => _transaction(() {
    final member = _requireRow(
      'SELECT sync_id FROM members WHERE id=? AND active=1',
      [id],
      '所选成员已停用或不存在',
    );
    final existing = _db.select(
      'SELECT member_key,device_code FROM identity_claims WHERE state=0 AND (member_key=? OR device_code=?)',
      [member['sync_id'], deviceCode],
    );
    for (final claim in existing) {
      if (claim['member_key'] == member['sync_id']) {
        if (claim['device_code'] == deviceCode) return;
        throw const InputException('这位室友已被认领，请选择其他成员');
      }
      throw const InputException('本机已有认领，请先解除后再选择');
    }
    _db.execute(
      'INSERT INTO identity_claims (member_key,device_code,state,created_at) VALUES (?,?,0,?)',
      [member['sync_id'], deviceCode, _timestamp()],
    );
  });

  void releaseMember() => _db.execute(
    'UPDATE identity_claims SET state=1 WHERE device_code=? AND state=0',
    [deviceCode],
  );

  String _targetKey(AuditTarget target, int id) {
    final table = target == AuditTarget.member ? 'members' : 'bills';
    return _requireRow('SELECT sync_id FROM $table WHERE id=?', [
          id,
        ], '记录不存在')['sync_id']
        as String;
  }

  void _audit(
    AuditTarget target,
    int id,
    AuditAction action,
    String detail, {
    String? browserDevice,
  }) {
    final device = browserDevice ?? deviceCode;
    if (!isIdentityCode(device)) throw const InputException('设备码无效');
    final claim = browserDevice == null
        ? (_db.select(
            'SELECT sync_id FROM identity_claims WHERE state=0 AND device_code=?',
            [device],
          ).firstOrNull?['sync_id'])
        : null;
    _db.execute(
      '''INSERT INTO audit_entries
      (target_kind,target_key,device_code,claim_key,action,created_at,detail)
      VALUES (?,?,?,?,?,?,?)''',
      [
        target.name,
        _targetKey(target, id),
        device,
        claim,
        action.name,
        _timestamp(),
        detail,
      ],
    );
  }

  List<AuditEntry> _activity(AuditTarget target, int id) => [
    for (final row in _db.select(
      '''
      SELECT a.*, m.name FROM audit_entries a
      LEFT JOIN identity_claims c ON c.sync_id=a.claim_key AND c.device_code=a.device_code AND c.state<>2
      LEFT JOIN members m ON m.sync_id=c.member_key
      WHERE a.target_kind=? AND a.target_key=?
      ORDER BY a.created_at DESC,a.sync_id DESC
      ''',
      [target.name, _targetKey(target, id)],
    ))
      (
        deviceCode: row['device_code'] as String,
        memberName: row['name'] as String?,
        date: row['created_at'] as String,
        action: AuditAction.values.byName(row['action'] as String),
        detail: row['detail'] as String,
      ),
  ];

  List<AuditEntry> memberActivity(int id) => _activity(AuditTarget.member, id);
}
