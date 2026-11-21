import 'identity.dart';
import 'matters.dart';
import 'models.dart';
import 'preferences.dart';
import 'schedule.dart';
import 'settlement.dart';

abstract interface class DormRepository {
  List<Member> members();
  MyIdentity get identity;
  void claimMember(int id);
  void releaseMember();
  List<AuditEntry> memberActivity(int id);
  void saveMember(
    String name, {
    int? id,
    String? avatar,
    bool clearAvatar = false,
    String? expectedIdentityCode,
  });
  void setMemberActive(int id, bool active);

  List<Bill> bills({int? supplyId});
  BillDetail billDetail(int id);
  List<Balance> balances();
  int addBill(BillDraft draft, {String? browserDevice});
  void updateBill(
    int id,
    BillDraft draft, {
    required String expectedVersion,
    String? browserDevice,
  });
  void deleteBill(int id, {String? browserDevice});
  void recordTransfer(
    int billId,
    int memberId,
    int amount, {
    String? browserDevice,
  });
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
