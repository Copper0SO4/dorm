import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

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

class _DormBootstrapState extends State<DormBootstrap> {
  SqliteDormRepository? _repository;
  late Future<DormController> _initialization = _open();

  Future<DormController> _open() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}${Platform.pathSeparator}dormos');
    await directory.create(recursive: true);
    if (!mounted) throw StateError('Startup was interrupted');
    final repository = SqliteDormRepository.open(
      '${directory.path}${Platform.pathSeparator}dormos.sqlite3',
    );
    _repository = repository;
    return DormController(repository);
  }

  @override
  void dispose() {
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
