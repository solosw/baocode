import 'dart:async';

import 'acp_transport.dart';

class MockAcpTransport implements AcpTransport {
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast(sync: true);
  final List<Map<String, Object?>> written = [];
  final Map<String, Object?> _sessions = {'sessionId': 'acp_mock_session'};

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    final id = message['id'];
    switch (method) {
      case 'initialize':
        _respond(id, {
          'protocolVersion': 1,
          'agentInfo': {'name': 'mock-acp'},
          'capabilities': {
            'modes': [
              {'id': 'plan', 'name': 'Plan'},
              {'id': 'bypass', 'name': 'Bypass'},
            ],
            'commands': [
              {'name': 'splash', 'description': 'Show splash'},
            ],
          },
        });
      case 'session/new':
        // As real agents do: advertise modes and slash commands as a
        // notification before the session/new result is delivered.
        _out.add({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': _sessions['sessionId'],
            'update': {
              'sessionUpdate': 'available_commands_update',
              'availableCommands': [
                {'name': 'splash', 'description': 'Show splash'},
              ],
            },
          },
        });
        _out.add({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': _sessions['sessionId'],
            'update': {
              'sessionUpdate': 'current_mode_update',
              'currentModeId': 'plan',
              'availableModes': [
                {'id': 'plan', 'name': 'Plan'},
                {'id': 'bypass', 'name': 'Bypass'},
              ],
            },
          },
        });
        _respond(id, {..._sessions});
      case 'session/prompt':
        _respond(id, {
          'sessionId': _sessions['sessionId'],
          'stopReason': 'end_turn',
        });
        final params = (message['params'] as Map).cast<String, Object?>();
        final prompt =
            ((params['prompt'] as List).first as Map)['text'] as String;
        _out.add({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': _sessions['sessionId'],
            'update': {
              'sessionUpdate': 'usage_update',
              'used': 4200,
              'size': 200000,
            },
          },
        });
        if (prompt == 'need-permission') {
          _out.add({
            'jsonrpc': '2.0',
            'id': 42,
            'method': 'session/request_permission',
            'params': {
              'sessionId': _sessions['sessionId'],
              'toolCall': {
                'toolCallId': 'call_1',
                'title': 'Run ls',
                'kind': 'execute',
                'rawInput': {'command': 'ls'},
              },
              'options': [
                {
                  'optionId': 'opt_allow',
                  'name': 'Allow once',
                  'kind': 'allow_once',
                },
                {
                  'optionId': 'opt_always',
                  'name': 'Allow always',
                  'kind': 'allow_always',
                },
                {
                  'optionId': 'opt_reject',
                  'name': 'Reject',
                  'kind': 'reject_once',
                },
              ],
            },
          });
          return;
        }
        _out.add({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': _sessions['sessionId'],
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'messageId': 'item_1',
              'content': {'type': 'text', 'text': 'Echo: $prompt'},
            },
          },
        });
      case 'session/cancel':
        _respond(id, {});
      case 'session/set_mode':
        _respond(id, {});
    }
  }

  void emitUsage({required int used, required int size}) {
    _out.add({
      'jsonrpc': '2.0',
      'method': 'session/update',
      'params': {
        'sessionId': _sessions['sessionId'],
        'update': {
          'sessionUpdate': 'usage_update',
          'used': used,
          'size': size,
        },
      },
    });
  }

  void _respond(Object? id, Map<String, Object?> result) {
    _out.add({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  @override
  void close() {
    if (!_out.isClosed) _out.close();
  }
}
