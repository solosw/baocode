import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/remote/ssh_host_settings.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('baocode-ssh-hosts'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'saved hosts persist user, port and key; password stays in secrets',
    () async {
      final settings = UserSettings(p.join(dir.path, 'settings.json'));
      addTearDown(settings.dispose);
      await settings.load();
      final secrets = MemorySecretStore();
      final hosts = SshHostSettings(settings: settings, secrets: secrets);

      await hosts.save(
        [
          const SshSavedHost(
            host: '10.0.0.8',
            user: 'dev',
            port: 2222,
            auth: SshAuthKind.password,
          ),
          const SshSavedHost(
            host: 'git.example',
            auth: SshAuthKind.key,
            identityFile: '/tmp/id_ed25519',
          ),
        ],
        passwords: {'10.0.0.8': 'hunter2'},
      );

      expect(hosts.targets, ['10.0.0.8:2222', 'git.example']);
      expect(
        await secrets.read(SshHostSettings.passwordId('10.0.0.8')),
        'hunter2',
      );
      expect(settings['remote.ssh.hosts'], isA<List>());

      final again = SshHostSettings(settings: settings, secrets: secrets);
      await again.load();
      expect(again.match('10.0.0.8:2222')?.user, 'dev');
      expect(again.match('10.0.0.8:2222')?.hasPassword, isTrue);
      expect(again.match('git.example')?.identityFile, '/tmp/id_ed25519');
      expect(again.optionsFor(SshTarget.parse('10.0.0.8:2222'))?.user, 'dev');
      expect(again.optionsFor(SshTarget.parse('10.0.0.8:2222'))?.port, 2222);
      expect(
        again.optionsFor(SshTarget.parse('git.example'))?.identityFile,
        '/tmp/id_ed25519',
      );
    },
  );
}
