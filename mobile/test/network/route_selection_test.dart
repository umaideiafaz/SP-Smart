import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sp_smart/core/config/app_config.dart';
import 'package:sp_smart/core/network/signaling_service.dart';

void main() {
  test('IP literal usa ws e dominio usa wss', () {
    const ip = ServerEndpoint(host: '192.168.1.10', signalingPort: 3000);
    const domain = ServerEndpoint(host: 'node.example.com', signalingPort: 443);

    expect(ip.wsUri.toString(), 'ws://192.168.1.10:3000/ws');
    expect(domain.wsUri.toString(), 'wss://node.example.com:443/ws');
  });

  test('corrida TCP elege o endpoint que responde', () async {
    final reachable = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unavailable =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unavailablePort = unavailable.port;
    await unavailable.close();

    final service = SignalingService();
    addTearDown(service.dispose);
    addTearDown(reachable.close);

    final selected = await service.selectFastestEndpoint([
      ServerEndpoint(
        host: InternetAddress.loopbackIPv4.address,
        signalingPort: unavailablePort,
        isPrimary: true,
      ),
      ServerEndpoint(
        host: InternetAddress.loopbackIPv4.address,
        signalingPort: reachable.port,
      ),
    ]);

    expect(selected.endpoint.signalingPort, reachable.port);
    expect(selected.rtt, isNot(Duration.zero));
  });
}
