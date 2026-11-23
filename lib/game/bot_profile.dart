import 'dart:convert';

import '../domain/preferences.dart';
import 'bot_models.dart';
import 'cards.dart';

export 'bot_models.dart' show BotEffort, BotModel, BotThinking;

const botDecisionTimeout = Duration(seconds: 45);
const botTimeoutLimit = 3;

enum BotProvider {
  deepseek(
    'DeepSeek',
    'https://api.deepseek.com',
    'deepseek-flash',
    BotEffort.low,
  ),
  openai('OpenAI 兼容', 'https://api.openai.com/v1', 'gpt-6-luna', BotEffort.low),
  anthropic(
    'Anthropic',
    'https://api.anthropic.com',
    'claude-sonnet-5-5',
    BotEffort.low,
  );

  const BotProvider(
    this.label,
    this.defaultBase,
    this.defaultModel,
    this.defaultEffort,
  );
  final String label;
  final String defaultBase;
  final String defaultModel;
  final BotEffort defaultEffort;

  static BotProvider parse(String? name) => values.firstWhere(
    (item) => item.name == name,
    orElse: () => BotProvider.deepseek,
  );
}

class BotProfile {
  const BotProfile({
    required this.enabled,
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.effort,
    required this.apiKey,
    this.modelInfo,
  });

  factory BotProfile.fromPreferences(DormPreferences preferences) {
    final provider = BotProvider.parse(preferences.botProvider);
    final base = preferences.botApiBase.trim();
    final model = preferences.botApiModel.trim();
    final baseUrl = base.isEmpty ? provider.defaultBase : base;
    final officialHost = Uri.tryParse(baseUrl)?.host;
    final retiredDeepSeekModel =
        provider == BotProvider.deepseek &&
        officialHost == 'api.deepseek.com' &&
        const {
          'deepseek-chat',
          'deepseek-reasoner',
          'deepseek-v4-flash',
        }.contains(model);
    final oldClaude =
        provider == BotProvider.anthropic &&
        officialHost == 'api.anthropic.com' &&
        const {
          'claude-sonnet-4-5',
          'claude-sonnet-4-5-20250929',
        }.contains(model);
    final activeModel = model.isEmpty || retiredDeepSeekModel || oldClaude
        ? provider.defaultModel
        : model;
    final metadata = BotModel.decode(preferences.botModelMetadata);
    return BotProfile(
      enabled: preferences.botApiEnabled,
      provider: provider,
      baseUrl: baseUrl,
      model: activeModel,
      effort:
          BotEffort.fromWire(preferences.botEffort) ?? provider.defaultEffort,
      modelInfo: metadata?.id == activeModel ? metadata : null,
      apiKey: preferences.botApiKey.trim(),
    );
  }

  final bool enabled;
  final BotProvider provider;
  final String baseUrl;
  final String model;
  final BotEffort effort;
  final String apiKey;
  final BotModel? modelInfo;

  BotThinking get thinkingStyle =>
      modelInfo?.thinking ??
      (provider == BotProvider.anthropic && model == provider.defaultModel
          ? BotThinking.adaptive
          : BotThinking.budget);

  String? get thinkingOffMode => modelInfo?.thinking != null
      ? modelInfo!.offMode
      : provider == BotProvider.anthropic && model == provider.defaultModel
      ? 'between_tools'
      : null;

  List<BotEffort> get effortOptions {
    final discovered = modelInfo?.efforts;
    return [
      BotEffort.automatic,
      if (discovered != null) ...discovered else ..._fallbackEfforts(),
    ];
  }

  BotEffort get effectiveEffort =>
      effortOptions.contains(effort) ? effort : BotEffort.automatic;

  List<BotEffort> _fallbackEfforts() {
    if (thinkingStyle == BotThinking.unsupported) return const [];
    return switch (provider) {
      BotProvider.deepseek => const [
        BotEffort.off,
        BotEffort.low,
        BotEffort.high,
        BotEffort.max,
      ],
      BotProvider.anthropic when thinkingStyle == BotThinking.adaptive => [
        if (thinkingOffMode != null) BotEffort.off,
        BotEffort.low,
        BotEffort.medium,
        BotEffort.high,
        BotEffort.xhigh,
        BotEffort.max,
      ],
      BotProvider.anthropic => const [
        BotEffort.off,
        BotEffort.low,
        BotEffort.high,
        BotEffort.max,
      ],
      BotProvider.openai
          when model.startsWith('gpt-4') || model.startsWith('gpt-3.5') =>
        const [],
      BotProvider.openai when model == BotProvider.openai.defaultModel =>
        const [
          BotEffort.off,
          BotEffort.low,
          BotEffort.medium,
          BotEffort.high,
          BotEffort.xhigh,
          BotEffort.max,
        ],
      BotProvider.openai => const [
        BotEffort.off,
        BotEffort.minimal,
        BotEffort.low,
        BotEffort.medium,
        BotEffort.high,
        BotEffort.xhigh,
        BotEffort.max,
      ],
    };
  }

  bool get usable => enabled && apiKey.isNotEmpty && model.isNotEmpty;

  bool get supportsReasoning => effortOptions.length > 1;

  bool sameDestination(BotProfile other) =>
      provider == other.provider &&
      _validatedBase(baseUrl) != null &&
      _validatedBase(other.baseUrl) != null &&
      botEndpoint(this) == botEndpoint(other);

  String? validate({bool needModel = true}) {
    if (_validatedBase(baseUrl) == null) {
      return '请填写 HTTPS 地址。本机服务可用 HTTP，地址中不能含账号、查询参数或片段。';
    }
    if (needModel && !isBotModelId(model.trim())) {
      return '请填写有效的模型名称';
    }
    if (apiKey.length > 400 ||
        apiKey.codeUnits.any((unit) => unit < 33 || unit > 126)) {
      return 'API 密钥格式无效';
    }
    if (enabled && apiKey.isEmpty) return '启用电脑 API 前请填写密钥';
    return null;
  }
}

Uri? _validatedBase(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.authority.contains('@') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  if (uri.scheme == 'https' ||
      (uri.scheme == 'http' &&
          const {'localhost', '127.0.0.1', '::1'}.contains(uri.host))) {
    return uri;
  }
  return null;
}

class BotSeat {
  const BotSeat({required this.id, required this.cards});

  final int id;
  final int cards;
}

class BotTurn {
  const BotTurn({
    required this.room,
    required this.deal,
    required this.bidding,
    required this.rules,
    required this.hand,
    required this.wild,
    required this.previous,
    required this.topBid,
    required this.seat,
    required this.landlord,
    required this.players,
    required this.log,
    this.leader,
    this.bottom = const [],
    this.playedBySeat = const {},
    this.cancelled,
  });

  final String room;
  final int deal;
  final bool bidding;
  final CardRules rules;
  final List<PlayingCard> hand;
  final Set<int> wild;
  final CardPlay? previous;
  final int? leader;
  final List<PlayingCard> bottom;
  final int topBid;
  final int seat;
  final int? landlord;
  final List<BotSeat> players;
  final List<String> log;
  final Map<int, List<int>> playedBySeat;
  final Future<void>? cancelled;
}

class BotAdvice {
  const BotAdvice.off()
    : explanation = null,
      ready = false,
      failure = null,
      timedOut = false,
      bid = null,
      play = null,
      pass = false;
  const BotAdvice.failed(this.failure, {this.timedOut = false})
    : explanation = null,
      ready = false,
      bid = null,
      play = null,
      pass = false;
  const BotAdvice.bid(this.bid)
    : explanation = null,
      ready = true,
      failure = null,
      timedOut = false,
      play = null,
      pass = false;
  const BotAdvice.pass([this.explanation])
    : ready = true,
      failure = null,
      timedOut = false,
      bid = null,
      play = null,
      pass = true;
  const BotAdvice.play(this.play, [this.explanation])
    : ready = true,
      failure = null,
      timedOut = false,
      bid = null,
      pass = false;

  final bool timedOut;
  final bool ready;
  final String? failure;
  final String? explanation;
  final int? bid;
  final CardPlay? play;
  final bool pass;
}

typedef BotAdvisor = Future<BotAdvice> Function(BotTurn turn);
typedef BotCoach = Future<BotAdvice> Function(
  BotTurn turn,
  List<String> history,
);

Uri botEndpoint(BotProfile profile) {
  final base = Uri.parse(profile.baseUrl.trim());
  final segments = [...base.pathSegments];
  while (segments.lastOrNull == '') {
    segments.removeLast();
  }
  if (segments.isEmpty &&
      profile.provider == BotProvider.openai &&
      base.host == 'api.openai.com') {
    segments.add('v1');
  }
  if (profile.provider == BotProvider.anthropic) {
    if (segments.lastOrNull != 'messages') {
      if (segments.lastOrNull != 'v1') segments.add('v1');
      segments.add('messages');
    }
  } else if (segments.lastOrNull != 'completions' ||
      segments.length < 2 ||
      segments[segments.length - 2] != 'chat') {
    segments.addAll(['chat', 'completions']);
  }
  return base.replace(pathSegments: segments);
}

Uri botModelsEndpoint(BotProfile profile) {
  final completion = botEndpoint(profile);
  final segments = [...completion.pathSegments]..removeLast();
  if (profile.provider != BotProvider.anthropic) segments.removeLast();
  return completion.replace(pathSegments: [...segments, 'models']);
}

const botSystemPrompt = '''
你是斗地主中的一名电脑玩家。这次请求只包含当前这一把的局面，不要假定还记得其他请求或其他牌局。
你的目标是尽快走完手牌。斗地主里农民是队友，除非能走完或需要阻止对手走完，优先让队友保有出牌权。
只能从菜单中选择，留意每项用了哪些原始牌，尽量少拆炸弹和连牌。只输出一个 JSON 对象，不要输出解释。
叫分输出 {"bid":数字}，0 表示不叫。出牌输出 {"i":序号}。
''';

const botCoachPrompt = '''
你是当前斗地主玩家的教练，只根据这一玩家自己的手牌和公开信息推荐一项可选动作。
考虑各座位剩余张数、队友领出、已出的牌、对手走完的风险和拆牌代价。
描述牌面时请用“2张4”“对4”“4张2”“单张A”等明确中文表达，禁止使用“4*2”“4×2”这类易混淆写法。
没有足够信息时说明不确定性。只回 JSON，例如 {"i":0,"reason":"简短的中文理由"}。理由最多 100 字。
''';

String botUserPrompt(
  BotTurn turn,
  List<CardPlay> options, {
  List<String>? coachingHistory,
}) {
  final hand = formatBotRanks(turn.hand.map((card) => card.rank));
  final wild = turn.wild.isEmpty
      ? (turn.rules.mode == CardMode.classic ? '无' : '尚未公开')
      : turn.wild.map(PlayingCard.rankLabel).join('、');
  final order = turn.rules.rocketBeatsChain
      ? '普通炸弹 ＜ 连炸 ＜ 王炸'
      : '普通炸弹 ＜ 王炸 ＜ 连炸';
  final seats = [
    for (final player in turn.players)
      '座位 ${player.id}${player.id == turn.seat ? '（你）' : ''}${player.id == turn.landlord ? '·地主' : ''} 余 ${player.cards} 张',
  ].join('；');
  final log = turn.log.isEmpty ? '无' : turn.log.join(' / ');
  final buffer = StringBuffer()
    ..writeln('第 ${turn.deal} 把。')
    ..writeln(
      '规则：${turn.rules.players} 人，${turn.rules.decks} 副（共 ${54 * turn.rules.decks} 张），'
      '随机弃 ${turn.rules.discard} 张，底牌 ${turn.rules.bottom} 张，${turn.rules.mode.label}，'
      '${turn.rules.landlord ? '地主模式' : '各自为战'}，'
      '连炸${turn.rules.chainBombs ? '开' : '关'}，四带二${turn.rules.fourWithTwo ? '开' : '关'}。$order。',
    )
    ..writeln('癞子：$wild')
    ..writeln('出牌顺序：$seats')
    ..writeln('本把最近公开操作：$log')
    ..writeln('已出原始牌（癞子按原点数统计）：');
  for (final player in turn.players) {
    final played = turn.playedBySeat[player.id] ?? const [];
    buffer.writeln(
      '座位 ${player.id} 已出 ${played.length} 张：${played.isEmpty ? '无' : formatBotRanks(played)}',
    );
  }
  buffer.writeln('你的手牌（${turn.hand.length} 张）：$hand');
  if (coachingHistory != null && coachingHistory.isNotEmpty) {
    buffer.writeln('本局给你的过往建议（仅作参考）：${jsonEncode(coachingHistory)}');
  }
  if (turn.bidding) {
    final choices = turn.rules.bidsAfter(turn.topBid);
    final call = turn.rules.landlordCall == LandlordCall.call;
    buffer
      ..writeln(call ? '叫地主制度，1 表示叫地主。' : '当前最高 ${turn.topBid} 分。')
      ..writeln(
        '可选动作：${choices.map((bid) => bid == 0
            ? '不叫'
            : call
            ? '叫地主'
            : '$bid 分').join('、')}。',
      )
      ..write('只输出例如 {"bid":0}。');
    return buffer.toString();
  }
  if (turn.bottom.isNotEmpty) {
    buffer.writeln(
      '公开底牌：${formatBotRanks(turn.bottom.map((card) => card.rank))}',
    );
  }
  final last = turn.previous;
  final previous = last == null
      ? '你先出'
      : '本轮需管座位 ${turn.leader} 的 ${last.label} ${PlayingCard.rankLabel(last.high)}';
  buffer.writeln(previous);
  var index = 0;
  if (turn.previous != null) {
    buffer.writeln('$index. 不出');
    index++;
  }
  for (final play in options) {
    final ranks = formatBotRanks(
      play.cards.map((card) => play.ranks[card.id] ?? card.rank),
    );
    final original = play.ranks.isEmpty
        ? ''
        : '（使用 ${formatBotRanks(play.cards.map((card) => card.rank))}）';
    buffer.writeln('$index. ${play.label} $ranks$original');
    index++;
  }
  buffer.write(
    coachingHistory == null
        ? '只输出例如 {"i":0}。'
        : '只输出例如 {"i":0,"reason":"为什么建议这样打"}。',
  );
  return buffer.toString();
}

List<CardPlay> botCandidates(BotTurn turn) {
  final hints = hintPlays(
    turn.hand,
    turn.wild,
    turn.previous,
    rules: turn.rules,
  );
  final ordinary = hints.where((play) => !play.bomb).toList()
    ..sort((a, b) {
      final length = b.cards.length.compareTo(a.cards.length);
      if (length != 0) return length;
      final rank = a.high.compareTo(b.high);
      return rank == 0 ? a.kind.index.compareTo(b.kind.index) : rank;
    });
  final byKind = <PlayKind, CardPlay>{};
  for (final play in ordinary) {
    byKind.putIfAbsent(play.kind, () => play);
  }
  final varied = {...byKind.values, ...ordinary};
  final bombs = hints.where((play) => play.bomb);
  final bombChoices = {
    for (final kind in PlayKind.values)
      ?bombs.where((play) => play.kind == kind).firstOrNull,
    ...bombs,
  };
  return [...varied.take(16), ...bombChoices.take(8)];
}

BotAdvice interpretBotText(
  String text,
  BotTurn turn,
  List<CardPlay> options, {
  bool explain = false,
}) {
  final Object? decoded;
  try {
    decoded = decodeBotJson(text);
  } on FormatException {
    return const BotAdvice.failed('API 没有返回可识别的动作');
  }
  if (decoded is! Map<String, dynamic> || decoded.length != (explain ? 2 : 1)) {
    return const BotAdvice.failed('API 没有返回可识别的动作');
  }
  if (turn.bidding) {
    final bid = decoded['bid'];
    final allowed = turn.rules.bidsAfter(turn.topBid);
    if (bid is! int || !allowed.contains(bid)) {
      return const BotAdvice.failed('API 给出的叫分不在可选范围内');
    }
    return BotAdvice.bid(bid);
  }
  final index = decoded['i'];
  final offset = turn.previous == null ? 0 : 1;
  if (index is! int || index < 0 || index >= options.length + offset) {
    return const BotAdvice.failed('API 给出的序号不在可选范围内');
  }
  String? reason;
  if (explain) {
    final text = decoded['reason'];
    if (text is! String || text.trim().isEmpty) {
      return const BotAdvice.failed('AI 没有给出可用的解释');
    }
    reason = String.fromCharCodes(
      text.runes.where((unit) => unit >= 32 && unit != 127).take(240),
    ).trim();
    if (reason.isEmpty) return const BotAdvice.failed('AI 没有给出可用的解释');
  }
  if (turn.previous != null && index == 0) return BotAdvice.pass(reason);
  return BotAdvice.play(options[index - offset], reason);
}

Object? decodeBotJson(String text) {
  final source = text.trim();
  final fence = RegExp(
    r'^\x60{3}(?:json)?\s*([\s\S]*?)\s*\x60{3}$',
    caseSensitive: false,
  ).firstMatch(source);
  return jsonDecode(fence?.group(1) ?? source);
}

String formatBotRanks(Iterable<int> ranks) {
  final counts = <int, int>{};
  for (final rank in ranks) {
    counts.update(rank, (value) => value + 1, ifAbsent: () => 1);
  }
  final ordered = counts.keys.toList()..sort();
  return [
    for (final rank in ordered)
      counts[rank] == 1
          ? PlayingCard.rankLabel(rank)
          : '${counts[rank]}张${PlayingCard.rankLabel(rank)}',
  ].join(' ');
}
