import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

import '../data/cloud_sync.dart';
import '../data/lan_api.dart';
import '../data/lan_server.dart';
import '../domain/ledger.dart';
import '../domain/preferences.dart';
import '../domain/repository.dart';
import '../game/card_session.dart';

class DormController extends ChangeNotifier {
  DormController(this.repository, {this.cloud}) {
    cloud?.onDataChanged = notifyListeners;
  }

  final DormRepository repository;
  final CloudSync? cloud;
  DormLanServer? _lan;
  CardSession? _cards;
  CardSession get cards => _cards ??= CardSession(() => cloud?.cardMailbox);
  DormLanServer get lan =>
      _lan ??= DormLanServer(LanApi(repository, write), rootBundle.loadString);

  void write(void Function() action) {
    action();
    notifyListeners();
    cloud?.changed();
  }

  void updatePreferences(DormPreferences Function(DormPreferences) update) {
    repository.savePreferences(update(repository.preferences));
    notifyListeners();
  }

  Future<void> resetFactory({
    bool keepRepository = false,
    bool clearRemote = false,
  }) async {
    Future<void> clearLocal() async {
      repository.resetFactory(
        keepCloudSettings: keepRepository && cloud?.settings != null,
        rememberEmptyCloudBase:
            keepRepository && cloud?.settings != null && clearRemote,
      );
      notifyListeners();
    }

    if (cloud != null) {
      await cloud!.resetData(
        clearLocal: clearLocal,
        keepRepository: keepRepository,
        clearRemote: clearRemote,
      );
    } else {
      await clearLocal();
    }
  }

  @override
  void dispose() {
    _cards?.dispose();
    _lan?.dispose();
    cloud?.dispose();
    super.dispose();
  }
}

String errorText(Object error, {String fallback = '操作失败，请重试。'}) {
  if (error is InputException) return error.message;
  debugPrint('Dorm operation failed: ${error.runtimeType}');
  return fallback;
}

void notify(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

void perform(
  BuildContext context,
  DormController controller,
  void Function() action,
  String success,
) {
  try {
    controller.write(action);
    notify(context, success);
  } catch (error) {
    notify(context, errorText(error));
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

const panelGap = 16.0;
const sectionGap = 20.0;

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, required this.storageKey});

  final List<Widget> children;
  final String storageKey;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = switch (constraints.maxWidth) {
        >= 1000 => const EdgeInsets.fromLTRB(32, 24, 32, 32),
        >= 600 => const EdgeInsets.fromLTRB(24, 20, 24, 28),
        _ => const EdgeInsets.fromLTRB(16, 16, 16, 24),
      };
      return ListView(
        key: PageStorageKey(storageKey),
        padding: inset,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      );
    },
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading(
    this.title,
    this.description, {
    super.key,
    this.actions = const [],
  });

  final String title;
  final String description;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: sectionGap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (actions.isEmpty) return copy;
          final wide = constraints.maxWidth >= 760;
          final buttons = Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: wide ? WrapAlignment.end : WrapAlignment.start,
            children: actions,
          );
          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [copy, buttons],
            );
          }
          return Row(
            spacing: sectionGap,
            children: [
              Expanded(child: copy),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .60,
                ),
                child: buttons,
              ),
            ],
          );
        },
      ),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, sectionGap, 0, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: panelGap, vertical: 24),
      child: Column(
        children: [
          IconTile(icon),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, size: 20, color: colors.onPrimaryContainer),
    );
  }
}

class EditorDialog extends StatefulWidget {
  const EditorDialog({
    super.key,
    required this.title,
    required this.fields,
    required this.onSave,
    this.action = '保存',
  });

  final String title;
  final Widget fields;
  final VoidCallback onSave;
  final String action;

  @override
  State<EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends State<EditorDialog> {
  final _form = GlobalKey<FormState>();
  String? _error;

  void _save() {
    if (!_form.currentState!.validate()) return;
    try {
      widget.onSave();
      Navigator.pop(context, true);
    } catch (error) {
      setState(() => _error = errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 470,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.fields,
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: Text(widget.action)),
    ],
  );
}

Widget fieldColumn(List<Widget> children) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.stretch,
  spacing: 16,
  children: children,
);

Widget textField(
  String label,
  String initial,
  ValueChanged<String> onChanged, {
  int limit = 80,
  bool required = true,
  bool autofocus = false,
  int maxLines = 1,
}) => TextFormField(
  initialValue: initial,
  onChanged: onChanged,
  maxLength: limit,
  maxLines: maxLines,
  autofocus: autofocus,
  decoration: InputDecoration(labelText: label, counterText: ''),
  validator: (value) =>
      required && (value ?? '').trim().isEmpty ? '请填写$label' : null,
);

String localTime(BuildContext context, String value) {
  final local = DateTime.parse(value).toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatCompactDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}
