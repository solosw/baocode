import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../l10n/l10n.dart';
import '../../remote/ssh_host_settings.dart';
import '../../theme/codicons.dart';
import 'settings_widgets.dart';

/// Settings → SSH: hosts the app keeps itself (user, port, password or
/// key), instead of only reading `~/.ssh/config`.
class SshHostsSettingsPage extends StatefulWidget {
  const SshHostsSettingsPage({super.key, required this.hosts});

  final SshHostSettings hosts;

  @override
  State<SshHostsSettingsPage> createState() => _SshHostsSettingsPageState();
}

class _SshHostsSettingsPageState extends State<SshHostsSettingsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.hosts.load());
  }

  Future<void> _add() async {
    final next = [
      ...widget.hosts.hosts,
      const SshSavedHost(host: ''),
    ];
    await widget.hosts.save(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: widget.hosts,
      builder: (context, _) => SettingsPage(
        title: l10n.settingsSectionSsh,
        description: l10n.sshSettingsDescription,
        children: [
          SettingsGroup(
            title: l10n.sshSettingsHosts,
            description: l10n.sshSettingsHostsDescription,
            children: [
              if (widget.hosts.hosts.isEmpty)
                SettingsRow(label: l10n.sshSettingsEmpty),
              for (final (index, host) in widget.hosts.hosts.indexed)
                _HostEditor(
                  key: ValueKey('$index-${host.host}'),
                  host: host,
                  onSave: (updated, {String? password}) => unawaited(
                    widget.hosts.save(
                      [
                        for (final (i, item) in widget.hosts.hosts.indexed)
                          i == index ? updated : item,
                      ],
                      passwords: password == null
                          ? const {}
                          : {updated.host: password},
                    ),
                  ),
                  onDelete: () => unawaited(
                    widget.hosts.save([
                      for (final (i, item) in widget.hosts.hosts.indexed)
                        if (i != index) item,
                    ], passwords: {host.host: ''}),
                  ),
                ),
              SettingsRow(
                label: l10n.sshSettingsAdd,
                trailing: IdeButton(
                  label: l10n.sshSettingsAdd,
                  icon: Codicons.add,
                  onPressed: () => unawaited(_add()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HostEditor extends StatefulWidget {
  const _HostEditor({
    super.key,
    required this.host,
    required this.onSave,
    required this.onDelete,
  });

  final SshSavedHost host;
  final void Function(SshSavedHost host, {String? password}) onSave;
  final VoidCallback onDelete;

  @override
  State<_HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<_HostEditor> {
  late final TextEditingController _host = TextEditingController(
    text: widget.host.host,
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.host.user,
  );
  late final TextEditingController _port = TextEditingController(
    text: widget.host.port?.toString() ?? '',
  );
  late final TextEditingController _secret = TextEditingController();
  late SshAuthKind _auth = widget.host.auth;

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _port.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _commit({bool password = false}) {
    final port = int.tryParse(_port.text.trim());
    widget.onSave(
      SshSavedHost(
        host: _host.text.trim(),
        user: _user.text.trim(),
        port: port != null && port > 0 ? port : null,
        auth: _auth,
        identityFile: _auth == SshAuthKind.key ? _secret.text.trim() : widget.host.identityFile,
        hasPassword: password
            ? _secret.text.isNotEmpty
            : widget.host.hasPassword,
      ),
      password: password && _auth == SshAuthKind.password ? _secret.text : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final key = _auth == SshAuthKind.key;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(l10n.sshSettingsHost, _host, l10n.sshSettingsHostHint, commit: false),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _field(
                  l10n.sshSettingsUser,
                  _user,
                  l10n.sshSettingsUserHint,
                  commit: false,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: _field(l10n.sshSettingsPort, _port, '22', commit: false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IdeButton(
                label: l10n.sshSettingsPassword,
                secondary: key,
                onPressed: () => setState(() => _auth = SshAuthKind.password),
              ),
              const SizedBox(width: 8),
              IdeButton(
                label: l10n.sshSettingsKey,
                secondary: !key,
                onPressed: () => setState(() {
                  _auth = SshAuthKind.key;
                  _secret.text = widget.host.identityFile;
                }),
              ),
              const Spacer(),
              IdeButton(
                label: l10n.sshSettingsRemove,
                secondary: true,
                icon: Codicons.trash,
                onPressed: widget.onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _field(
            key ? l10n.sshSettingsKeyPath : l10n.sshSettingsPassword,
            _secret,
            key
                ? l10n.sshSettingsKeyHint
                : (widget.host.hasPassword
                      ? l10n.sshSettingsPasswordKept
                      : l10n.sshSettingsPasswordHint),
            obscure: !key,
            onSubmitted: (_) => _commit(password: !key),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: IdeButton(
              label: l10n.sshSettingsSave,
              onPressed: () => _commit(password: !key),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    bool obscure = false,
    bool commit = true,
    ValueChanged<String>? onSubmitted,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SettingsText.description),
        const SizedBox(height: 4),
        IdeInputBox(
          controller: controller,
          placeholder: hint,
          obscureText: obscure,
          semanticsLabel: label,
          onSubmitted: onSubmitted ?? (commit ? (_) => _commit() : null),
        ),
      ],
    );
  }
}
