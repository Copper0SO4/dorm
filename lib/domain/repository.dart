import 'matters.dart';
import 'models.dart';
import 'preferences.dart';
import 'schedule.dart';
import 'settlement.dart';

abstract interface class DormRepository {
  List<Member> members();
  void saveMember(String name, {int? id});
  void setMemberActive(int id, bool active);

  List<Bill> bills({int? supplyId});
  BillDetail billDetail(int id);
  List<Balance> balances();
  int addBill(BillDraft draft);
  void deleteBill(int id);
  void recordTransfer(int billId, int memberId, int amount);
  List<SettlementPair> openSettlements();
  List<SettlementBatch> settlementHistory();
  void recordSettlement(
    int debtorId,
    int payerId,
    Map<int, int> expected,
    int amount,
  );

  List<Matter> matters();
  int saveMatter(MatterDraft draft, {int? id});
  void setMatterStatus(int id, MatterStatus status);
  void archiveMatter(int id, bool archived);

  List<Chore> chores();
  void addChore(String title, Cadence cadence, DateTime start);
  void renameChore(int id, String title);
  void archiveChore(int id, DateTime from);
  void generateShiftsThrough(DateTime through);
  List<Shift> shifts(DateTime from, DateTime through);
  void completeShift(int id);
  void reassignShift(int id, int memberId);
  void swapShifts(int first, int second);

  List<Supply> supplies();
  void saveSupply(SupplyDraft draft, {int? id});
  void deleteSupply(int id);
  void markSupplyOrdered(int id);
  void receiveSupply(int id, int units);
  DormPreferences get preferences;
  void savePreferences(DormPreferences preferences);
  AppearanceMode get appearanceMode;
  void saveAppearanceMode(AppearanceMode mode);
  Future<void> writeBackup(String path);
  void close();
}
