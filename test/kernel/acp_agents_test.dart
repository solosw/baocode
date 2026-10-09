import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/acp/acp_agent.dart';
import 'package:baocode/kernel/acp_agents.dart';
import 'package:baocode/settings/user_settings.dart';

void main() {
  test('stores and reads multiple ACP agent configurations', () async {
    final settings = UserSettings('test/settings.json');
    final agents = AcpAgents(settings);
    final first = const AcpAgentConfig(
      id: 'claude-acp',
      label: 'Claude ACP',
      command: 'claude',
      arguments: ['--acp'],
      environment: {'MODE': 'test'},
    );
    final second = const AcpAgentConfig(
      id: 'codex-acp',
      label: 'Codex ACP',
      command: 'codex',
    );

    await agents.save([first, second]);
    expect(agents.agents.map((agent) => agent.id), ['claude-acp', 'codex-acp']);
    expect(agents.agents.first.arguments, ['--acp']);
    expect(agents.agents.first.environment['MODE'], 'test');

    await agents.remove(first.id);
    expect(agents.agents.map((agent) => agent.id), ['codex-acp']);
    agents.dispose();
  });
}
