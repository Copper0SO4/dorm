import 'dart:async';
import 'dart:io';

import 'package:git2dart/git2dart.dart' as git;
import 'package:material_ui/material_ui.dart';

import 'app_identity.dart';
import 'data/cloud_sync.dart';
import 'data/data_location.dart';
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

Future<DormController> _openDorm() async {
  final defaultDirectory = await dormDataDirectory();
  final location = Platform.isWindows
      ? await DormDataLocation.open(defaultDirectory)
      : null;
  final directory = location?.directory ?? defaultDirectory;
  SqliteDormRepository? opened;
  try {
    await directory.create(recursive: true);
    final repository = opened = SqliteDormRepository.open(
      '${directory.path}${Platform.pathSeparator}${DormDataLocation.databaseName}',
    );
    final cloud = CloudSync(
      repository.cloud,
      SshVault(directory),
      GitHubTransport(
        Directory('${directory.path}${Platform.pathSeparator}cloud-git'),
        deviceCode: repository.deviceCode,
      ),
      initialize: git.PlatformSpecific.initialize,
    );
    return DormController(repository, cloud: cloud, dataLocation: location);
  } catch (_) {
    try {
      opened?.close();
    } finally {
      location?.close();
    }
    rethrow;
  }
}

class DormBootstrap extends StatefulWidget {
  const DormBootstrap({super.key, this.openController = _openDorm});

  final Future<DormController> Function() openController;

  @override
  State<DormBootstrap> createState() => _DormBootstrapState();
}

class _DormBootstrapState extends State<DormBootstrap>
    with WidgetsBindingObserver {
  DormController? _controller;
  bool _scheduledSync = false;
  late Future<DormController> _initialization = _open();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_scheduledSync && state == AppLifecycleState.resumed) {
      unawaited(_controller?.cloud?.sync());
    }
  }

  Future<DormController> _open() async {
    final controller = await widget.openController();
    if (!mounted) {
      _closeController(controller);
      throw StateError('Startup was interrupted');
    }
    return _controller = controller;
  }

  void _closeController(DormController controller) {
    controller.dispose();
    try {
      controller.repository.close();
    } finally {
      controller.dataLocation?.close();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_controller case final controller?) _closeController(controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DormController>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.data case final controller?) {
        if (!_scheduledSync) {
          _scheduledSync = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(controller.cloud?.startup());
          });
        }
        return DormApp(controller: controller);
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: dormFullName,
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
