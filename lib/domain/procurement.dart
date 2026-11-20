import 'models.dart';
import 'preferences.dart';

bool isLowStock(Supply item, DormPreferences preferences) =>
    preferences.stockAlerts && item.quantity <= preferences.stockThreshold;

bool needsPurchase(Supply item, DormPreferences preferences) =>
    item.status == PurchaseStatus.needed ||
    (item.status == PurchaseStatus.stocked && isLowStock(item, preferences));
