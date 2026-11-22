import 'ledger.dart';

enum StartupPage {
  ledger('公共账本'),
  chores('卫生排班'),
  supplies('公共物资'),
  matters('寝室事务'),
  tools('寝室工具箱');

  const StartupPage(this.label);
  final String label;
}

enum LedgerFilter {
  all('全部账单'),
  outstanding('仅待结清'),
  currentMonth('仅本月');

  const LedgerFilter(this.label);
  final String label;
}

enum MatterView {
  board('全部状态'),
  open('待处理'),
  doing('进行中'),
  done('已完成');

  const MatterView(this.label);
  final String label;
}

enum ThemePalette {
  pine('松林绿', 0xff326454, 0xfff5f7f2, 0xff151e1a),
  ocean('海盐蓝', 0xff255e8a, 0xfff3f7fb, 0xff131b24),
  amber('暖橘棕', 0xff9a5824, 0xfffbf7f2, 0xff211a14),
  plum('暮色紫', 0xff624b8a, 0xfff7f5fb, 0xff1b1724),
  crimson('枫叶红', 0xff983b3b, 0xfffbf5f5, 0xff231616),
  slate('石墨灰', 0xff455a64, 0xfff5f7f8, 0xff171b1e);

  const ThemePalette(
    this.label,
    this.seedColor,
    this.lightSurface,
    this.darkSurface,
  );
  final String label;
  final int seedColor;
  final int lightSurface;
  final int darkSurface;
}

const maxStockQuantity = 999999;
const defaultLanPort = 8765;

class DormPreferences {
  const DormPreferences({
    this.startupPage = StartupPage.ledger,
    this.ledgerFilter = LedgerFilter.all,
    this.selectAllParticipants = true,
    this.monthlyBudget = 0,
    this.stockAlerts = true,
    this.stockThreshold = 1,
    this.matterView = MatterView.board,
    this.lanPort = defaultLanPort,
    this.themePalette = ThemePalette.pine,
    this.einkMode = false,
  });

  factory DormPreferences.fromValues(Map<String, String> values) {
    return DormPreferences(
      startupPage: _readEnum(
        StartupPage.values,
        values['startupPage'],
        StartupPage.ledger,
      ),
      ledgerFilter: _readEnum(
        LedgerFilter.values,
        values['ledgerFilter'],
        LedgerFilter.all,
      ),
      selectAllParticipants: values['selectAllParticipants'] != 'false',
      monthlyBudget: _readInt(values['monthlyBudget'], maxAmountCents, 0),
      stockAlerts: values['stockAlerts'] != 'false',
      stockThreshold: _readInt(values['stockThreshold'], maxStockQuantity, 1),
      lanPort: _readInt(values['lanPort'], 65535, defaultLanPort, minimum: 1),
      matterView: _readEnum(
        MatterView.values,
        values['matterView'],
        MatterView.board,
      ),
      themePalette: _readEnum(
        ThemePalette.values,
        values['themePalette'],
        ThemePalette.pine,
      ),
      einkMode: values['einkMode'] == 'true',
    );
  }

  final StartupPage startupPage;
  final LedgerFilter ledgerFilter;
  final bool selectAllParticipants;
  final int monthlyBudget;
  final bool stockAlerts;
  final int stockThreshold;
  final MatterView matterView;
  final int lanPort;
  final ThemePalette themePalette;
  final bool einkMode;

  DormPreferences copyWith({
    StartupPage? startupPage,
    LedgerFilter? ledgerFilter,
    bool? selectAllParticipants,
    int? monthlyBudget,
    bool? stockAlerts,
    int? stockThreshold,
    MatterView? matterView,
    int? lanPort,
    ThemePalette? themePalette,
    bool? einkMode,
  }) => DormPreferences(
    startupPage: startupPage ?? this.startupPage,
    ledgerFilter: ledgerFilter ?? this.ledgerFilter,
    selectAllParticipants: selectAllParticipants ?? this.selectAllParticipants,
    monthlyBudget: monthlyBudget ?? this.monthlyBudget,
    stockAlerts: stockAlerts ?? this.stockAlerts,
    stockThreshold: stockThreshold ?? this.stockThreshold,
    matterView: matterView ?? this.matterView,
    lanPort: lanPort ?? this.lanPort,
    themePalette: themePalette ?? this.themePalette,
    einkMode: einkMode ?? this.einkMode,
  );

  Map<String, String> toValues() => {
    'startupPage': startupPage.name,
    'ledgerFilter': ledgerFilter.name,
    'selectAllParticipants': selectAllParticipants.toString(),
    'monthlyBudget': monthlyBudget.toString(),
    'stockAlerts': stockAlerts.toString(),
    'stockThreshold': stockThreshold.toString(),
    'matterView': matterView.name,
    'lanPort': lanPort.toString(),
    'themePalette': themePalette.name,
    'einkMode': einkMode.toString(),
  };
}

T _readEnum<T extends Enum>(List<T> values, String? value, T fallback) =>
    values.firstWhere((item) => item.name == value, orElse: () => fallback);

int _readInt(String? text, int maximum, int fallback, {int minimum = 0}) {
  final value = int.tryParse(text ?? '');
  return value != null && value >= minimum && value <= maximum
      ? value
      : fallback;
}
