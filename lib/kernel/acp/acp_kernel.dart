import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'acp_transport.dart';

/// Adapts an ACP JSON-RPC agent over a message transport to [AgentKernel].
class AcpKernel
    with KernelEventSource
    implements AgentKernel, SelectsMode, ProvidesCommands, ReportsContext {
  AcpKernel(this.descriptor, this._context, this._transportFactory);

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final AcpTransportFactory _transportFactory;
  AcpTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;

  KernelHealth _health = KernelHealth.idle;
  String? _sessionId;
  String? _turnId;
  DateTime? _turnStarted;
  int _nextId = 0;
  bool _initialized = false;
  bool _starting = false;
  bool _disposed = false;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Map<String, String> _messages = {};
  final List<KernelOption> _modeOptions = [];
  List<KernelCommand> _commands = const [];

  @override
  late final KernelChoiceSource mode = LocalChoice([], onChanged: _selectMode);

  @override
  List<KernelCommand> get commands => _commands;

  int _contextWindow = 200000;

  @override
  int get contextWindow => _contextWindow;

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _sessionId;

  @override
  Future<void> get stopped async {
    final subscription = _subscription;
    if (subscription != null && !_disposed) await subscription.asFuture<void>();
  }

  @override
  void prepare() {
    if (_disposed || _initialized || _starting) return;
    _starting = true;
    _health = const KernelHealth(KernelHealthStatus.starting);
    emitInfoChanged();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _transport = QueuedAcpTransport(await _transportFactory(_context));
      _subscription = _transport!.messages.listen(
        _receive,
        onError: (Object error, StackTrace _) => _fail(error),
        onDone: () {
          if (!_disposed) _fail(StateError('ACP agent process exited'));
        },
      );
      await _request('initialize', {
        'protocolVersion': 1,
        'clientInfo': {'name': 'BaoCode', 'version': '1.0.0'},
        'clientCapabilities': <String, Object?>{},
      });
      if (_disposed) return;
      _initialized = true;
      await _ensureSession();
      if (_disposed) return;
      _starting = false;
      _health = KernelHealth.ready;
      emitInfoChanged();
    } on Object catch (error) {
      _starting = false;
      _fail(error);
    }
  }

  Future<void> _ensureSession() async {
    if (_sessionId != null) return;
    final session = await _request('session/new', {
      'cwd': _context.cwd ?? '',
      'mcpServers': const <Object?>[],
    });
    _sessionId = session['sessionId'] as String?;
    _applyModes(session['modes']);
    _setCommands(
      session['availableCommands'] ??
          session['available_commands'] ??
          session['commands'] ??
          session['slashCommands'],
    );
    // Notifications that arrived during session/new were queued until the
    // listener resumed. Apply them now so modes and slash commands replace
    // the previous agent's.
    _flushQueued();
    if (_sessionId == null) {
      throw StateError('ACP session/new returned no sessionId');
    }
  }

  @override
  void send(KernelTurn turn) {
    if (_disposed || turn.id == _turnId) return;
    prepare();
    unawaited(_sendWhenReady(turn));
  }

  Future<void> _sendWhenReady(KernelTurn turn) async {
    try {
      while (!_initialized &&
          !_disposed &&
          _health.status != KernelHealthStatus.failed) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!_initialized || _disposed) return;
      await _ensureSession();
      final sessionId = _sessionId!;
      _turnId = turn.id;
      _turnStarted = DateTime.now();
      emit(TurnStarted(nextSeq, turn.id));
      final result = await _request('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': turn.text},
        ],
      });
      if (_turnId == turn.id) {
        _endTurn(result['stopReason'] == 'cancelled');
      }
    } on Object catch (error) {
      _fail(error);
      if (_turnId == turn.id) _endTurn(false);
    }
  }

  void runCommand(String name, [String argument = '']) {
    final command = name.startsWith('/') ? name : '/$name';
    final text = argument.trim().isEmpty
        ? command
        : '$command ${argument.trim()}';
    send(KernelTurn(id: 'command_${++_nextId}', text: text));
  }

  void _applyModes(Object? raw) {
    final Map<String, Object?> state;
    if (raw is List) {
      state = {'availableModes': raw};
    } else if (raw is Map) {
      state = raw.cast<String, Object?>();
    } else {
      return;
    }
    final modes = state['availableModes'];
    if (modes is List) {
      _modeOptions
        ..clear()
        ..addAll([
          for (final item in modes)
            if (item is Map && item['id'] is String)
              KernelOption(
                item['id'] as String,
                item['name'] as String? ?? item['id'] as String,
                Icons.tune_rounded,
                item['description'] as String? ?? 'ACP mode',
              ),
        ]);
      if (_modeOptions.isNotEmpty) (mode as LocalChoice).options = _modeOptions;
    }
    final current = state['currentModeId'];
    if (current is String && current.isNotEmpty) {
      (mode as LocalChoice).reported = current;
    }
    emitInfoChanged();
  }

  void _selectMode(String modeId) {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    unawaited(
      _request('session/set_mode', {
        'sessionId': sessionId,
        'modeId': modeId,
      }).then((_) {}, onError: (Object error) => _fail(error)),
    );
  }

  void _setCommands(Object? raw) {
    if (raw is! List) return;
    _commands = [
      for (final item in raw)
        if (item is Map && item['name'] is String)
          KernelCommand(
            (item['name'] as String).replaceFirst(RegExp(r'^/'), ''),
            item['description'] as String? ?? 'ACP command',
            Icons.code_rounded,
            argumentHint: (item['input'] as Map?)?['hint'] as String? ?? '',
          ),
    ];
    emitInfoChanged();
  }

  @override
  void cancel() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    unawaited(
      _request('session/cancel', {'sessionId': sessionId}).then((_) {}),
    );
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    final rpcId = _permissionRpcIds.remove(requestId) ?? requestId;
    final optionId = _permissionOptionId(requestId, answer);
    _permissionOptions.remove(requestId);
    _permissionKinds.remove(requestId);
    // `cancelled` is only for session/cancel while a permission is pending.
    // A deny must select a reject_* optionId from the agent's list.
    _transport?.write({
      'jsonrpc': '2.0',
      'id': rpcId,
      'result': {
        'outcome': optionId == null
            ? {'outcome': 'cancelled'}
            : {'outcome': 'selected', 'optionId': optionId},
      },
    });
    if (_commandInteractionIds.remove(requestId) && _turnId != null) {
      _endTurn(false);
    }
    emit(InteractionResolved(nextSeq, requestId));
  }

  /// Maps the panel's choice back to the option the agent advertised.
  String? _permissionOptionId(String requestId, InteractionAnswer answer) {
    final byLabel = _permissionOptions[requestId] ?? const {};
    final byKind = _permissionKinds[requestId] ?? const {};
    switch (answer) {
      case QuestionAnswer(:final picks, :final skipped):
        if (skipped || picks.isEmpty || picks.first.isEmpty) {
          return byKind['reject_once'] ?? byKind['reject-once'];
        }
        final label = picks.first.first;
        return byLabel[label] ?? label;
      case ApprovalAnswer(:final decision):
        return switch (decision) {
          ApprovalDecision.allowOnce =>
            byKind['allow_once'] ??
                byKind['allow-once'] ??
                byLabel['Allow once'] ??
                'allow_once',
          ApprovalDecision.allowAlways =>
            byKind['allow_always'] ??
                byKind['allow-always'] ??
                byLabel.values.firstWhere(
                  (id) => id.contains('always') && id.contains('allow'),
                  orElse: () => 'allow_always',
                ),
          ApprovalDecision.deny =>
            byKind['reject_once'] ??
                byKind['reject-once'] ??
                byKind['reject_always'] ??
                byKind['reject-always'] ??
                'reject_once',
        };
      case _:
        return byKind['reject_once'] ?? byKind['reject-once'];
    }
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = '${++_nextId}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _transport?.write({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw TimeoutException('ACP request timed out: $method'),
    );
  }

  void _flushQueued() {
    final transport = _transport;
    if (transport is! QueuedAcpTransport) return;
    final pending = transport.takeQueued();
    if (pending.isEmpty) return;
    // Apply after session/new's future resumes, so a mode/command update
    // that arrived before the result is not dropped on the paused listener.
    scheduleMicrotask(() {
      if (_disposed) return;
      for (final message in pending) {
        _receive(message);
      }
    });
  }

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final rawId = message['id'];
    final id = rawId?.toString();
    if (method == null && id != null) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      if (message['error'] case final Map error) {
        pending.completeError(StateError('${error['message'] ?? error}'));
      } else {
        pending.complete(
          (message['result'] as Map?)?.cast<String, Object?>() ?? const {},
        );
      }
      return;
    }
    if (method == null) return;
    final params =
        (message['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (rawId != null && id != null) {
      // Keep the agent's JSON-RPC id type (int or string) for the reply.
      _handleServerRequest(rawId, id, method, params);
    } else if (method == 'session/update') {
      _handleUpdate(params);
    }
  }

  void _handleServerRequest(
    Object rpcId,
    String requestId,
    String method,
    Map<String, Object?> params,
  ) {
    if (method != 'session/request_permission') {
      _transport?.write({
        'jsonrpc': '2.0',
        'id': rpcId,
        'error': {'code': -32601, 'message': 'method not found: $method'},
      });
      return;
    }
    final toolCall =
        (params['toolCall'] as Map?)?.cast<String, Object?>() ?? const {};
    final title = toolCall['title'] as String? ?? 'Permission required';
    final toolKind = toolCall['kind'] as String?;
    final isCommandChoice =
        toolKind == 'command' ||
        toolKind == 'slash_command' ||
        title.startsWith('/');
    if (isCommandChoice) _commandInteractionIds.add(requestId);
    final options = [
      for (final raw in params['options'] as List? ?? const [])
        if (raw is Map && raw['optionId'] is String)
          (
            id: raw['optionId'] as String,
            name: raw['name'] as String? ?? raw['optionId'] as String,
            kind: raw['kind'] as String?,
          ),
    ];
    _permissionRpcIds[requestId] = rpcId;
    _permissionOptions[requestId] = {
      for (final option in options) option.name: option.id,
      for (final option in options) option.id: option.id,
    };
    _permissionKinds[requestId] = {
      for (final option in options)
        if (option.kind != null) option.kind!: option.id,
    };
    // Always show the agent's own option names. ApprovalRequest would replace
    // them with localized Accept/Deny labels.
    emit(
      InteractionRequested(
        nextSeq,
        QuestionRequest(
          id: requestId,
          title: isCommandChoice ? 'Choose a command' : title,
          questions: [
            Question(
              prompt: title,
              header: isCommandChoice ? 'Command' : (toolKind ?? 'Permission'),
              options: [
                for (final option in options)
                  QuestionOption(
                    option.name,
                    description:
                        option.kind == null || option.kind == option.name
                        ? ''
                        : option.kind!,
                  ),
              ],
              allowOther: false,
            ),
          ],
        ),
      ),
    );
  }

  final Map<String, Object> _permissionRpcIds = {};
  final Map<String, Map<String, String>> _permissionOptions = {};
  final Map<String, Map<String, String>> _permissionKinds = {};
  final Set<String> _commandInteractionIds = {};

  void _handleUpdate(Map<String, Object?> params) {
    final session = params['sessionId'];
    if (_sessionId != null && session is String && session != _sessionId) {
      return;
    }
    final update =
        (params['update'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
      case 'agent_thought_chunk':
        final content =
            (update['content'] as Map?)?.cast<String, Object?>() ?? const {};
        final text = content['text'];
        if (text is! String || text.isEmpty) return;
        final itemId =
            update['messageId'] as String? ??
            update['thoughtId'] as String? ??
            (update['sessionUpdate'] == 'agent_thought_chunk'
                ? 'acp_agent_thought'
                : 'acp_agent_message');
        final oldText = _messages[itemId] ?? '';
        _messages[itemId] = '$oldText$text';
        if (oldText.isEmpty) {
          emit(
            ItemUpserted(
              nextSeq,
              itemId,
              update['sessionUpdate'] == 'agent_thought_chunk'
                  ? ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now())
                  : const AssistantTextItem(''),
              streaming: true,
            ),
          );
        }
        emit(TextDelta(nextSeq, itemId, oldText.length, text));
      case 'available_commands_update':
        _setCommands(
          update['availableCommands'] ??
              update['available_commands'] ??
              update['commands'],
        );
      case 'current_mode_update':
        _applyModes({
          'currentModeId': update['currentModeId'],
          'availableModes': update['availableModes'],
        });
      case 'usage_update':
        final usage = _contextUsage(update);
        if (usage != null) emit(UsageReported(nextSeq, usage));
      case 'tool_call':
      case 'tool_call_update':
        _toolUpdate(update);
      case 'todo_update':
        _todosUpdate(update['todos'] ?? update['items'] ?? update['todoItems']);
      case 'user_message_chunk':
        break;
      case 'session_end':
      case 'prompt_complete':
      case 'turn_complete':
        if (_turnId != null) _endTurn(false);
        break;
    }
  }

  void _toolUpdate(Map<String, Object?> update) {
    final id =
        update['toolCallId'] as String? ??
        update['id'] as String? ??
        'acp_tool';
    final title = update['title'] as String? ?? 'Tool call';
    final rawStatus = update['status'] as String? ?? 'running';
    final status = switch (rawStatus) {
      'completed' || 'succeeded' || 'success' => CommandStatus.succeeded,
      'failed' || 'error' => CommandStatus.failed,
      _ => CommandStatus.running,
    };
    final kind = _toolKind(
      update['kind'] as String? ?? update['toolName'] as String?,
    );
    final toolStatus = switch (status) {
      CommandStatus.succeeded => ToolStatus.succeeded,
      CommandStatus.failed => ToolStatus.failed,
      CommandStatus.running => ToolStatus.running,
    };
    emit(
      ItemUpserted(
        nextSeq,
        id,
        ToolCallItem(
          kind: kind,
          target: title,
          label: update['title'] as String?,
          status: toolStatus,
          detail: _toolDetail(update),
        ),
      ),
    );
    emit(
      TasksReported(nextSeq, [
        KernelTask(
          id: id,
          description: title,
          kind: KernelTaskKind.other,
          status: status,
          startedAt: DateTime.now(),
          summary: title,
        ),
      ]),
    );
  }

  ToolKind _toolKind(String? raw) {
    final value = (raw ?? '').toLowerCase();
    if (value.contains('read')) return ToolKind.read;
    if (value.contains('grep') || value.contains('search')) {
      return ToolKind.search;
    }
    if (value.contains('edit') || value.contains('write')) return ToolKind.edit;
    if (value.contains('command') || value.contains('shell')) {
      return ToolKind.command;
    }
    if (value.contains('todo')) return ToolKind.todo;
    if (value.contains('agent')) return ToolKind.agent;
    return ToolKind.other;
  }

  String? _toolDetail(Map<String, Object?> update) {
    final content = update['content'];
    if (content is List) {
      return content
          .whereType<Map>()
          .map((item) => item['text'] ?? item['content'])
          .whereType<String>()
          .join();
    }
    final raw = update['rawInput'] ?? update['raw_input'] ?? update['input'];
    return raw is String
        ? raw
        : raw == null
        ? null
        : '$raw';
  }

  ContextUsage? _contextUsage(Map<String, Object?> update) {
    int? asInt(Object? value) => switch (value) {
      final int n => n,
      final num n => n.round(),
      final String s => int.tryParse(s),
      _ => null,
    };
    final used =
        asInt(update['used']) ??
        asInt(update['inputTokens']) ??
        asInt(update['input_tokens']) ??
        asInt((update['usage'] as Map?)?['used']) ??
        asInt((update['usage'] as Map?)?['inputTokens']) ??
        asInt((update['usage'] as Map?)?['input_tokens']);
    final window =
        asInt(update['size']) ??
        asInt(update['contextWindow']) ??
        asInt(update['context_window']) ??
        asInt(update['window']) ??
        asInt((update['usage'] as Map?)?['size']) ??
        asInt((update['usage'] as Map?)?['contextWindow']) ??
        asInt((update['usage'] as Map?)?['context_window']) ??
        asInt((update['usage'] as Map?)?['window']);
    if (used == null || window == null || window <= 0) return null;
    _contextWindow = window;
    return ContextUsage(window: window, used: used);
  }

  void _todosUpdate(Object? raw) {
    if (raw is! List) return;
    final todos = <TodoEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final content = item['content'] ?? item['title'] ?? item['text'];
      if (content is! String || content.trim().isEmpty) continue;
      final status = switch (item['status']?.toString()) {
        'completed' || 'done' => TodoStatus.completed,
        'in_progress' || 'in-progress' || 'active' => TodoStatus.inProgress,
        _ => TodoStatus.pending,
      };
      todos.add(
        TodoEntry(
          content.trim(),
          status,
          activeForm:
              item['activeForm'] as String? ?? item['active_form'] as String?,
        ),
      );
    }
    emit(TodosReported(nextSeq, todos));
  }

  void _endTurn(bool interrupted) {
    final turn = _turnId;
    if (turn == null) return;
    final worked = _turnStarted == null
        ? null
        : DateTime.now().difference(_turnStarted!);
    emit(TurnEnded(nextSeq, turn, interrupted: interrupted, worked: worked));
    _turnId = null;
    _turnStarted = null;
  }

  void _fail(Object error) {
    if (_disposed || _health.status == KernelHealthStatus.failed) return;
    _health = KernelHealth(KernelHealthStatus.failed, message: '$error');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    emitInfoChanged();
  }

  @override
  void restart() {
    if (_disposed) return;
    _transport?.close();
    _transport = null;
    _subscription?.cancel();
    _subscription = null;
    _sessionId = null;
    _initialized = false;
    _starting = false;
    _health = KernelHealth.idle;
    prepare();
  }

  @override
  void release() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _transport?.close();
    _subscription?.cancel();
    closeEvents();
  }
}
