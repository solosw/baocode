import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';

void main() {
  KernelDescriptor descriptor() => KernelDescriptor(
    id: 'mock-acp',
    label: 'Mock ACP',
    icon: Icons.hub,
    description: 'Test ACP agent',
    create: (_) => throw UnimplementedError(),
  );

  test('ACP initializes a session and streams an assistant message', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(kernel.commands.map((command) => command.name), ['splash']);
    expect(kernel.mode.options.map((option) => option.id), ['plan', 'bypass']);
    expect(kernel.mode.selected, 'plan');

    kernel.send(const KernelTurn(id: 'turn-1', text: 'hello'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(kernel.sessionId, 'acp_mock_session');
    expect(kernel.commands.single.name, 'splash');
    expect(kernel.mode.options.map((option) => option.id), ['plan', 'bypass']);
    kernel.mode.select('bypass');
    expect(
      transport.written.any(
        (message) => message['method'] == 'session/set_mode',
      ),
      isTrue,
    );
    expect(
      transport.written.map((message) => message['method']),
      containsAll(<Object?>['initialize', 'session/new', 'session/prompt']),
    );
    expect(events.whereType<TurnStarted>().single.turnId, 'turn-1');
    expect(events.whereType<TextDelta>().single.text, 'Echo: hello');
    expect(events.whereType<UsageReported>().single.usage.used, 4200);
    expect(events.whereType<UsageReported>().single.usage.window, 200000);
    expect(kernel.contextWindow, 200000);
    expect(events.whereType<TurnEnded>().single.turnId, 'turn-1');

    await subscription.cancel();
    kernel.dispose();
  });

  test('ACP permission shows agent option names and keeps JSON-RPC id', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.send(const KernelTurn(id: 'turn-perm', text: 'need-permission'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final requested = events.whereType<InteractionRequested>().single;
    expect(requested.request, isA<QuestionRequest>());
    final question = requested.request as QuestionRequest;
    expect(question.title, 'Run ls');
    expect(question.questions.single.options.map((o) => o.label), [
      'Allow once',
      'Allow always',
      'Reject',
    ]);

    kernel.answer(
      question.id,
      const QuestionAnswer([
        ['Allow once'],
      ]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final reply = transport.written.lastWhere(
      (message) => message.containsKey('result') && message['id'] == 42,
    );
    expect(reply['id'], 42);
    expect(reply['result'], {
      'outcome': {'outcome': 'selected', 'optionId': 'opt_allow'},
    });
    expect(events.whereType<InteractionResolved>().single.requestId, question.id);

    await subscription.cancel();
    kernel.dispose();
  });

  test('ACP skip maps to reject_once option instead of cancelled', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.send(const KernelTurn(id: 'turn-deny', text: 'need-permission'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final question =
        events.whereType<InteractionRequested>().single.request as QuestionRequest;

    kernel.answer(question.id, const QuestionAnswer([], skipped: true));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final reply = transport.written.lastWhere(
      (message) => message.containsKey('result') && message['id'] == 42,
    );
    expect(reply['result'], {
      'outcome': {'outcome': 'selected', 'optionId': 'opt_reject'},
    });

    await subscription.cancel();
    kernel.dispose();
  });
}
