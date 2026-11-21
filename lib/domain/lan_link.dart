import 'dart:io';

import 'ledger.dart';

Uri readLanQrLink(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri != null &&
      uri.scheme == 'http' &&
      uri.hasAuthority &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.port >= 1 &&
      uri.port <= 65535) {
    final host = InternetAddress.tryParse(uri.host);
    if (host != null &&
        host.type == InternetAddressType.IPv4 &&
        !host.isLoopback &&
        !host.isMulticast &&
        host.address != '0.0.0.0' &&
        host.address != '255.255.255.255') {
      return Uri(scheme: 'http', host: host.address, port: uri.port);
    }
  }
  throw const InputException('请扫描 Dorm 局域网访问地址的二维码');
}
