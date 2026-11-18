enum Cadence {
  daily('每日', 1),
  weekly('每周', 7);

  const Cadence(this.label, this.days);

  final String label;
  final int days;
}

DateTime today() {
  final now = DateTime.now();
  return DateTime.utc(now.year, now.month, now.day);
}

DateTime civilDay(DateTime day) => DateTime.utc(day.year, day.month, day.day);

String dayKey(DateTime day) => civilDay(day).toIso8601String().substring(0, 10);

int nextAssignee(List<int> sortedMemberIds, int? previousId) {
  if (previousId != null) {
    for (final id in sortedMemberIds) {
      if (id > previousId) return id;
    }
  }
  return sortedMemberIds.first;
}
