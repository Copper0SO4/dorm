import 'dart:convert';

enum BotEffort {
  automatic('服务端默认'),
  off('关闭'),
  minimal('最低'),
  low('低'),
  medium('中'),
  high('高'),
  xhigh('很高'),
  max('最高');

  const BotEffort(this.label);

  final String label;

  String get wire => this == off ? 'none' : name;

  static BotEffort? fromWire(Object? value) => switch (value) {
    'none' => off,
    String name => values.where((item) => item.name == name).firstOrNull,
    _ => null,
  };
}

enum BotThinking { adaptive, budget, unsupported }

class BotModel {
  const BotModel({
    required this.id,
    this.name = '',
    this.efforts,
    this.defaultEffort,
    this.thinking,
    this.offMode,
  });

  final String id;
  final String name;

  /// Null means the server did not publish levels. An empty list is explicit.
  final List<BotEffort>? efforts;
  final BotEffort? defaultEffort;
  final BotThinking? thinking;
  final String? offMode;

  String get label => name.isEmpty || name == id ? id : '$name ($id)';

  String encode() => jsonEncode({
    'id': id,
    'name': name,
    'efforts': efforts?.map((effort) => effort.wire).toList(),
    'default': defaultEffort?.wire,
    'thinking': thinking?.name,
    'off': offMode,
  });

  static BotModel? decode(String value) {
    if (value.isEmpty || value.length > 1600) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map || !isBotModelId(data['id'])) return null;
      return BotModel(
        id: data['id'] as String,
        name: data['name'] is String ? data['name'] as String : '',
        efforts: _readEfforts(data['efforts']),
        defaultEffort: BotEffort.fromWire(data['default']),
        thinking: BotThinking.values
            .where((style) => style.name == data['thinking'])
            .firstOrNull,
        offMode: switch (data['off']) {
          'disabled' => 'disabled',
          'between_tools' => 'between_tools',
          _ => null,
        },
      );
    } on FormatException {
      return null;
    }
  }

  static BotModel? fromApi(
    Map<String, dynamic> item, {
    required bool anthropic,
    required bool deepseek,
  }) {
    final id = item['id'];
    if (!isBotModelId(id) ||
        item['lifecycle'] == 'retired' ||
        !_hasText(item['input_modalities']) ||
        !_hasText(item['output_modalities'])) {
      return null;
    }
    final displayName = item['display_name'] ?? item['name'];
    final effort = _map(item['effort']);
    var levels = _readEfforts(
      effort?['supported_levels'] ?? item['supported_reasoning_efforts'],
    );
    final defaultEffort = BotEffort.fromWire(effort?['default_level']);
    BotThinking? style;
    String? offMode;
    if (anthropic) {
      final caps = _map(item['capabilities']);
      final support = _map(caps?['thinking']);
      final types = _map(support?['types']);
      final declared = _map(caps?['effort']);
      if (support?['supported'] == false) {
        style = BotThinking.unsupported;
        levels = const [];
      } else if (_supported(types?['adaptive'])) {
        style = BotThinking.adaptive;
        offMode = _supported(types?['between_tools'])
            ? 'between_tools'
            : _supported(types?['disabled'])
            ? 'disabled'
            : null;
        if (declared != null) {
          levels = [
            if (offMode != null) BotEffort.off,
            for (final level in BotEffort.values)
              if (_supported(declared[level.wire])) level,
          ];
        }
      } else if (_supported(types?['enabled'])) {
        style = BotThinking.budget;
      }
    }
    if (deepseek && levels != null && levels.isNotEmpty) {
      levels = {BotEffort.off, ...levels}.toList();
    }
    return BotModel(
      id: id as String,
      name: displayName is String
          ? String.fromCharCodes(displayName.runes.take(160))
          : '',
      efforts: levels == null ? null : List.unmodifiable(levels),
      defaultEffort: levels?.contains(defaultEffort) == true
          ? defaultEffort
          : null,
      thinking: style,
      offMode: offMode,
    );
  }
}

bool isBotModelId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 200 &&
    value.codeUnits.every((unit) => unit >= 33 && unit <= 126);

bool _hasText(Object? field) => field is! List || field.contains('text');

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;

bool _supported(Object? value) => _map(value)?['supported'] == true;

List<BotEffort>? _readEfforts(Object? value) {
  if (value is! List) return null;
  return {
    for (final item in value)
      if (BotEffort.fromWire(item) case final level?
          when level != BotEffort.automatic)
        level,
  }.toList();
}
