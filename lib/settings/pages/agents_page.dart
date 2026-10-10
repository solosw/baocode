import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_agents.dart';
import '../../theme/codicons.dart';
import 'settings_widgets.dart';

class AgentsSettingsPage extends StatelessWidget {
  const AgentsSettingsPage({super.key, required this.agents});

  final AcpAgents agents;

  Future<void> _add(BuildContext context) async {
    final id = agents.newId('ACP Agent');
    await agents.add(
      AcpAgentConfig(id: id, label: 'ACP Agent', command: 'agent'),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: agents,
    builder: (context, _) => SettingsPage(
      title: 'Agents',
      description: 'Configure multiple Agent Client Protocol agents.',
      children: [
        SettingsGroup(
          title: 'ACP agents',
          children: [
            if (agents.agents.isEmpty)
              const SettingsRow(label: 'No ACP agents configured'),
            for (final agent in agents.agents)
              _AgentSettingsRow(
                key: ValueKey(agent.id),
                agent: agent,
                onSave: (updated) => unawaited(
                  agents.save([
                    for (final item in agents.agents)
                      item.id == agent.id ? updated : item,
                  ]),
                ),
                onDelete: () => unawaited(agents.remove(agent.id)),
              ),
            SettingsRow(
              label: 'Add ACP agent',
              trailing: IdeButton(
                label: 'Add ACP agent',
                icon: Codicons.add,
                onPressed: () => unawaited(_add(context)),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _AgentSettingsRow extends StatefulWidget {
  const _AgentSettingsRow({
    super.key,
    required this.agent,
    required this.onSave,
    required this.onDelete,
  });

  final AcpAgentConfig agent;
  final ValueChanged<AcpAgentConfig> onSave;
  final VoidCallback onDelete;

  @override
  State<_AgentSettingsRow> createState() => _AgentSettingsRowState();
}

class _AgentSettingsRowState extends State<_AgentSettingsRow> {
  late final TextEditingController _label = TextEditingController(
    text: widget.agent.label,
  );
  late final TextEditingController _command = TextEditingController(
    text: widget.agent.command,
  );
  late final TextEditingController _arguments = TextEditingController(
    text: widget.agent.arguments.join(' '),
  );
  late final TextEditingController _environment = TextEditingController(
    text: formatEnvironment(widget.agent.environment),
  );
  bool _dirty = false;

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    _arguments.dispose();
    _environment.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AgentSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty &&
        (oldWidget.agent.id != widget.agent.id ||
            oldWidget.agent.label != widget.agent.label ||
            oldWidget.agent.command != widget.agent.command ||
            oldWidget.agent.arguments != widget.agent.arguments ||
            oldWidget.agent.environment != widget.agent.environment)) {
      _label.text = widget.agent.label;
      _command.text = widget.agent.command;
      _arguments.text = widget.agent.arguments.join(' ');
      _environment.text = formatEnvironment(widget.agent.environment);
    }
  }

  void _markDirty([String? _]) {
    if (_dirty) return;
    setState(() => _dirty = true);
  }

  void _save() {
    final label = _label.text.trim();
    final command = _command.text.trim();
    if (label.isEmpty || command.isEmpty) return;
    widget.onSave(
      AcpAgentConfig(
        id: widget.agent.id,
        label: label,
        command: command,
        arguments: _arguments.text.trim().isEmpty
            ? const []
            : _arguments.text.trim().split(RegExp(r'\s+')),
        environment: parseEnvironment(_environment.text),
        description: widget.agent.description,
      ),
    );
    setState(() => _dirty = false);
  }

  @override
  Widget build(BuildContext context) => SettingsCard(
    children: [
      SettingsRow(label: 'Name', trailing: _field(_label, 'Agent name')),
      SettingsRow(
        label: 'Command',
        trailing: _field(
          _command,
          'Executable on the project machine',
        ),
      ),
      SettingsRow(
        label: 'Arguments',
        trailing: _field(_arguments, 'Arguments separated by spaces'),
      ),
      SettingsRow(
        label: 'Environment',
        below: [
          IdeInputBox(
            controller: _environment,
            semanticsLabel: 'Environment',
            minLines: 2,
            maxLines: 5,
            onChanged: _markDirty,
          ),
        ],
      ),
      SettingsRow(
        label: 'Actions',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdeButton(
              label: 'Save',
              icon: Codicons.check,
              onPressed: _dirty ? _save : null,
            ),
            const SizedBox(width: 8),
            IdeButton(
              label: 'Remove agent',
              icon: Codicons.trash,
              secondary: true,
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _field(TextEditingController controller, String label) => SizedBox(
    width: 300,
    child: IdeInputBox(
      controller: controller,
      semanticsLabel: label,
      onChanged: _markDirty,
    ),
  );
}

String formatEnvironment(Map<String, String> environment) =>
    [for (final entry in environment.entries) '${entry.key}=${entry.value}']
        .join('\n');

Map<String, String> parseEnvironment(String text) => {
  for (final line in text.split('\n'))
    if (line.contains('='))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};
