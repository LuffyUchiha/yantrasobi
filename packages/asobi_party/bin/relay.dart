import 'dart:io';

import 'package:asobi_party/io.dart';

/// Runs the party relay: `dart run asobi_party:relay` (PORT env, default 8787).
Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final server = await RelayServer.start(port: port);
  stdout.writeln('Yantrasobi party relay on :${server.port} (ws path /v1/party, health /healthz)');
  ProcessSignal.sigint.watch().first.then((_) async {
    await server.close();
    exit(0);
  });
}
