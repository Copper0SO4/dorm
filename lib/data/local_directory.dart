import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

Future<Directory> dormDataDirectory() async {
  final separator = Platform.pathSeparator;
  if (Platform.isWindows) {
    final isolated = Platform.environment['DORM_DATA_DIR'];
    if (isolated != null && isolated.trim().isNotEmpty) {
      return Directory(isolated);
    }
    // The old Windows VERSIONINFO selected this directory. Keep it independent
    // of the display name so future branding changes also preserve local data.
    final roaming = await _windowsRoamingAppData();
    if (roaming == null) {
      throw const FileSystemException(
        'Windows roaming app data is unavailable',
      );
    }
    return Directory(
      [roaming, 'org.dormos', 'dormos', 'dormos'].join(separator),
    );
  }
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${separator}dormos');
}

Future<String?> _windowsRoamingAppData() =>
    PathProviderWindows().getPath('{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}');
