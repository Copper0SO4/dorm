import 'schedule.dart';

typedef Member = ({int id, String name, bool active});

typedef Bill = ({
  int id,
  String title,
  int total,
  int payerId,
  String payer,
  String createdAt,
  String? supplyName,
  int outstanding,
});

class BillDraft {
  const BillDraft({
    required this.title,
    required this.sharedAmount,
    required this.payerId,
    required this.participantIds,
    this.personalAmounts = const {},
    this.supplyId,
  });

  final String title;
  final int sharedAmount;
  final int payerId;
  final List<int> participantIds;
  final Map<int, int> personalAmounts;
  final int? supplyId;
}

typedef Share = ({
  int memberId,
  String member,
  int amount,
  int personalAmount,
  int paid,
});

typedef Transfer = ({String member, int amount, String createdAt});

typedef BillDetail = ({
  Bill bill,
  List<Share> shares,
  List<Transfer> transfers,
});

typedef Balance = ({
  String name,
  int receivable,
  int payable,
  int openReceivable,
  int openPayable,
});

typedef Chore = ({int id, String title, Cadence cadence, bool active});

typedef Shift = ({
  int id,
  int taskId,
  String title,
  String day,
  int memberId,
  String member,
  bool memberActive,
  String? completedAt,
});

enum PurchaseStatus {
  stocked('已入库'),
  needed('待采购'),
  ordered('采购中');

  const PurchaseStatus(this.label);

  final String label;
}

typedef Supply = ({
  int id,
  String name,
  String category,
  int quantity,
  String location,
  String note,
  PurchaseStatus status,
});

typedef SupplyDraft = ({
  String name,
  String category,
  int quantity,
  String location,
  String note,
  PurchaseStatus status,
});
