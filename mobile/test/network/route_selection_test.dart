import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sp_smart/core/config/app_config.dart';
import 'package:sp_smart/core/network/signaling_service.dart';

void main() {
  test('hostname DNS usa WSS', () {
    const domain = ServerEndpoint(host: 'node.example.com', signalingPort: 443);

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
        host: 'localhost',
        signalingPort: unavailablePort,
        isPrimary: true,
      ),
      ServerEndpoint(
        host: 'localhost',
        signalingPort: reachable.port,
      ),
    ]);

    expect(selected.endpoint.signalingPort, reachable.port);
    expect(selected.rtt, isNot(Duration.zero));
  });
}
