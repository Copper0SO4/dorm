enum MatterStatus {
  open('待处理'),
  doing('进行中'),
  done('已完成');

  const MatterStatus(this.label);
  final String label;
}

typedef MatterDraft = ({
  String title,
  String note,
  int? ownerId,
  DateTime? due,
  bool urgent,
});

typedef Matter = ({
  int id,
  String title,
  String note,
  int? ownerId,
  String? owner,
  String? dueDay,
  bool urgent,
  MatterStatus status,
  String createdAt,
  String? completedAt,
  bool archived,
});
