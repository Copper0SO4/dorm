import 'dart:math';

import 'ledger.dart';

typedef DecisionPreset = ({
  String id,
  String title,
  String description,
  bool usesMembers,
  List<String> options,
});

const decisionPresets = <DecisionPreset>[
  (
    id: 'meal',
    title: '今天吃什么',
    description: '纠结午饭、晚饭或夜宵时快速拍板',
    usesMembers: false,
    options: [
      '食堂一楼自选',
      '食堂二楼麻辣烫',
      '黄焖鸡米饭',
      '猪脚饭',
      '轻食减脂餐',
      '兰州拉面',
      '烧烤夜宵',
      '点外卖换换口味',
    ],
  ),
  (
    id: 'errand',
    title: '谁去跑腿',
    description: '拿快递、下楼取外卖、倒垃圾一抽定音',
    usesMembers: true,
    options: [],
  ),
  (
    id: 'weekend',
    title: '周末去哪玩',
    description: '寝室聚会或周末放松快速挑一个安排',
    usesMembers: false,
    options: [
      '宿舍开黑组局',
      '看场电影',
      '下馆子聚餐',
      '操场夜跑打球',
      '桌面小游戏局',
      '图书馆刷自习',
      '宿舍躺平补觉',
    ],
  ),
];

const penaltyPresets = <String>[
  '承包今天寝室倒垃圾',
  '给每位室友带一瓶饮料/矿泉水',
  '寝室群发一个 2 元拼手气红包',
  '下次下楼顺手帮大家带外卖/快递',
  '清唱两句大家点播的歌',
  '做 15 个深蹲或平板支撑 30 秒',
];

List<String> parsePenaltyOptions(String text) => List.unmodifiable({
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
});

String pickRandomOption(List<String> entries, Random random) {
  final valid = entries
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
  if (valid.isEmpty) {
    throw const InputException('请至少保留 1 个有效选项');
  }
  return valid[random.nextInt(valid.length)];
}

enum BombOutcome { tooLow, tooHigh, exploded }

class NumberBombGame {
  NumberBombGame({int min = 1, int max = 100, Random? random})
    : _random = random ?? Random.secure() {
    reset(min: min, max: max);
  }

  final Random _random;
  late int _low;
  late int _high;
  late int _secret;
  var _exploded = false;
  final _history = <({int guess, BombOutcome outcome})>[];

  int get low => _low;
  int get high => _high;
  bool get exploded => _exploded;
  int get secret => _secret;
  int get attempts => _history.length;
  List<({int guess, BombOutcome outcome})> get history =>
      List.unmodifiable(_history);

  void reset({int min = 1, int max = 100}) {
    if (min < 1 || max <= min + 1 || max > 9999) {
      throw const InputException('范围须满足 1 ≤ 下限，且区间至少包含 3 个数字（上限 ≤ 9999）');
    }
    _low = min;
    _high = max;
    _secret = min + _random.nextInt(max - min + 1);
    _exploded = false;
    _history.clear();
  }

  BombOutcome guess(int value) {
    if (_exploded) {
      throw const InputException('本局炸弹已引爆，请点击重新开始');
    }
    if (value < _low || value > _high) {
      throw InputException('请输入 $_low 至 $_high 之间的整数');
    }
    final BombOutcome outcome;
    if (value == _secret) {
      outcome = BombOutcome.exploded;
      _exploded = true;
    } else if (value < _secret) {
      outcome = BombOutcome.tooLow;
      _low = value + 1;
    } else {
      outcome = BombOutcome.tooHigh;
      _high = value - 1;
    }
    _history.add((guess: value, outcome: outcome));
    return outcome;
  }
}
