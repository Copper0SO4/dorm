import 'package:material_ui/material_ui.dart';

import '../data/cloud_sync.dart';
import '../domain/ledger.dart';
import '../domain/repository.dart';

class DormController extends ChangeNotifier {
  DormController(this.repository, {this.cloud}) {
    cloud?.onDataChanged = notifyListeners;
  }

  final DormRepository repository;
  final CloudSync? cloud;

  void write(void Function() action) {
    action();
    notifyListeners();
    cloud?.changed();
  }

  @override
  void dispose() {
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
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, required this.storageKey});

  final List<Widget> children;
  final String storageKey;

  @override
  Widget build(BuildContext context) => ListView(
    key: PageStorageKey(storageKey),
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
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
        const SizedBox(height: 6),
        Text(
          description,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
    final buttons = Wrap(spacing: 8, runSpacing: 8, children: actions);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 650
            ? Row(
                children: [
                  Expanded(child: copy),
                  const SizedBox(width: 16),
                  buttons,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  copy,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    buttons,
                  ],
                ],
              ),
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
    padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
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
  spacing: 14,
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
