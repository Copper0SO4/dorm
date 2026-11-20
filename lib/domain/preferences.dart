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

  DormPreferences copyWith({
    StartupPage? startupPage,
    LedgerFilter? ledgerFilter,
    bool? selectAllParticipants,
    int? monthlyBudget,
    bool? stockAlerts,
    int? stockThreshold,
    MatterView? matterView,
    int? lanPort,
  }) => DormPreferences(
    startupPage: startupPage ?? this.startupPage,
    ledgerFilter: ledgerFilter ?? this.ledgerFilter,
    selectAllParticipants: selectAllParticipants ?? this.selectAllParticipants,
    monthlyBudget: monthlyBudget ?? this.monthlyBudget,
    stockAlerts: stockAlerts ?? this.stockAlerts,
    stockThreshold: stockThreshold ?? this.stockThreshold,
    matterView: matterView ?? this.matterView,
    lanPort: lanPort ?? this.lanPort,
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
