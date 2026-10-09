import 'acp_transport.dart';
import 'acp_transport_io.dart';

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

  AcpTransportFactory get transport =>
      (context) => StdioAcpTransport.start(
        command,
        arguments: arguments,
        workingDirectory: context.cwd,
        environment: environment.isEmpty ? null : environment,
      );
}
