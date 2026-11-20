import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/ledger_export.dart';
import '../domain/models.dart';
import '../domain/repository.dart';
import '../domain/schedule.dart';
import 'common.dart';
import 'save_document.dart';

Future<void> exportBills(BuildContext context, List<Bill> bills) async {
  final name = 'Dorm-bills-${dayKey(DateTime.now())}.csv';
  try {
    final saved = await saveDocument(
      XFile.fromData(utf8.encode(billsCsv(bills)), name: name),
      name: name,
      extension: 'csv',
      label: '账单 CSV',
      mimeType: 'text/csv',
    );
    if (saved && context.mounted) notify(context, '已导出 ${bills.length} 笔账单');
  } catch (error) {
    if (context.mounted) notify(context, errorText(error, fallback: '无法导出账单'));
  }
}

Future<void> exportBackup(
  BuildContext context,
  DormRepository repository,
) async {
  final name = 'Dorm-backup-${dayKey(DateTime.now())}.dormbak';
  try {
    final dir = await (await getTemporaryDirectory()).createTemp(
      'dorm-backup-',
    );
    try {
      final path = '${dir.path}${Platform.pathSeparator}$name';
      await repository.writeBackup(path);
      if (!context.mounted) return;
      final saved = await saveDocument(
        XFile(path),
        name: name,
        extension: 'dormbak',
        label: 'Dorm 本地备份',
      );
      if (saved && context.mounted) notify(context, '已保存本地备份');
    } finally {
      await dir.delete(recursive: true);
    }
  } catch (error) {
    if (context.mounted) {
      notify(context, errorText(error, fallback: '无法生成本地备份'));
    }
  }
}
