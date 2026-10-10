import 'dart:io';

import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/remote/remote_acp.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../fixtures/lsp/fake_lsp.dart' show dartExecutable;
import 'remote_harness.dart';

/// A one-line ACP stand-in: answers initialize and session/new with the
/// directory it was started in, so a remote launch can be told from a local
/// one.
const _agent = r'''
import 'dart:convert';
import 'dart:io';

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim().isEmpty) return;
    final message = jsonDecode(line) as Map<String, Object?>;
    final method = message['method'];
    final id = message['id'];
    if (method == 'initialize') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {'protocolVersion': 1},
      }));
    } else if (method == 'session/new') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'update': {
            'sessionUpdate': 'available_commands_update',
            'availableCommands': [
              {'name': 'remote-only', 'description': Directory.current.path},
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {'sessionId': 'remote-session'},
      }));
    }
  });
}
''';

void main() {
  test('an ssh project starts ACP on that host, not here', () async {
    final dataDir = Directory.systemTemp.createTempSync('baocode-acp-data-');
    final project = Directory.systemTemp.createTempSync('baocode-acp-project-');
    final root = project.resolveSymbolicLinksSync();
    final agent = File(p.join(dataDir.path, 'agent.dart'))
      ..writeAsStringSync(_agent);
    final connector = MemoryConnector(dataDir.path);
    final previous = SshHosts.instance;
    SshHosts.instance = SshHosts(connect: connector.call);
    final location = RemoteLocation.of('dev', root);
    AcpKernel? kernel;
    try {
      final transport = await RemoteAcpTransport.start(
        SshHosts.instance['dev'],
        dartExecutable,
        arguments: [agent.path],
        cwd: RemoteLocation.pathOf(location),
        login: false,
      );
      kernel = AcpKernel(
        KernelDescriptor(
          id: 'remote-acp',
          label: 'Remote ACP',
          icon: Icons.hub,
          description: 'test',
          create: (_) => throw UnimplementedError(),
        ),
        KernelContext(cwd: location),
        (_) async => transport,
      );
      final events = <KernelEvent>[];
      final subscription = kernel.events.listen(events.add);
      kernel.prepare();
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (kernel.commands.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        kernel.health.status,
        KernelHealthStatus.ready,
        reason: kernel.health.message,
      );
      expect(kernel.commands.single.name, 'remote-only');
      expect(kernel.commands.single.description, root);
      expect(
        events.whereType<ItemUpserted>(),
        isEmpty,
        reason: 'the remote agent has not been prompted yet',
      );
      await subscription.cancel();
    } finally {
      kernel?.dispose();
      await SshHosts.instance.closeAll();
      SshHosts.instance = previous;
      for (final dir in [dataDir, project]) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    }
  });

  test('session/new is told the path on the host, not ssh://', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      KernelDescriptor(
        id: 'mock-acp',
        label: 'Mock ACP',
        icon: Icons.hub,
        description: 'test',
        create: (_) => throw UnimplementedError(),
      ),
      const KernelContext(cwd: 'ssh://dev/home/me/app'),
      (_) async => transport,
    );
    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final created = transport.written.firstWhere(
      (message) => message['method'] == 'session/new',
    );
    expect((created['params'] as Map)['cwd'], '/home/me/app');
    kernel.dispose();
  });
}
