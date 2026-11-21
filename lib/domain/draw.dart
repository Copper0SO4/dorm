import 'dart:math';

import 'ledger.dart';

enum DrawMode { draw, teams }

List<String> drawEntries(String input) => _uniqueEntries(input.split('\n'));

List<String> _uniqueEntries(Iterable<String> entries) => {
  for (final entry in entries)
    if (entry.trim().isNotEmpty) entry.trim(),
}.toList();

List<List<String>> makeDraw(
  List<String> entries,
  int count,
  DrawMode mode,
  Random random,
) {
  final options = _uniqueEntries(entries);
  if (options.isEmpty || options.length > 100) {
    throw const InputException('请输入 1 至 100 个不同选项');
  }
  if (options.any((entry) => entry.runes.length > 60)) {
    throw const InputException('每个选项最多 60 个字符');
  }
  final minimum = mode == DrawMode.draw ? 1 : 2;
  if (options.length < minimum) {
    throw const InputException('随机分组至少需要 2 个不同的候选项');
  }
  if (count < minimum || count > options.length) {
    final label = mode == DrawMode.draw ? '抽取数量' : '组数';
    throw InputException('$label须为 $minimum 至 ${options.length}');
  }
  options.shuffle(random);
  return switch (mode) {
    DrawMode.draw => [options.take(count).toList()],
    DrawMode.teams => [
      for (var group = 0; group < count; group++)
        [
          for (var member = group; member < options.length; member += count)
            options[member],
        ],
    ],
  };
}
