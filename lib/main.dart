import 'dart:async';
import 'dart:io';

import 'package:git2dart/git2dart.dart' as git;
import 'package:material_ui/material_ui.dart';

import 'app_identity.dart';
import 'data/cloud_sync.dart';
import 'data/github_transport.dart';
import 'data/local_directory.dart';
import 'data/ssh_vault.dart';
import 'data/sqlite_repository.dart';
import 'ui/app.dart';
import 'ui/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DormBootstrap());
}

class DormBootstrap extends StatefulWidget {
  const DormBootstrap({super.key});

  @override
  State<DormBootstrap> createState() => _DormBootstrapState();
}

class _DormBootstrapState extends State<DormBootstrap>
    with WidgetsBindingObserver {
  SqliteDormRepository? _repository;
  DormController? _controller;
  late Future<DormController> _initialization = _open();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.cloud?.sync());
    }
  }

  Future<DormController> _open() async {
    final directory = await dormDataDirectory();
    await directory.create(recursive: true);
    if (!mounted) throw StateError('Startup was interrupted');
    final repository = SqliteDormRepository.open(
      '${directory.path}${Platform.pathSeparator}dormos.sqlite3',
    );
    _repository = repository;
    final cloud = CloudSync(
      repository.cloud,
      SshVault(directory),
      GitHubTransport(
        Directory('${directory.path}${Platform.pathSeparator}cloud-git'),
      ),
      initialize: git.PlatformSpecific.initialize,
    );
    final controller = _controller = DormController(repository, cloud: cloud);
    await cloud.startup();
    return controller;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _repository?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DormController>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.hasData) return DormApp(controller: snapshot.data!);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: dormName,
        theme: dormTheme(Brightness.light),
        darkTheme: dormTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: snapshot.connectionState != ConnectionState.done
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.storage_outlined, size: 40),
                        const SizedBox(height: 16),
                        Text(
                          errorText(
                            snapshot.error!,
                            fallback: '无法打开本地数据库，请检查存储空间和目录权限。',
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () =>
                              setState(() => _initialization = _open()),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      );
    },
  );
}
