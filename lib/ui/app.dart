import 'package:material_ui/material_ui.dart';

import '../app_identity.dart';
import '../domain/models.dart';
import 'chores_page.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'matters_page.dart';
import 'settings_page.dart';
import 'supplies_page.dart';

ThemeData dormTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff326454),
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xff151e1a) : const Color(0xfff5f7f2),
        surfaceContainerLow: dark
            ? const Color(0xff202a24)
            : const Color(0xfffdfefa),
      );
  final base = ThemeData(
    useMaterial3: true,
    fontFamilyFallback: const ['NotoSansSC'],
    colorScheme: colors,
    brightness: brightness,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(20),
    side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.55)),
  );
  return base.copyWith(
    scaffoldBackgroundColor: colors.surface,
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: shape,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.38),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class DormApp extends StatefulWidget {
  const DormApp({super.key, required this.controller});

  final DormController controller;

  @override
  State<DormApp> createState() => _DormAppState();
}

class _DormAppState extends State<DormApp> {
  late final _mode = ValueNotifier(widget.controller.repository.appearanceMode);
  late int _selected =
      widget.controller.repository.preferences.startupPage.index;
  final _storage = PageStorageBucket();

  static const _destinations = [
    (
      label: '公共账本',
      short: '账本',
      icon: Icons.receipt_long_outlined,
      selected: Icons.receipt_long_rounded,
    ),
    (
      label: '卫生排班',
      short: '排班',
      icon: Icons.calendar_month_outlined,
      selected: Icons.calendar_month_rounded,
    ),
    (
      label: '公共物资',
      short: '物资',
      icon: Icons.inventory_2_outlined,
      selected: Icons.inventory_2_rounded,
    ),
    (
      label: '寝室事务',
      short: '事务',
      icon: Icons.view_kanban_outlined,
      selected: Icons.view_kanban_rounded,
    ),
  ];

  @override
  void dispose() {
    _mode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppearanceMode>(
    valueListenable: _mode,
    builder: (context, mode, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: dormFullName,
      theme: dormTheme(Brightness.light),
      darkTheme: dormTheme(Brightness.dark),
      themeMode: switch (mode) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 830;
          final theme = Theme.of(context);
          final page = PageStorage(
            bucket: _storage,
            child: switch (_selected) {
              0 => LedgerPage(controller: widget.controller),
              1 => ChoresPage(controller: widget.controller),
              2 => SuppliesPage(controller: widget.controller),
              _ => MattersPage(controller: widget.controller),
            },
          );
          return Scaffold(
            appBar: AppBar(
              title: Text(
                dormFullName,
                maxLines: desktop ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: desktop ? null : theme.textTheme.titleMedium,
              ),
              actions: [
                SettingsAction(controller: widget.controller, themeMode: _mode),
                const SizedBox(width: 12),
              ],
            ),
            body: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (desktop) ...[
                    NavigationRail(
                      extended: true,
                      minExtendedWidth: 204,
                      backgroundColor: theme.colorScheme.surfaceContainerLow,
                      leading: const Padding(
                        padding: EdgeInsets.fromLTRB(12, 14, 12, 28),
                        child: _Brand(),
                      ),
                      trailing: const Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: _LocalStatus(),
                          ),
                        ),
                      ),
                      destinations: [
                        for (final item in _destinations)
                          NavigationRailDestination(
                            icon: Icon(item.icon),
                            selectedIcon: Icon(item.selected),
                            label: Text(item.label),
                          ),
                      ],
                      selectedIndex: _selected,
                      onDestinationSelected: (index) =>
                          setState(() => _selected = index),
                    ),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(child: page),
                ],
              ),
            ),
            bottomNavigationBar: desktop
                ? null
                : NavigationBar(
                    selectedIndex: _selected,
                    onDestinationSelected: (index) =>
                        setState(() => _selected = index),
                    destinations: [
                      for (final item in _destinations)
                        NavigationDestination(
                          icon: Icon(item.icon),
                          selectedIcon: Icon(item.selected),
                          label: item.short,
                        ),
                    ],
                  ),
          );
        },
      ),
    ),
  );
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            Icons.other_houses_rounded,
            color: theme.colorScheme.onPrimary,
            size: 22,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          dormName,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
          ),
        ),
      ],
    );
  }
}

class _LocalStatus extends StatelessWidget {
  const _LocalStatus();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        Icons.storage_rounded,
        size: 17,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: 8),
      const Text('本机离线存储'),
    ],
  );
}
