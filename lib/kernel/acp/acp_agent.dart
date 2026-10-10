import '../../remote/remote_acp.dart';
import 'acp_transport.dart';

/// Configuration for one ACP agent executable.
class AcpAgentConfig {
  const AcpAgentConfig({
    required this.id,
    required this.label,
    required this.command,
    this.arguments = const [],
    this.environment = const {},
    this.description = 'Agent Client Protocol agent',
  });

  final String id;
  final String label;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String description;

  /// On the project's host: this machine, or the remote one an `ssh://`
  /// project names. Slash commands come from that process.
  AcpTransportFactory get transport =>
      (context) => startAcpAgent(
        command,
        arguments: arguments,
        location: context.cwd,
        environment: environment.isEmpty ? null : environment,
      );
}
