import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:git2dart/git2dart.dart' as git;

import '../domain/cloud.dart';
import '../domain/ledger.dart';
import 'cloud_proxy.dart';
import 'ssh_vault.dart';

typedef RemoteCloud = ({String revision, String author, CloudSnapshot data});

abstract interface class CloudTransport {
  Future<RemoteCloud?> pull(
    CloudSettings settings,
    CloudKey key, {
    CloudProxy? proxy,
  });
  Future<void> push(
    CloudSettings settings,
    CloudKey key,
    CloudSnapshot data,
    String? expectedRevision, {
    CloudProxy? proxy,
  });
}

class CloudRace implements Exception {
  const CloudRace();
}

class GitHubTransport implements CloudTransport {
  GitHubTransport(this.directory, {this.localTestRemote});

  final Directory directory;
  final Directory? localTestRemote;

  String _path(CloudSettings settings) =>
      '${directory.path}${Platform.pathSeparator}${cloudRepositoryId(settings.repository)}';

  String _url(CloudSettings settings) =>
      localTestRemote?.uri.toString() ??
      settings.repository.replaceFirst(
        'git@github.com:',
        'ssh://git@$githubSshHost:$githubSshPort/',
      );

  @override
  Future<RemoteCloud?> pull(
    CloudSettings settings,
    CloudKey key, {
    CloudProxy? proxy,
  }) {
    return _run(settings, key, proxy, (repo, remote, callbacks) {
      if (_head(remote, callbacks) == null) return null;
      remote.fetch(refspecs: ['+$_branch:$_incoming'], callbacks: callbacks);
      final oid = git.Reference.nameToId(repo: repo, refName: _incoming);
      try {
        final commit = git.Commit.lookup(repo: repo, oid: oid);
        try {
          final tree = commit.tree;
          try {
            final entry = tree[cloudFileName];
            if (tree.length != 1 || entry.filemode != git.GitFilemode.blob) {
              throw const InputException('云端数据分支包含意外的文件');
            }
            final blobId = entry.oid;
            try {
              final blob = git.Blob.lookup(repo: repo, oid: blobId);
              try {
                if (blob.size > maxCloudBytes) {
                  throw const InputException('云端快照超过 8 MB，无法读取');
                }
                return (
                  revision: oid.sha,
                  author: commit.author.name,
                  data: CloudSnapshot.decode(utf8.decode(blob.contentBytes)),
                );
              } finally {
                blob.free();
              }
            } finally {
              blobId.free();
            }
          } finally {
            tree.free();
          }
        } finally {
          commit.free();
        }
      } finally {
        oid.free();
      }
    });
  }

  @override
  Future<void> push(
    CloudSettings settings,
    CloudKey key,
    CloudSnapshot data,
    String? expectedRevision, {
    CloudProxy? proxy,
  }) {
    final path = _path(settings);
    final encoded = data.encoded;
    final operator = settings.operator;
    final email = settings.commitEmail;
    return _run(settings, key, proxy, (repo, remote, callbacks) {
      if (_head(remote, callbacks) != expectedRevision) {
        throw const CloudRace();
      }
      final bytes = utf8.encode(encoded);
      if (bytes.length > maxCloudBytes) {
        throw const InputException('本地快照超过 8 MB，无法上传');
      }
      final stage = Directory(path).createTempSync('snapshot-');
      try {
        final file = File(
          '${stage.path}${Platform.pathSeparator}$cloudFileName',
        )..writeAsBytesSync(bytes);
        final blob = git.Blob.createFromDisk(repo: repo, path: file.path);
        try {
          final builder = git.TreeBuilder(repo: repo);
          try {
            builder.add(
              filename: cloudFileName,
              oid: blob,
              filemode: git.GitFilemode.blob,
            );
            final treeId = builder.write();
            try {
              final tree = git.Tree.lookup(repo: repo, oid: treeId);
              try {
                _publish(
                  repo,
                  remote,
                  callbacks,
                  tree,
                  operator,
                  email,
                  expectedRevision,
                );
              } finally {
                tree.free();
              }
            } finally {
              treeId.free();
            }
          } finally {
            builder.free();
          }
        } finally {
          blob.free();
        }
      } finally {
        stage.deleteSync(recursive: true);
      }
    });
  }

  Future<T> _run<T>(
    CloudSettings settings,
    CloudKey key,
    CloudProxy? proxy,
    _RemoteAction<T> action,
  ) async {
    final path = _path(settings);
    final url = _url(settings);
    final isLocal = localTestRemote != null;
    if (proxy == null || isLocal) {
      return _runRemote(path, url, key, isLocal, null, action);
    }
    final tunnel = await GitHubProxyTunnel.open(proxy);
    try {
      return await _runRemote(path, url, key, false, tunnel.port, action);
    } catch (error) {
      if (tunnel.failure case final failure?) throw failure;
      rethrow;
    } finally {
      await tunnel.close();
    }
  }
}

typedef _RemoteAction<T> = T Function(
  git.Repository,
  git.Remote,
  git.Callbacks,
);

Future<T> _runRemote<T>(
  String path,
  String url,
  CloudKey key,
  bool isLocal,
  int? tunnelPort,
  _RemoteAction<T> action,
) =>
    Isolate.run(() => _withRemote(path, url, key, isLocal, tunnelPort, action));

const _branch = 'refs/heads/$cloudBranch';
const _incoming = 'refs/remotes/origin/$cloudBranch';
const _githubFingerprints = {
  '+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU', // Ed25519
  'p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM', // ECDSA
  'uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s', // RSA
};

T _withRemote<T>(
  String path,
  String url,
  CloudKey key,
  bool isLocal,
  int? tunnelPort,
  _RemoteAction<T> action,
) {
  final expectedHost = tunnelPort == null ? githubSshHost : '127.0.0.1';
  final expectedPort = tunnelPort ?? githubSshPort;
  var rejectedHost = false;
  String? rejection;
  final callbacks = isLocal
      ? const git.Callbacks()
      : git.Callbacks(
          credentials: git.KeypairFromMemory(
            username: 'git',
            pubKey: key.publicKey,
            privateKey: key.privateKey,
            passPhrase: key.passphrase,
          ),
          certificateCheck: (certificate, host, {required valid}) {
            final fingerprint = certificate.hostkey?.sha256;
            final accepted =
                (host == expectedHost ||
                    host == '$expectedHost:$expectedPort' ||
                    host == '[$expectedHost]:$expectedPort') &&
                fingerprint != null &&
                _githubFingerprints.contains(
                  base64.encode(fingerprint).replaceAll('=', ''),
                );
            rejectedHost = !accepted;
            return accepted;
          },
          pushUpdateReference: (_, message) {
            if (message.isNotEmpty) rejection = message;
          },
        );
  try {
    Directory(path).createSync(recursive: true);
    final repo = File('$path${Platform.pathSeparator}HEAD').existsSync()
        ? git.Repository.openBare(path)
        : git.Repository.initBasic(path: path, bare: true);
    try {
      final remote = git.Remote.list(repo).contains('origin')
          ? git.Remote.lookup(repo: repo, name: 'origin')
          : git.Remote.create(
              repo: repo,
              name: 'origin',
              url: url,
              fetch: '+$_branch:$_incoming',
            );
      try {
        if (remote.url != url) throw const InputException('本地 Git 缓存的仓库地址不匹配');
        if (tunnelPort != null) {
          final forwarded = Uri.parse(url)
              .replace(host: expectedHost, port: tunnelPort)
              .toString();
          remote.url = forwarded;
          remote.pushUrl = forwarded;
        }
        final result = action(repo, remote, callbacks);
        if (rejection case final message?) {
          if (_raceMessage(message)) throw const CloudRace();
          throw const InputException('GitHub 拒绝写入，请检查 SSH Key 的仓库写权限和分支规则');
        }
        return result;
      } finally {
        remote.free();
      }
    } finally {
      repo.free();
    }
  } catch (error) {
    if (isLocal || error is InputException || error is CloudRace) rethrow;
    if (rejectedHost) throw const InputException('GitHub SSH 主机指纹核验失败，连接已断开');
    final message = error.toString().toLowerCase();
    if (_raceMessage(message)) throw const CloudRace();
    if (message.contains('authentica') ||
        message.contains('credential') ||
        message.contains('publickey')) {
      throw const InputException('GitHub 未接受 SSH Key，请检查私钥、口令及仓库权限');
    }
    throw const InputException('连接 GitHub 失败，请检查网络、仓库地址和 SSH Key 权限');
  } finally {
    git.Libgit2.shutdown();
  }
}

bool _raceMessage(String message) => RegExp(
  r'non.fast.forward|fetch first|commits that are not present|stale info',
  caseSensitive: false,
).hasMatch(message);

String? _head(git.Remote remote, git.Callbacks callbacks) {
  final references = remote.ls(callbacks: callbacks);
  try {
    return references
        .where((reference) => reference.name == _branch)
        .firstOrNull
        ?.oid
        .sha;
  } finally {
    for (final reference in references) {
      reference.oid.free();
      reference.localId?.free();
    }
  }
}

void _publish(
  git.Repository repo,
  git.Remote remote,
  git.Callbacks callbacks,
  git.Tree tree,
  String operator,
  String email,
  String? expectedRevision,
) {
  final parentId = expectedRevision == null
      ? null
      : git.Oid.fromSHA(repo, expectedRevision);
  try {
    final parent = parentId == null
        ? null
        : git.Commit.lookup(repo: repo, oid: parentId);
    try {
      final signature = git.Signature.create(name: operator, email: email);
      try {
        final outgoing =
            'refs/heads/dormos-outgoing-${DateTime.now().microsecondsSinceEpoch}';
        final commit = git.Commit.create(
          repo: repo,
          updateRef: outgoing,
          author: signature,
          committer: signature,
          message: 'Sync DormOS data',
          tree: tree,
          parents: [?parent],
        );
        commit.free();
        try {
          remote.push(refspecs: ['$outgoing:$_branch'], callbacks: callbacks);
        } finally {
          git.Reference.delete(repo: repo, name: outgoing);
        }
      } finally {
        signature.free();
      }
    } finally {
      parent?.free();
    }
  } finally {
    parentId?.free();
  }
}
