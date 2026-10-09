import 'package:flutter/foundation.dart';

import '../settings/user_settings.dart';
import 'acp/acp_agent.dart';

/// Persistent ACP agent configurations stored in settings.json.
class AcpAgents extends ChangeNotifier {
  AcpAgents(this._settings) {
    _settings.addListener(_changed);
  }

  static const settingKey = 'agents.acp';
  final UserSettings _settings;
  List<AcpAgentConfig>? _cache;

  List<AcpAgentConfig> get agents => _cache ??= [
    for (final value in switch (_settings[settingKey]) {
      final List list => list,
      _ => const [],
    })
      if (value is Map) _fromJson(value),
  ];

  void _changed() {
    _cache = null;
    notifyListeners();
  }

  Future<void> save(List<AcpAgentConfig> agents) async {
    await _settings.update(settingKey, [
      for (final agent in agents) _toJson(agent),
    ]);
  }

  Future<void> add(AcpAgentConfig agent) => save([...agents, agent]);

  Future<void> remove(String id) => save([
    for (final agent in agents)
      if (agent.id != id) agent,
  ]);

  String newId(String label) {
    final base = label.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '-',
    );
    var id = base.isEmpty ? 'acp-agent' : base;
    var number = 2;
    while (agents.any((agent) => agent.id == id)) {
      id = '${base.isEmpty ? 'acp-agent' : base}-$number';
      number++;
    }
    return id;
  }

  static AcpAgentConfig _fromJson(Map value) => AcpAgentConfig(
    id: value['id'] is String ? value['id'] as String : 'acp-agent',
    label: value['label'] is String ? value['label'] as String : 'ACP Agent',
    command: value['command'] is String ? value['command'] as String : '',
    arguments: [
      for (final argument
          in value['arguments'] is List ? value['arguments'] as List : const [])
        if (argument is String) argument,
    ],
    environment: {
      for (final entry
          in value['environment'] is Map
              ? (value['environment'] as Map).entries
              : const <MapEntry<Object?, Object?>>[])
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    },
    description: value['description'] is String
        ? value['description'] as String
        : 'Agent Client Protocol agent',
  );

  static Map<String, Object?> _toJson(AcpAgentConfig agent) => {
    'id': agent.id,
    'label': agent.label,
    'command': agent.command,
    if (agent.arguments.isNotEmpty) 'arguments': agent.arguments,
    if (agent.environment.isNotEmpty) 'environment': agent.environment,
    if (agent.description.isNotEmpty) 'description': agent.description,
  };

  @override
  void dispose() {
    _settings.removeListener(_changed);
    super.dispose();
  }
}
