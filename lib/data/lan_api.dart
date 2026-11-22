import '../domain/identity.dart';
import '../domain/ledger.dart';
import '../domain/matters.dart';
import '../domain/models.dart';
import '../domain/party_tools.dart';
import '../domain/repository.dart';
import '../domain/schedule.dart';

class LanApi {
  const LanApi(this.repository, this.write);
  final DormRepository repository;
  final void Function(void Function()) write;

  Object? read(List<String> route, Map<String, String> parameters) =>
      switch (route) {
        ['members'] => [
          for (final member in repository.members())
            {'id': member.id, 'name': member.name, 'active': member.active},
        ],
        ['ledger'] => _ledger(parameters),
        ['ledger', final id] => _detail(_positiveId(id)),
        ['chores'] => _shifts(parameters['day']),
        ['supplies'] => [
          for (final item in repository.supplies())
            {
              'id': item.id,
              'name': item.name,
              'category': item.category,
              'quantity': item.quantity,
              'location': item.location,
              'note': item.note,
              'status': item.status.name,
            },
        ],
        ['matters'] => [
          for (final item in repository.matters())
            {
              'id': item.id,
              'title': item.title,
              'note': item.note,
              'ownerId': item.ownerId,
              'owner': item.owner,
              'dueDay': item.dueDay,
              'urgent': item.urgent,
              'status': item.status.name,
              'archived': item.archived,
            },
        ],
        ['tools'] => _tools(),
        _ => null,
      };

  bool mutate(List<String> route, Map<String, dynamic> body) {
    final data = _Input(body);
    String browserDevice() {
      final code = body['browserDevice'];
      if (code == null) return newIdentityCode();
      if (code is! String || !isIdentityCode(code)) {
        throw const InputException('浏览器设备码无效');
      }
      return code;
    }

    switch (route) {
      case ['ledger'] || ['ledger', 'edit']:
        final participants = body['participants'];
        final personal = body['personal'];
        if (participants is! List ||
            participants.any((item) => item is! int || item < 1) ||
            personal is! Map<String, dynamic>) {
          throw const InputException('请检查参与成员和个人费用');
        }
        final fees = <int, int>{};
        for (final item in personal.entries) {
          fees[_positiveId(item.key)] = _cents(item.value);
        }
        final supplyId = data.optionalId('supplyId');
        final draft = BillDraft(
          title: data.text('title'),
          sharedAmount: data.money('shared', optional: true),
          payerId: data.id('payerId'),
          participantIds: participants.cast<int>(),
          personalAmounts: fees,
          supplyId: supplyId,
          markSupplyOrdered: supplyId != null,
        );
        if (route.length == 1) {
          write(
            () => repository.addBill(draft, browserDevice: browserDevice()),
          );
        } else {
          write(
            () => repository.updateBill(
              data.id('id'),
              draft,
              expectedVersion: data.text('version'),
              browserDevice: browserDevice(),
            ),
          );
        }
      case ['ledger', 'delete']:
        write(
          () => repository.deleteBill(
            data.id('id'),
            browserDevice: browserDevice(),
          ),
        );
      case ['transfers']:
        write(
          () => repository.recordTransfer(
            data.id('billId'),
            data.id('memberId'),
            data.money('amount'),
            browserDevice: browserDevice(),
          ),
        );
      case ['settlement']:
        final rawExpected = body['expected'];
        if (rawExpected is! Map<String, dynamic> || rawExpected.isEmpty) {
          throw const InputException('请选择需要核销的账单');
        }
        final expected = <int, int>{};
        for (final entry in rawExpected.entries) {
          final amount = entry.value;
          if (amount is! int || amount <= 0) {
            throw const InputException('待付账单金额格式无效');
          }
          expected[_positiveId(entry.key)] = amount;
        }
        write(
          () => repository.recordSettlement(
            data.id('debtorId'),
            data.id('payerId'),
            expected,
            data.money('amount'),
          ),
        );
      case ['members', 'save']:
        write(
          () => repository.saveMember(
            data.text('name'),
            id: data.optionalId('id'),
          ),
        );
      case ['members', 'active']:
        write(
          () => repository.setMemberActive(data.id('id'), data.flag('active')),
        );
      case ['members', 'delete']:
        write(() => repository.deleteMember(data.id('id')));
      case ['chores', 'generate']:
        final day = _parseDay(data.text('day'));
        if (day.isAfter(today().add(const Duration(days: 45)))) {
          throw const InputException('可生成未来 45 天内的排班');
        }
        write(() => repository.generateShiftsThrough(day));
      case ['chores', 'complete']:
        write(() => repository.completeShift(data.id('id')));
      case ['chores', 'reassign']:
        write(
          () => repository.reassignShift(data.id('id'), data.id('memberId')),
        );
      case ['supplies', 'save']:
        final draft = (
          name: data.text('name'),
          category: data.text('category'),
          quantity: data.integer('quantity'),
          location: data.text('location'),
          note: data.text('note'),
          status: data.choice('status', PurchaseStatus.values),
        );
        write(() => repository.saveSupply(draft, id: data.optionalId('id')));
      case ['supplies', 'delete']:
        write(() => repository.deleteSupply(data.id('id')));
      case ['supplies', 'order']:
        write(() => repository.markSupplyOrdered(data.id('id')));
      case ['supplies', 'receive']:
        write(
          () =>
              repository.receiveSupply(data.id('id'), data.integer('quantity')),
        );
      case ['matters', 'save']:
        final due = data.text('due');
        final draft = (
          title: data.text('title'),
          note: data.text('note'),
          ownerId: data.optionalId('ownerId'),
          due: due.isEmpty ? null : _parseDay(due),
          urgent: data.flag('urgent'),
        );
        write(() => repository.saveMatter(draft, id: data.optionalId('id')));
      case ['matters', 'status']:
        write(
          () => repository.setMatterStatus(
            data.id('id'),
            data.choice('status', MatterStatus.values),
          ),
        );
      case ['matters', 'archive']:
        write(
          () => repository.archiveMatter(data.id('id'), data.flag('archived')),
        );
      default:
        return false;
    }
    return true;
  }

  Object _ledger(Map<String, String> parameters) {
    final requested = int.tryParse(parameters['page'] ?? '0') ?? 0;
    final page = requested < 0 || requested > 100000 ? 0 : requested;
    const pageSize = 40;
    final query = (parameters['query'] ?? '').trim().toLowerCase();
    final bills = repository
        .bills()
        .where(
          (bill) =>
              (parameters['unpaid'] != 'true' || bill.outstanding > 0) &&
              (query.isEmpty ||
                  [
                    bill.title,
                    bill.payer,
                    bill.supplyName ?? '',
                  ].any((value) => value.toLowerCase().contains(query))),
        )
        .toList();
    return {
      'page': page,
      'selectAllParticipants': repository.preferences.selectAllParticipants,
      'count': bills.length,
      'total': bills.fold(0, (sum, bill) => sum + bill.total),
      'outstanding': bills.fold(0, (sum, bill) => sum + bill.outstanding),
      'hasNext': (page + 1) * pageSize < bills.length,
      'bills': bills.skip(page * pageSize).take(pageSize).map(_bill).toList(),
      'balances': () {
        final membersByName = {
          for (final member in repository.members()) member.name: member,
        };
        return [
          for (final item in repository.balances())
            {
              'id': membersByName[item.name]?.id,
              'name': item.name,
              'active': membersByName[item.name]?.active ?? true,
              'receivable': item.receivable,
              'payable': item.payable,
              'openReceivable': item.openReceivable,
              'openPayable': item.openPayable,
            },
        ];
      }(),
      'openSettlements': [
        for (final pair in repository.openSettlements())
          {
            'debtorId': pair.debtorId,
            'debtor': pair.debtor,
            'payerId': pair.payerId,
            'payer': pair.payer,
            'total': pair.charges.fold(0, (sum, charge) => sum + charge.amount),
            'charges': [
              for (final charge in pair.charges)
                {
                  'billId': charge.billId,
                  'title': charge.title,
                  'amount': charge.amount,
                },
            ],
          },
      ],
    };
  }

  Object _tools() => {
    'members': [
      for (final member in repository.members())
        if (member.active) member.name,
    ],
    'penalties': penaltyPresets,
  };

  Object _detail(int id) {
    final detail = repository.billDetail(id);
    return {
      'bill': _bill(detail.bill),
      'version': detail.version,
      'participants': detail.participants,
      'activity': [
        for (final entry in detail.activity)
          {
            'deviceCode': entry.deviceCode,
            'member': entry.memberName,
            'action': entry.action.label,
            'createdAt': entry.date,
            'detail': entry.detail,
          },
      ],
      'shares': [
        for (final share in detail.shares)
          {
            'id': share.memberId,
            'name': share.member,
            'amount': share.amount,
            'personal': share.personalAmount,
            'paid': share.paid,
          },
      ],
      'transfers': [
        for (final transfer in detail.transfers)
          {
            'member': transfer.member,
            'amount': transfer.amount,
            'createdAt': transfer.createdAt,
          },
      ],
    };
  }

  Object _shifts(String? selected) {
    final date = selected == null ? today() : _parseDay(selected);
    return {
      'day': dayKey(date),
      'today': dayKey(today()),
      'shifts': [
        for (final shift in repository.shifts(date, date))
          {
            'id': shift.id,
            'title': shift.title,
            'member': shift.member,
            'completedAt': shift.completedAt,
          },
      ],
    };
  }
}

Map<String, Object?> _bill(Bill bill) => {
  'id': bill.id,
  'title': bill.title,
  'total': bill.total,
  'payerId': bill.payerId,
  'payer': bill.payer,
  'supplyName': bill.supplyName,
  'createdAt': bill.createdAt,
  'outstanding': bill.outstanding,
  'personal': bill.personalAmount,
};

DateTime _parseDay(String text) {
  final value = DateTime.tryParse(text);
  if (value == null ||
      value.year < 1900 ||
      value.year > 9999 ||
      dayKey(value) != text) {
    throw const InputException('请选择有效日期');
  }
  return civilDay(value);
}

int _positiveId(String raw) {
  final id = int.tryParse(raw);
  if (id == null || id <= 0) throw const InputException('记录编号无效');
  return id;
}

int _cents(Object? value, {bool optional = false}) {
  if (optional && value == '') return 0;
  final amount = value is String ? parseCents(value) : null;
  if (amount == null || (!optional && amount == 0)) {
    throw const InputException('请输入有效的金额，最多两位小数');
  }
  return amount;
}

class _Input {
  const _Input(this.values);
  final Map<String, dynamic> values;

  String text(String key) {
    final value = values[key];
    if (value is! String) throw const InputException('请检查填写内容');
    return value.trim();
  }

  int integer(String key) {
    final value = values[key];
    if (value is! int) throw const InputException('请输入有效整数');
    return value;
  }

  int id(String key) {
    final value = integer(key);
    if (value < 1) throw const InputException('记录编号无效');
    return value;
  }

  int? optionalId(String key) => values[key] == null ? null : id(key);
  int money(String key, {bool optional = false}) =>
      _cents(values[key], optional: optional);

  bool flag(String key) {
    final value = values[key];
    if (value is! bool) throw const InputException('请检查选项');
    return value;
  }

  T choice<T extends Enum>(String key, List<T> options) => options.firstWhere(
    (item) => item.name == text(key),
    orElse: () => throw const InputException('所选状态不存在'),
  );
}
