import 'package:material_ui/material_ui.dart';

import '../game/bot_api.dart';
import '../game/bot_profile.dart';
import 'common.dart';

Future<void> showBotApiDialog(
  BuildContext context,
  DormController controller, {
  BotApiSettings api = const BotApiSettings(),
}) => showDialog<void>(
  context: context,
  builder: (_) => _BotApiDialog(controller: controller, api: api),
);

class _BotApiDialog extends StatefulWidget {
  const _BotApiDialog({required this.controller, required this.api});

  final DormController controller;
  final BotApiSettings api;

  @override
  State<_BotApiDialog> createState() => _BotApiDialogState();
}

class _BotApiDialogState extends State<_BotApiDialog> {
  late final _stored = BotProfile.fromPreferences(
    widget.controller.repository.preferences,
  );
  late var _enabled = _stored.enabled;
  late var _provider = _stored.provider;
  late var _effort = _stored.effectiveEffort;
  late final _base = TextEditingController(text: _stored.baseUrl);
  late final _model = TextEditingController(text: _stored.model);
  final _key = TextEditingController();
  late List<BotModel> _models = [?_stored.modelInfo];
  var _loaded = false;
  var _clearKey = false;
  var _obscure = true;
  String? _working;
  String? _error;
  String? _success;

  BotProfile _draft({required String key, required bool enabled}) => BotProfile(
    enabled: enabled,
    provider: _provider,
    baseUrl: _base.text.trim(),
    model: _model.text.trim(),
    effort: _effort,
    apiKey: key,
    modelInfo: _models
        .where((entry) => entry.id == _model.text.trim())
        .firstOrNull,
  );

  bool get _canKeepKey =>
      _stored.apiKey.isNotEmpty &&
      _draft(key: '', enabled: false).sameDestination(_stored);

  String get _effectiveKey {
    final entered = _key.text.trim();
    if (entered.isNotEmpty) return entered;
    return _canKeepKey && !_clearKey ? _stored.apiKey : '';
  }

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  void _clearMessage() {
    _error = null;
    _success = null;
  }

  void _credentialsChanged() {
    setState(() {
      _models = [];
      _loaded = false;
      _clearMessage();
    });
  }

  void _switchProvider(BotProvider next) {
    if (next == _provider) return;
    setState(() {
      final original = next == _stored.provider;
      _base.text = original ? _stored.baseUrl : next.defaultBase;
      _model.text = original ? _stored.model : next.defaultModel;
      _effort = original ? _stored.effectiveEffort : next.defaultEffort;
      _models = original ? [?_stored.modelInfo] : [];
      _loaded = false;
      _key.clear();
      _clearMessage();
      _provider = next;
    });
  }

  Future<void> _check(
    String label,
    Future<void> Function(BotProfile) work,
  ) async {
    final profile = _draft(key: _effectiveKey, enabled: false);
    setState(() {
      _clearMessage();
      _working = label;
    });
    try {
      await work(profile);
    } on BotHttpException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _error = errorText(error, fallback: 'API 请求失败'));
      }
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _loadModels() async {
    await _check('正在获取模型…', (profile) async {
      final models = await widget.api.listModels(profile);
      if (!mounted) return;
      setState(() {
        _models = models;
        _loaded = true;
        _success = models.isEmpty ? '接口没有返回可用模型' : '已获取 ${models.length} 个模型';
      });
    });
    if (mounted && _error == null && _models.isNotEmpty) await _pickModel();
  }

  Future<void> _pickModel() async {
    final model = await showDialog<BotModel>(
      context: context,
      builder: (_) =>
          _ModelPicker(models: _models, selected: _model.text.trim()),
    );
    if (model == null || !mounted) return;
    setState(() {
      _model.text = model.id;
      final profile = _draft(key: '', enabled: false);
      if (!profile.effortOptions.contains(_effort)) {
        _effort = profile.effortOptions.contains(BotEffort.low)
            ? BotEffort.low
            : (model.defaultEffort ?? BotEffort.automatic);
      }
      _clearMessage();
    });
  }

  Future<void> _testConnection() => _check('正在测试连接…', (profile) async {
    final duration = await widget.api.testConnection(profile);
    if (mounted) {
      setState(() => _success = '测试通过 · ${duration.inMilliseconds} 毫秒');
    }
  });

  void _save() {
    final key = _effectiveKey;
    final profile = _draft(
      key: key,
      enabled: _enabled && !(_clearKey && key.isEmpty),
    );
    final problem = profile.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    try {
      widget.controller.updatePreferences(
        (current) => current.copyWith(
          botApiEnabled: profile.enabled,
          botProvider: profile.provider.name,
          botApiBase: profile.baseUrl,
          botApiModel: profile.model,
          botEffort: profile.effectiveEffort.name,
          botApiKey: profile.apiKey,
          botModelMetadata: profile.modelInfo?.encode() ?? '',
        ),
      );
      Navigator.pop(context);
    } catch (error) {
      setState(() => _error = errorText(error, fallback: '保存 API 设置失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _working != null;
    final profile = _draft(key: '', enabled: false);
    final metadata = profile.modelInfo;
    final theme = Theme.of(context);
    final effortHelp = metadata?.efforts != null
        ? '等级来自模型接口。'
        : profile.effortOptions.length == 1
        ? '当前模型使用服务端默认配置。'
        : _loaded
        ? '模型列表未公布等级，可测试当前配置。'
        : '可获取模型及其公布的思考等级。';
    return AlertDialog(
      scrollable: true,
      title: const Text('电脑 API'),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              'AI 出牌和提示使用房主的 API，单次最多等待 ${botDecisionTimeout.inSeconds} 秒。'
              '一局内第 $botTimeoutLimit 次超时后，自动出牌由本地电脑接管。连接测试会发送一条简短消息。',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用电脑 API'),
              subtitle: const Text('开启后可添加 API 电脑、选择 API 托管并使用 AI 提示'),
              value: _enabled,
              onChanged: busy
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final provider in BotProvider.values)
                  ChoiceChip(
                    label: Text(provider.label),
                    selected: _provider == provider,
                    onSelected: busy ? null : (_) => _switchProvider(provider),
                  ),
              ],
            ),
            TextField(
              controller: _base,
              enabled: !busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => _credentialsChanged(),
              decoration: const InputDecoration(labelText: 'API 地址'),
            ),
            TextField(
              controller: _key,
              enabled: !busy,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (_) => _credentialsChanged(),
              decoration: InputDecoration(
                labelText: 'API 密钥',
                hintText: !_canKeepKey || _clearKey ? '粘贴密钥' : '留空则保留当前地址的密钥',
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示' : '隐藏',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            if (_canKeepKey)
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        _clearKey = !_clearKey;
                        _clearMessage();
                      }),
                child: Text(_clearKey ? '撤销清除密钥' : '清除密钥并关闭 API'),
              ),
            TextField(
              controller: _model,
              enabled: !busy,
              autocorrect: false,
              onChanged: (_) => setState(_clearMessage),
              decoration: const InputDecoration(labelText: '模型'),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : _loadModels,
                  child: Text(_loaded ? '刷新模型' : '获取模型'),
                ),
                if (_loaded && _models.isNotEmpty)
                  TextButton(
                    onPressed: busy ? null : _pickModel,
                    child: Text('选择模型（${_models.length}）'),
                  ),
                OutlinedButton(
                  onPressed: busy ? null : _testConnection,
                  child: const Text('测试连接'),
                ),
              ],
            ),
            const Text('思考等级'),
            Wrap(
              spacing: 8,
              runSpacing: 5,
              children: [
                for (final effort in profile.effortOptions)
                  ChoiceChip(
                    label: Text(
                      effort == BotEffort.automatic &&
                              metadata?.defaultEffort != null
                          ? '服务端默认（${metadata!.defaultEffort!.label}）'
                          : effort.label,
                    ),
                    selected: profile.effectiveEffort == effort,
                    onSelected: busy
                        ? null
                        : (_) => setState(() {
                            _effort = effort;
                            _clearMessage();
                          }),
                  ),
              ],
            ),
            Text(effortHelp, style: theme.textTheme.bodySmall),
            if (_working case final message?)
              Row(
                spacing: 8,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  Text(message),
                ],
              ),
            if ((_error ?? _success) case final message?)
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  style: TextStyle(
                    color: _error == null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: busy ? null : _save, child: const Text('保存')),
      ],
    );
  }
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.selected});

  final List<BotModel> models;
  final String selected;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.models
        .where((model) => model.label.toLowerCase().contains(_query))
        .toList();
    return AlertDialog(
      title: const Text('从 API 选择模型'),
      content: SizedBox(
        width: 420,
        height: (MediaQuery.sizeOf(context).height * .43).clamp(100.0, 340.0),
        child: Column(
          spacing: 8,
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: '搜索模型',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('没有匹配的模型'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final model = filtered[index];
                        return ListTile(
                          title: Text(
                            model.name.isEmpty ? model.id : model.name,
                          ),
                          subtitle: model.name == model.id || model.name.isEmpty
                              ? null
                              : Text(model.id),
                          selected: model.id == widget.selected,
                          onTap: () => Navigator.pop(context, model),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
