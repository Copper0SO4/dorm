import 'dart:math';

import 'ledger.dart';

enum DrawMode { draw, teams }

List<String> drawEntries(String input) => {
  for (final line in input.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
}.toList();

List<List<String>> makeDraw(
  List<String> entries,
  int count,
  DrawMode mode,
  Random random,
) {
  if (entries.isEmpty || entries.length > 100) {
    throw const InputException('请输入 1 至 100 个不同选项');
  }
  if (entries.any((entry) => entry.runes.length > 60)) {
    throw const InputException('每个选项最多 60 个字符');
  }
  final minimum = mode == DrawMode.draw ? 1 : 2;
  if (count < minimum || count > entries.length) {
    throw InputException('数量须为 $minimum 至 ${entries.length}');
  }
  final shuffled = [...entries]..shuffle(random);
  return switch (mode) {
    DrawMode.draw => [shuffled.take(count).toList()],
    DrawMode.teams => [
      for (var group = 0; group < count; group++)
        [
          for (var member = group; member < shuffled.length; member += count)
            shuffled[member],
        ],
    ],
  };
}
