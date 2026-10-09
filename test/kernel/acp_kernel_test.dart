import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
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
    final user = events.whereType<ItemUpserted>().singleWhere(
      (event) => event.id == 'turn-1',
    );
    expect(user.item, isA<UserMessageItem>());
    expect((user.item as UserMessageItem).text, 'hello');
    expect(events.whereType<TextDelta>().single.text, 'Echo: hello');
    expect(
      events
          .whereType<ItemUpserted>()
          .where((event) {
            return event.item is AssistantTextItem;
          })
          .single
          .id,
      'acp_message_1_1',
    );

    kernel.send(const KernelTurn(id: 'turn-2', text: 'again'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      events
          .whereType<ItemUpserted>()
          .where((event) {
            return event.item is AssistantTextItem &&
                event.id.startsWith('acp_message_2_');
          })
          .single
          .id,
      'acp_message_2_2',
    );
    expect(
      events
          .whereType<ItemUpserted>()
          .where((event) => event.id == 'turn-2')
          .single
          .item,
      isA<UserMessageItem>(),
    );
    expect(events.whereType<UsageReported>().first.usage.used, 4200);
    expect(events.whereType<UsageReported>().first.usage.window, 200000);
    expect(kernel.contextWindow, 200000);
    expect(events.whereType<TurnEnded>().map((event) => event.turnId), [
      'turn-1',
      'turn-2',
    ]);

    await subscription.cancel();
    kernel.dispose();
  });

  test('ACP session/load replays history as separate turns', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      KernelContext(
        cwd: '/tmp/project',
        resume: SessionRecord(
          id: 'sess_history',
          title: 'Earlier',
          updatedAt: DateTime.utc(2026, 10, 9),
          cwd: '/tmp/project',
        ),
      ),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      transport.written.any((message) => message['method'] == 'session/load'),
      isTrue,
    );
    expect(
      transport.written.any((message) => message['method'] == 'session/new'),
      isFalse,
    );
    final users = events
        .whereType<ItemUpserted>()
        .where((event) => event.item is UserMessageItem)
        .map((event) => (event.item as UserMessageItem).text)
        .toList();
    final answers = events
        .whereType<ItemUpserted>()
        .where((event) => event.item is AssistantTextItem)
        .map((event) => event.id)
        .toList();
    expect(users, ['first question', 'second question']);
    expect(answers, hasLength(2));
    expect(answers.first, isNot(answers.last));
    expect(events.whereType<TurnStarted>().length, 2);

    await subscription.cancel();
    kernel.dispose();
  });

  test(
    'ACP permission shows agent option names and keeps JSON-RPC id',
    () async {
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
      expect(
        events.whereType<InteractionResolved>().single.requestId,
        question.id,
      );

      await subscription.cancel();
      kernel.dispose();
    },
  );

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
        events.whereType<InteractionRequested>().single.request
            as QuestionRequest;

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

  test('ACP plan session updates replace the todo list', () async {
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

    // ACP v1: sessionUpdate "plan", entries at the top level.
    transport.notify({
      'sessionUpdate': 'plan',
      'entries': [
        {
          'content': 'Analyze the existing codebase structure',
          'priority': 'high',
          'status': 'pending',
        },
        {
          'content': 'Create unit tests',
          'priority': 'medium',
          'status': 'in_progress',
        },
      ],
    });
    // ACP v2 draft: sessionUpdate "plan_update", entries under plan.
    // A later update replaces the whole list, including cancelled.
    transport.notify({
      'sessionUpdate': 'plan_update',
      'plan': {
        'type': 'items',
        'planId': 'plan-1',
        'entries': [
          {
            'content': 'Analyze the existing codebase structure',
            'priority': 'high',
            'status': 'completed',
          },
          {
            'content': 'Create unit tests',
            'priority': 'medium',
            'status': 'cancelled',
          },
        ],
      },
    });

    // Papercode sends sessionUpdate "todo_update" with id'd todos, not plan.
    transport.notify({
      'sessionUpdate': 'todo_update',
      'todos': [
        {
          'id': '1',
          'content': 'Analyze the existing codebase structure',
          'status': 'pending',
          'priority': 'high',
        },
        {
          'id': '2',
          'content': 'Create unit tests',
          'status': 'in_progress',
          'activeForm': 'Writing tests',
        },
      ],
    });

    final reports = events.whereType<TodosReported>().toList();
    expect(reports, hasLength(3));
    expect(reports.first.todos.map((todo) => todo.status), [
      TodoStatus.pending,
      TodoStatus.inProgress,
    ]);
    expect(reports[1].todos.map((todo) => (todo.content, todo.status)), [
      ('Analyze the existing codebase structure', TodoStatus.completed),
      ('Create unit tests', TodoStatus.pending),
    ]);
    expect(reports.last.todos.map((todo) => (todo.content, todo.status)), [
      ('Analyze the existing codebase structure', TodoStatus.pending),
      ('Create unit tests', TodoStatus.inProgress),
    ]);
    expect(reports.last.todos.last.activeForm, 'Writing tests');

    // Papercode wraps the todo_write result as nested ACP content. The text
    // is JSON `{ok, todos}` and history replay may not send todo_update.
    transport.notify({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'todo_write',
      'kind': 'other',
      'title': '更新待办',
      'status': 'completed',
      'content': [
        {
          'type': 'content',
          'content': {
            'type': 'text',
            'text': '{"ok":true,"todos":[{"id":"1","content":"Wire ACP","status":"in_progress","activeForm":"Wiring ACP"}],"message":"todos updated: 1 total"}',
          },
        },
      ],
    });
    expect(
      events.whereType<TodosReported>().last.todos.single.content,
      'Wire ACP',
    );
    expect(
      events.whereType<TodosReported>().last.todos.single.status,
      TodoStatus.inProgress,
    );
    expect(
      events.whereType<TodosReported>().last.todos.single.activeForm,
      'Wiring ACP',
    );

    await subscription.cancel();
    kernel.dispose();
  });

  test('ACP plan variants with items/description still become todos', () async {
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

    // Some agents nest under plan.items and use description / TitleCase status.
    transport.notify({
      'sessionUpdate': 'plan',
      'plan': {
        'items': [
          {
            'description': 'Inspect ACP plan updates',
            'priority': 'high',
            'status': 'InProgress',
          },
          {
            'title': 'Show TodoPanel above composer',
            'status': 'PENDING',
          },
        ],
      },
    });
    // plan as a bare list of strings.
    transport.notify({
      'sessionUpdate': 'plan',
      'plan': ['First step', 'Second step'],
    });

    final reports = events.whereType<TodosReported>().toList();
    expect(reports, hasLength(2));
    expect(reports.first.todos.map((todo) => (todo.content, todo.status)), [
      ('Inspect ACP plan updates', TodoStatus.inProgress),
      ('Show TodoPanel above composer', TodoStatus.pending),
    ]);
    expect(reports.last.todos.map((todo) => todo.content), [
      'First step',
      'Second step',
    ]);

    await subscription.cancel();
    kernel.dispose();
  });
}
