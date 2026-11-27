import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../domain/cloud.dart';
import '../domain/ledger.dart';
import '../game/card_mailbox.dart';
import 'cloud_proxy.dart';
import 'dorm_invite.dart';
import 'github_transport.dart';
import 'ssh_vault.dart';

class CloudConflict {
  const CloudConflict({
    required this.local,
    required this.remote,
    required this.message,
    this.merge,
  });

  final CloudSnapshot local;
  final RemoteCloud? remote;
  final String message;
  final CloudMerge? merge;
}

class CloudSync extends ChangeNotifier {
  CloudSync(this._store, this._vault, this._transport, {this._initialize});

  final CloudStore _store;
  final SshVault _vault;
  final CloudTransport _transport;
  final Future<void> Function()? _initialize;
  Future<void>? _initialized;
  VoidCallback? onDataChanged;
  Timer? _debounce;
  Timer? _poll;
  bool _disposed = false;
  bool _busy = false;
  bool _repeat = false;
  String? _error;
  CloudConflict? _conflict;
  DateTime? _lastSynced;

  CloudSettings? get settings => _store.settings;
  bool get busy => _busy;
  String? get error => _error;
  CloudConflict? get conflict => _conflict;
  DateTime? get lastSynced => _lastSynced;

  CardMailbox? get cardMailbox {
    final current = settings;
    final transport = _transport;
    if (current == null || transport is! GitHubTransport) return null;
    return transport.cardMailbox(current, () {
      if (_disposed || settings?.repository != current.repository) {
        throw const InputException('GitHub 仓库已更改，请重新进入在线大厅');
      }
      return _key(current);
    }, readProxy);
  }

  Future<CloudProxy?> readProxy() => _vault.readProxy();

  Future<void> saveProxy(CloudProxy? proxy) async {
    await _vault.saveProxy(proxy);
    if (_disposed || settings == null) return;
    // An in-flight pull and push keep using the same route.
    if (_busy) {
      _repeat = true;
    } else {
      unawaited(sync());
    }
  }

  Future<String?> devicePublicKey() async =>
      (await _vault.readDevice())?.publicKey;

  Future<String> generateDevicePublicKey() async =>
      (await _vault.generateDevice()).publicKey;

  Future<DormInvite> exportInvite({
    bool includeKey = false,
    String? password,
  }) async {
    final current = settings;
    if (current == null) throw const InputException('请先配置 GitHub 仓库');
    final invite = DormInvite(current.repository);
    if (password != null) {
      return invite.withSharedKey(await _readKey(current), password);
    }
    if (includeKey) {
      return invite.withDirectKey(await _readKey(current));
    }
    return invite;
  }

  Future<void> startup() async {
    _poll ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_busy) unawaited(sync());
    });
    await sync().timeout(const Duration(seconds: 8), onTimeout: () {});
  }

  Future<void> configure(CloudSettings settings, CloudKey? newKey) async {
    if (_busy) throw const InputException('同步正在进行，请稍后再保存配置');
    _setBusy();
    try {
      if (settings.useDeviceKey) {
        if (await _vault.readDevice() == null) {
          throw const InputException('请先生成设备 SSH 密钥');
        }
      } else if (newKey != null) {
        await _vault.save(settings.repository, newKey);
      } else if (await _vault.read(settings.repository) == null) {
        throw const InputException('请选择设备密钥，或粘贴仓库的 SSH 私钥');
      }
      if (_disposed) return;
      final changedRepository =
          _store.settings?.repository != settings.repository;
      _store.saveSettings(settings);
      if (changedRepository) {
        _conflict = null;
        _lastSynced = null;
      }
    } finally {
      _finish();
    }
    await sync().timeout(const Duration(seconds: 8), onTimeout: () {});
  }

  Future<void> disconnect() async {
    if (_busy) throw const InputException('同步正在进行，请稍后再断开连接');
    final current = settings;
    if (current == null) return;
    _setBusy();
    try {
      await _vault.remove(current.repository);
      if (_disposed) return;
      _store.saveSettings(null);
      _conflict = null;
      _lastSynced = null;
    } finally {
      _finish();
    }
  }

  Future<void> resetData({
    required Future<void> Function() clearLocal,
    bool keepRepository = false,
    bool clearRemote = false,
  }) async {
    if (_busy) throw const InputException('同步正在进行，请稍后再试');
    final current = settings;
    final mailbox = cardMailbox;
    _debounce?.cancel();
    _repeat = false;
    _setBusy();
    try {
      if (current != null && clearRemote) {
        final key = await _key(current);
        final proxy = await readProxy();
        final empty = CloudSnapshot({});
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            if (_disposed) return;
            final remote = await _transport.pull(current, key, proxy: proxy);
            if (_disposed) return;
            if (remote != null && !remote.data.isEmpty) {
              await _transport.push(
                current,
                key,
                empty,
                remote.revision,
                proxy: proxy,
              );
            }
            break;
          } on CloudRace {
            if (attempt == 1) {
              throw const InputException('云端在清空时又有更新，请稍后重试');
            }
          }
        }
        if (mailbox != null) {
          for (var attempt = 0; attempt < 2; attempt++) {
            try {
              if (_disposed) return;
              final remoteCards = await mailbox.pull();
              if (_disposed) return;
              if (remoteCards != null && remoteCards.body.trim() != '{}') {
                await mailbox.push('{}', remoteCards.revision);
              }
              break;
            } on CardMailboxRace {
              if (attempt == 1) {
                throw const InputException('在线牌桌在清空时又有更新，请稍后重试');
              }
            }
          }
        }
      }
      if (current != null && !keepRepository) {
        await _vault.remove(current.repository);
        if (_disposed) return;
      }
      await clearLocal();
      if (_disposed) return;
      _conflict = null;
      _error = null;
      _lastSynced = (keepRepository && current != null && clearRemote)
          ? DateTime.now()
          : null;
    } finally {
      _finish();
    }
  }

  void changed() {
    if (_disposed || settings == null) return;
    if (_busy) {
      _repeat = true;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(sync()),
    );
  }

  Future<void> sync() async {
    if (_disposed || _busy) return;
    final current = settings;
    if (current == null) return;
    _debounce?.cancel();
    _setBusy();
    try {
      final key = await _key(current);
      final proxy = await readProxy();
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          if (_disposed) return;
          await _synchronize(current, key, proxy);
          return;
        } on CloudRace {
          if (attempt == 1) throw const InputException('云端在同步时又有更新，稍后将重新拉取');
        }
      }
    } catch (error) {
      _error = _message(error);
    } finally {
      _finish();
    }
  }

  Future<void> _synchronize(
    CloudSettings current,
    CloudKey key,
    CloudProxy? proxy,
  ) async {
    var remote = await _transport.pull(current, key, proxy: proxy);
    if (_disposed) return;
    var local = _store.snapshot();
    final base = _store.base;
    if (remote == null) {
      if (_conflict case final pending?
          when pending.remote == null && pending.local.sameAs(local)) {
        return;
      }
      if (base != null && !base.isEmpty) {
        _conflict = CloudConflict(
          local: local,
          remote: null,
          message: '云端数据分支已被移除，请选择要保留的数据',
        );
        return;
      }
      await _upload(current, key, local, null, proxy);
      _conflict = null;
      return;
    }
    // Claim conflicts are withdrawn even if business changes need manual review.
    final localClaims = local.withClaimConflicts(remote.data);
    final remoteClaims = remote.data.withClaimConflicts(local);
    if (!localClaims.sameAs(local)) {
      _apply(local, localClaims, base);
      local = localClaims;
    }
    if (!remoteClaims.sameAs(remote.data)) {
      await _transport.push(
        current,
        key,
        remoteClaims,
        remote.revision,
        proxy: proxy,
      );
      if (_disposed) return;
      remote = await _transport.pull(current, key, proxy: proxy);
      if (_disposed) return;
      if (remote == null || !remote.data.sameAs(remoteClaims)) {
        throw const CloudRace();
      }
      local = _store.snapshot();
    }
    if (_conflict case final pending?
        when pending.remote?.revision == remote.revision &&
            pending.local.sameAs(local)) {
      return;
    }
    if (local.sameAs(remote.data)) {
      _conflict = null;
      _remember(remote.data);
      return;
    }
    if (base == null &&
        local.hasBusinessData &&
        remote.data.hasBusinessData &&
        !local.sameBusinessData(remote.data)) {
      _conflict = CloudConflict(
        local: local,
        remote: remote,
        message: '首次连接时，本机和仓库均已有数据，请选择初始版本',
      );
      return;
    }
    final plan = CloudMerge(local, remote.data, base ?? CloudSnapshot({}));
    if (plan.conflicts.isNotEmpty) {
      _conflict = CloudConflict(
        local: local,
        remote: remote,
        message: '本机和云端修改了同一条记录',
        merge: plan,
      );
      return;
    }
    final merged = plan.resolve({});
    try {
      _apply(local, merged, remote.data);
    } on Object catch (error) {
      if (error is! SqliteException && error is! InputException) rethrow;
      _conflict = CloudConflict(
        local: local,
        remote: remote,
        message: error is InputException
            ? error.message
            : '合并后的成员、账单或排班存在数据关系冲突',
      );
      return;
    }
    _conflict = null;
    if (merged.sameAs(remote.data)) {
      _remember(remote.data);
    } else {
      await _upload(current, key, merged, remote.revision, proxy);
    }
  }

  Future<void> resolve({
    Map<int, CloudSide> choices = const {},
    CloudSide? entire,
  }) async {
    final decision = _conflict;
    final current = settings;
    if (decision == null || current == null || _busy) return;
    final remoteData = decision.remote?.data ?? CloudSnapshot({});
    final chosen = switch (entire) {
      CloudSide.local => decision.local.withIdentityHistory(
        decision.local,
        remoteData,
      ),
      CloudSide.remote => remoteData.withIdentityHistory(
        decision.local,
        remoteData,
      ),
      null =>
        decision.merge?.resolve(choices) ??
            (throw const InputException('请选择一个完整版本')),
    };
    _setBusy();
    try {
      final key = await _key(current);
      final proxy = await readProxy();
      if (_disposed) return;
      final local = _store.snapshot();
      if (!local.sameAs(decision.local)) {
        _conflict = null;
        _repeat = true;
        throw const InputException('本机数据已更新，正在重新计算冲突');
      }
      _apply(local, chosen, remoteData);
      _conflict = null;
      if (decision.remote != null && chosen.sameAs(remoteData)) {
        _remember(remoteData);
      } else {
        await _upload(current, key, chosen, decision.remote?.revision, proxy);
      }
    } on CloudRace {
      _repeat = true;
    } on SqliteException {
      throw const InputException('所选版本组合无法通过数据校验，请调整选择，或保留一侧完整版本');
    } on InputException catch (error) {
      if (_conflict != null) rethrow;
      _error = error.message;
    } catch (error) {
      _error = _message(error);
    } finally {
      _finish();
    }
  }

  Future<CloudKey> _key(CloudSettings current) async {
    _initialized ??= _initialize?.call() ?? Future<void>.value();
    await _initialized;
    return _readKey(current);
  }

  Future<CloudKey> _readKey(CloudSettings current) async {
    final key = current.useDeviceKey
        ? await _vault.readDevice()
        : await _vault.read(current.repository);
    return key ?? (throw const InputException('SSH 私钥未找到，请重新配置'));
  }

  void _apply(CloudSnapshot local, CloudSnapshot merged, CloudSnapshot? base) {
    if (local.sameAs(merged)) {
      if (base != null) _store.rememberBase(base);
    } else {
      _store.accept(merged, base);
      onDataChanged?.call();
    }
  }

  Future<void> _upload(
    CloudSettings current,
    CloudKey key,
    CloudSnapshot data,
    String? revision,
    CloudProxy? proxy,
  ) async {
    await _transport.push(current, key, data, revision, proxy: proxy);
    if (!_disposed) _remember(data);
  }

  void _remember(CloudSnapshot data) {
    _store.rememberBase(data);
    _lastSynced = DateTime.now();
  }

  String _message(Object error) =>
      error is InputException ? error.message : '云端同步暂不可用，操作仍保存在本机';

  void _setBusy() {
    _busy = true;
    _error = null;
    notifyListeners();
  }

  void _finish() {
    _busy = false;
    if (_disposed) return;
    notifyListeners();
    if (_repeat) {
      _repeat = false;
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _poll?.cancel();
    super.dispose();
  }
}
