const schema = [
  '''CREATE TABLE members (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE,
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
  ) STRICT''',
  '''CREATE TABLE supplies (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity >= 0), location TEXT NOT NULL,
    note TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('stocked', 'needed', 'ordered')),
    deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
  ) STRICT''',
  '''CREATE TABLE bills (
    id INTEGER PRIMARY KEY, title TEXT NOT NULL,
    total INTEGER NOT NULL CHECK (total BETWEEN 1 AND 999999999),
    payer_id INTEGER NOT NULL REFERENCES members(id), created_at TEXT NOT NULL,
    supply_id INTEGER REFERENCES supplies(id), supply_name TEXT,
    CHECK ((supply_id IS NULL) = (supply_name IS NULL))
  ) STRICT''',
  '''CREATE TABLE shares (
    bill_id INTEGER NOT NULL REFERENCES bills(id), member_id INTEGER NOT NULL REFERENCES members(id),
    amount INTEGER NOT NULL CHECK (amount >= 0), PRIMARY KEY (bill_id, member_id)
  ) STRICT''',
  '''CREATE TABLE transfers (
    id INTEGER PRIMARY KEY, bill_id INTEGER NOT NULL, member_id INTEGER NOT NULL,
    amount INTEGER NOT NULL CHECK (amount > 0), created_at TEXT NOT NULL,
    FOREIGN KEY (bill_id, member_id) REFERENCES shares(bill_id, member_id)
  ) STRICT''',
  'CREATE INDEX transfers_bill_member ON transfers(bill_id, member_id)',
  'CREATE INDEX bills_supply ON bills(supply_id)',
  '''CREATE VIEW obligations AS
    SELECT s.bill_id, s.member_id, b.payer_id, s.amount,
      s.amount - COALESCE((SELECT SUM(t.amount) FROM transfers t
        WHERE t.bill_id = s.bill_id AND t.member_id = s.member_id), 0) AS outstanding
    FROM shares s JOIN bills b ON b.id = s.bill_id WHERE s.member_id <> b.payer_id''',
  '''CREATE TABLE chores (
    id INTEGER PRIMARY KEY, title TEXT NOT NULL, cadence TEXT NOT NULL CHECK (cadence IN ('daily', 'weekly')),
    next_day TEXT NOT NULL, last_member_id INTEGER REFERENCES members(id),
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
  ) STRICT''',
  '''CREATE TABLE shifts (
    id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES chores(id), day TEXT NOT NULL,
    member_id INTEGER NOT NULL REFERENCES members(id), completed_at TEXT,
    UNIQUE (task_id, day)
  ) STRICT''',
  'CREATE INDEX shifts_day ON shifts(day)',
];

const mattersSchema = '''CREATE TABLE matters (
  id INTEGER PRIMARY KEY, title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 80),
  note TEXT NOT NULL CHECK(length(note) <= 600),
  owner_id INTEGER REFERENCES members(id), due_day TEXT CHECK(due_day IS NULL OR length(due_day)=10),
  urgent INTEGER NOT NULL DEFAULT 0 CHECK(urgent IN (0,1)),
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','doing','done')),
  created_at TEXT NOT NULL, completed_at TEXT,
  archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
  CHECK ((status = 'done') = (completed_at IS NOT NULL))
) STRICT''';

const identitySchema = [
  'ALTER TABLE members ADD COLUMN avatar TEXT CHECK(avatar IS NULL OR length(avatar) <= 52000)',
  'ALTER TABLE bills ADD COLUMN edit_version TEXT',
  'ALTER TABLE shares ADD COLUMN shared INTEGER CHECK(shared IN (0, 1))',
  '''CREATE TABLE identity_claims (
    id INTEGER PRIMARY KEY, member_key TEXT NOT NULL, device_code TEXT NOT NULL,
    state INTEGER NOT NULL CHECK(state IN (0, 1, 2)), created_at TEXT NOT NULL
  ) STRICT''',
  'CREATE UNIQUE INDEX active_member_claim ON identity_claims(member_key) WHERE state=0',
  'CREATE UNIQUE INDEX active_device_claim ON identity_claims(device_code) WHERE state=0',
  'CREATE INDEX claim_device_history ON identity_claims(device_code, created_at)',
  '''CREATE TABLE audit_entries (
    id INTEGER PRIMARY KEY, target_kind TEXT NOT NULL CHECK(target_kind IN ('member', 'bill')),
    target_key TEXT NOT NULL, device_code TEXT NOT NULL, claim_key TEXT,
    action TEXT NOT NULL, created_at TEXT NOT NULL, detail TEXT NOT NULL
  ) STRICT''',
  'CREATE INDEX audit_target ON audit_entries(target_kind, target_key, created_at)',
];
