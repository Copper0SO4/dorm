import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_identity.dart';
import '../domain/models.dart';
import '../domain/preferences.dart';
import 'chores_page.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'me_page.dart';
import 'matters_page.dart';
import 'settings_page.dart';
import 'supplies_page.dart';
import 'tools_page.dart';

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

ThemeData dormTheme(
  Brightness brightness, {
  ThemePalette palette = ThemePalette.pine,
  bool eink = false,
}) {
  final dark = brightness == Brightness.dark;
  final ColorScheme colors;
  if (eink) {
    colors = dark
        ? const ColorScheme.dark(
            primary: Color(0xfff5f5f5),
            onPrimary: Color(0xff000000),
            primaryContainer: Color(0xff262626),
            onPrimaryContainer: Color(0xfff5f5f5),
            secondary: Color(0xffcccccc),
            onSecondary: Color(0xff000000),
            secondaryContainer: Color(0xff2a2a2a),
            onSecondaryContainer: Color(0xfff5f5f5),
            surface: Color(0xff000000),
            onSurface: Color(0xfff5f5f5),
            surfaceContainerLow: Color(0xff0b0b0b),
            surfaceContainerHighest: Color(0xff1a1a1a),
            onSurfaceVariant: Color(0xffd4d4d4),
            outline: Color(0xffe5e5e5),
            outlineVariant: Color(0xff888888),
            error: Color(0xfff5f5f5),
            onError: Color(0xff000000),
          )
        : const ColorScheme.light(
            primary: Color(0xff111111),
            onPrimary: Color(0xffffffff),
            primaryContainer: Color(0xffe6e6e6),
            onPrimaryContainer: Color(0xff111111),
            secondary: Color(0xff333333),
            onSecondary: Color(0xffffffff),
            secondaryContainer: Color(0xffe8e8e8),
            onSecondaryContainer: Color(0xff111111),
            surface: Color(0xffffffff),
            onSurface: Color(0xff111111),
            surfaceContainerLow: Color(0xffffffff),
            surfaceContainerHighest: Color(0xfff0f0f0),
            onSurfaceVariant: Color(0xff333333),
            outline: Color(0xff111111),
            outlineVariant: Color(0xff444444),
            error: Color(0xff111111),
            onError: Color(0xffffffff),
          );
  } else {
    colors =
        ColorScheme.fromSeed(
          seedColor: Color(palette.seedColor),
          brightness: brightness,
        ).copyWith(
          surface: Color(dark ? palette.darkSurface : palette.lightSurface),
          surfaceContainerLow: dark
              ? Color.alphaBlend(
                  const Color(0x14ffffff),
                  Color(palette.darkSurface),
                )
              : const Color(0xfffdfefa),
        );
  }
  final base = ThemeData(
    useMaterial3: true,
    fontFamilyFallback: const ['NotoSansSC'],
    colorScheme: colors,
    brightness: brightness,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(eink ? 14 : 20),
    side: BorderSide(
      width: eink ? 1.2 : 1,
      color: eink
          ? colors.outlineVariant
          : colors.outlineVariant.withValues(alpha: 0.55),
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: colors.surface,
    splashFactory: eink ? NoSplash.splashFactory : null,
    highlightColor: eink ? Colors.transparent : null,
    pageTransitionsTheme: eink
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _NoTransitionsBuilder(),
              TargetPlatform.windows: _NoTransitionsBuilder(),
              TargetPlatform.linux: _NoTransitionsBuilder(),
            },
          )
        : null,
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: shape,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: eink
          ? colors.surface
          : colors.surfaceContainerHighest.withValues(alpha: 0.38),
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
  late var _palette = widget.controller.repository.preferences.themePalette;
  late var _eink = widget.controller.repository.preferences.einkMode;
  late var _uiScale = widget.controller.repository.preferences.uiScale;
  late StartupPage _selected =
      widget.controller.repository.preferences.startupPage;
  final _storage = PageStorageBucket();

  static const _destinations = [
    (
      page: StartupPage.ledger,
      short: '账本',
      icon: Icons.receipt_long_outlined,
      selected: Icons.receipt_long_rounded,
    ),
    (
      page: StartupPage.chores,
      short: '排班',
      icon: Icons.calendar_month_outlined,
      selected: Icons.calendar_month_rounded,
    ),
    (
      page: StartupPage.supplies,
      short: '物资',
      icon: Icons.inventory_2_outlined,
      selected: Icons.inventory_2_rounded,
    ),
    (
      page: StartupPage.matters,
      short: '事务',
      icon: Icons.view_kanban_outlined,
      selected: Icons.view_kanban_rounded,
    ),
    (
      page: StartupPage.tools,
      short: '工具',
      icon: Icons.casino_outlined,
      selected: Icons.casino_rounded,
    ),
  ];

  void _showMe(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => MePage(controller: widget.controller)),
  );

  void _syncAppearance() {
    final mode = widget.controller.repository.appearanceMode;
    final prefs = widget.controller.repository.preferences;
    if (_mode.value != mode) _mode.value = mode;
    if (_palette != prefs.themePalette ||
        _eink != prefs.einkMode ||
        (_uiScale - prefs.uiScale).abs() > 0.001) {
      setState(() {
        _palette = prefs.themePalette;
        _eink = prefs.einkMode;
        _uiScale = prefs.uiScale;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncAppearance);
  }

  @override
  void didUpdateWidget(covariant DormApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncAppearance);
      widget.controller.addListener(_syncAppearance);
      _syncAppearance();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncAppearance);
    _mode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppearanceMode>(
    valueListenable: _mode,
    builder: (context, mode, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: dormFullName,
      theme: dormTheme(Brightness.light, palette: _palette, eink: _eink),
      darkTheme: dormTheme(Brightness.dark, palette: _palette, eink: _eink),
      themeMode: switch (mode) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      builder: (context, child) {
        final inner = child ?? const SizedBox.shrink();
        final mediaQuery = MediaQuery.of(context);
        final shortcuts = DormUiScaleScope(
          scale: _uiScale,
          onAdjust: widget.controller.adjustUiScale,
          onReset: widget.controller.resetUiScale,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.equal,
                control: true,
              ): () =>
                  widget.controller.adjustUiScale(1),
              const SingleActivator(
                LogicalKeyboardKey.equal,
                control: true,
                shift: true,
              ): () =>
                  widget.controller.adjustUiScale(1),
              const SingleActivator(
                LogicalKeyboardKey.add,
                control: true,
              ): () =>
                  widget.controller.adjustUiScale(1),
              const SingleActivator(
                LogicalKeyboardKey.numpadAdd,
                control: true,
              ): () =>
                  widget.controller.adjustUiScale(1),
              const SingleActivator(
                LogicalKeyboardKey.minus,
                control: true,
              ): () =>
                  widget.controller.adjustUiScale(-1),
              const SingleActivator(
                LogicalKeyboardKey.numpadSubtract,
                control: true,
              ): () =>
                  widget.controller.adjustUiScale(-1),
              const SingleActivator(
                LogicalKeyboardKey.digit0,
                control: true,
              ): () =>
                  widget.controller.resetUiScale(),
              const SingleActivator(
                LogicalKeyboardKey.numpad0,
                control: true,
              ): () =>
                  widget.controller.resetUiScale(),
            },
            child: inner,
          ),
        );
        final withAnimationMode = _eink
            ? MediaQuery(
                data: mediaQuery.copyWith(disableAnimations: true),
                child: shortcuts,
              )
            : shortcuts;
        if ((_uiScale - 1.0).abs() < 0.001) return withAnimationMode;
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            if (!width.isFinite ||
                !height.isFinite ||
                width <= 0 ||
                height <= 0) {
              return withAnimationMode;
            }
            final scaledWidth = width / _uiScale;
            final scaledHeight = height / _uiScale;
            return SizedBox(
              width: width,
              height: height,
              child: FittedBox(
                fit: BoxFit.fill,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: scaledWidth,
                  height: scaledHeight,
                  child: MediaQuery(
                    data: mediaQuery.copyWith(
                      size: Size(scaledWidth, scaledHeight),
                      padding: mediaQuery.padding / _uiScale,
                      viewPadding: mediaQuery.viewPadding / _uiScale,
                      viewInsets: mediaQuery.viewInsets / _uiScale,
                      systemGestureInsets:
                          mediaQuery.systemGestureInsets / _uiScale,
                      devicePixelRatio: mediaQuery.devicePixelRatio * _uiScale,
                      disableAnimations: _eink
                          ? true
                          : mediaQuery.disableAnimations,
                    ),
                    child: shortcuts,
                  ),
                ),
              ),
            );
          },
        );
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
              StartupPage.ledger => LedgerPage(controller: widget.controller),
              StartupPage.chores => ChoresPage(controller: widget.controller),
              StartupPage.supplies => SuppliesPage(
                controller: widget.controller,
              ),
              StartupPage.matters => MattersPage(controller: widget.controller),
              StartupPage.tools => ToolsPage(controller: widget.controller),
            },
          );
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.digit1,
                control: true,
              ): () =>
                  setState(() => _selected = _destinations[0].page),
              const SingleActivator(
                LogicalKeyboardKey.digit2,
                control: true,
              ): () =>
                  setState(() => _selected = _destinations[1].page),
              const SingleActivator(
                LogicalKeyboardKey.digit3,
                control: true,
              ): () =>
                  setState(() => _selected = _destinations[2].page),
              const SingleActivator(
                LogicalKeyboardKey.digit4,
                control: true,
              ): () =>
                  setState(() => _selected = _destinations[3].page),
              const SingleActivator(
                LogicalKeyboardKey.digit5,
                control: true,
              ): () =>
                  setState(() => _selected = _destinations[4].page),
            },
            child: Scaffold(
              appBar: AppBar(
                title: Text(
                  desktop ? dormFullName : dormName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: desktop
                      ? null
                      : theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                ),
                actions: [
                  if (desktop)
                    TextButton.icon(
                      onPressed: () => _showMe(context),
                      icon: const Icon(Icons.account_circle_outlined),
                      label: const Text('我'),
                    )
                  else
                    IconButton(
                      tooltip: '我',
                      icon: const Icon(Icons.account_circle_outlined),
                      onPressed: () => _showMe(context),
                    ),
                  SettingsAction(
                    controller: widget.controller,
                    themeMode: _mode,
                  ),
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
                        trailing: Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: _LocalStatus(
                                controller: widget.controller,
                              ),
                            ),
                          ),
                        ),
                        destinations: [
                          for (final item in _destinations)
                            NavigationRailDestination(
                              icon: Icon(item.icon),
                              selectedIcon: Icon(item.selected),
                              label: Text(item.page.label),
                            ),
                        ],
                        selectedIndex: _destinations.indexWhere(
                          (item) => item.page == _selected,
                        ),
                        onDestinationSelected: (index) => setState(
                          () => _selected = _destinations[index].page,
                        ),
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
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysShow,
                      selectedIndex: _destinations.indexWhere(
                        (item) => item.page == _selected,
                      ),
                      onDestinationSelected: (index) =>
                          setState(() => _selected = _destinations[index].page),
                      destinations: [
                        for (final item in _destinations)
                          NavigationDestination(
                            icon: Icon(item.icon),
                            selectedIcon: Icon(item.selected),
                            label: item.short,
                          ),
                      ],
                    ),
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
  const _LocalStatus({required this.controller});

  final DormController controller;

  @override
  Widget build(BuildContext context) {
    final cloud = controller.cloud;
    return ListenableBuilder(
      listenable: cloud ?? controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final (icon, label, color) = switch (cloud) {
          final c? when c.busy => (
            Icons.sync_rounded,
            '正在云同步…',
            colors.primary,
          ),
          final c? when c.conflict != null => (
            Icons.warning_amber_rounded,
            '云同步有冲突',
            colors.error,
          ),
          final c? when c.error != null => (
            Icons.cloud_off_rounded,
            '云同步异常',
            colors.error,
          ),
          final c? when c.settings != null => (
            Icons.cloud_done_outlined,
            '已启用云同步',
            colors.primary,
          ),
          _ => (Icons.storage_rounded, '本机离线存储', colors.primary),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color == colors.error ? color : null),
              ),
            ),
          ],
        );
      },
    );
  }
}
