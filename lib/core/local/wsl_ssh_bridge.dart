import 'dart:io';
import '../models/server_profile.dart';

class WslSshBridge {
  static const int _wsldPort = 2299; // arbitrary free port for WSL sshd

  /// Returns true if we are on Windows and WSL is available.
  static Future<bool> get isAvailable async {
    if (!Platform.isWindows) return false;
    final r = await Process.run('wsl.exe', ['--status'])
        .catchError((_) => ProcessResult(-1, 1, '', ''));
    return r.exitCode == 0;
  }

  /// One-time setup: installs openssh-server in WSL, configures sshd
  /// on _wsldPort with password auth enabled, and sets up passwordless
  /// sudo for the WSL user. Returns the WSL username.
  static Future<String> setup() async {
    // Get WSL username
    final userResult = await Process.run(
        'wsl.exe', ['bash', '-c', 'echo \$USER']);
    final wslUser = (userResult.stdout as String).trim();

    // Run the full setup as a single bash script piped to wsl.
    // This installs sshd, sets a known password, enables PasswordAuth,
    // sets port, and adds NOPASSWD sudo — all in one shot.
    const setupScript = r'''
set -e
# Install openssh-server if missing
which sshd >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq openssh-server)
# Configure sshd
mkdir -p /run/sshd
grep -q "Port 2299" /etc/ssh/sshd_config || echo "Port 2299" >> /etc/ssh/sshd_config
grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
# Set a known password for the WSL user so SSH can auth
echo "${USER}:hamma_local_bridge_2024" | chpasswd
# Passwordless sudo
echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/hamma
chmod 0440 /etc/sudoers.d/hamma
# Regenerate host keys if missing
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A
''';

    await Process.run('wsl.exe', ['bash', '-c', 'sudo bash -c "\$@"', '--', setupScript]);
    return wslUser;
  }

  /// Starts sshd inside WSL on _wsldPort (if not already running).
  static Future<void> startSshd() async {
    await Process.run('wsl.exe', [
      'bash', '-c',
      'pgrep -f "sshd.*2299" >/dev/null || sudo /usr/sbin/sshd -p 2299'
    ]);
  }

  /// Returns a ServerProfile that SshService can connect to,
  /// targeting the WSL sshd we just started.
  static ServerProfile profileFor(String wslUser) {
    return ServerProfile(
      id: '__wsl_local__',
      name: 'Local (WSL)',
      host: '127.0.0.1',
      port: _wsldPort,
      username: wslUser,
      password: 'hamma_local_bridge_2024',
    );
  }
}
