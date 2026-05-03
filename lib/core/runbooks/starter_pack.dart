import 'runbook.dart';

/// Curated, read-only starter runbooks shown alongside the user's
/// personal list. They live in source code (not storage) so they
/// always travel with the app — no sync needed, no risk of a
/// half-written upload destroying them.
///
/// Editing a starter copies it into the user's personal list with a
/// fresh id; the original stays untouched.
const List<Runbook> starterPackRunbooks = [
  Runbook(
    id: 'starter-disk-and-port',
    name: 'Find what is hogging port and disk',
    description:
        'Reports listeners on a chosen port plus the top-3 largest '
        'directories under /var. Read-only.',
    starter: true,
    params: [
      RunbookParam(
        name: 'port',
        label: 'Port to inspect',
        defaultValue: '80',
        required: true,
      ),
    ],
    steps: [
      RunbookStep(
        id: 's1',
        label: 'Listeners on port',
        type: RunbookStepType.command,
        command: 'ss -tulpn | grep ":{{port}} " || echo "no listeners"',
      ),
      RunbookStep(
        id: 's2',
        label: 'Top dirs in /var',
        type: RunbookStepType.command,
        command: 'du -sh /var/* 2>/dev/null | sort -hr | head -3',
      ),
      RunbookStep(
        id: 's3',
        label: 'AI digest',
        type: RunbookStepType.aiSummarize,
        aiPrompt:
            'Look at the listeners + disk output. Flag anything suspicious.',
      ),
    ],
  ),
  Runbook(
    id: 'starter-restart-nginx',
    name: 'Restart nginx safely',
    description:
        'Validates the nginx config first; only restarts if the test passes.',
    starter: true,
    steps: [
      RunbookStep(
        id: 'test',
        label: 'nginx -t',
        type: RunbookStepType.command,
        command: 'sudo nginx -t 2>&1',
      ),
      RunbookStep(
        id: 'restart',
        label: 'systemctl restart nginx',
        type: RunbookStepType.command,
        command: 'sudo systemctl restart nginx',
        skipIfRegex: r'(emerg|failed|error)',
        skipIfReferenceStepId: 'test',
      ),
      RunbookStep(
        id: 'status',
        label: 'systemctl status nginx',
        type: RunbookStepType.command,
        command: 'sudo systemctl status nginx --no-pager | head -20',
      ),
      RunbookStep(
        id: 'notify',
        label: 'Done',
        type: RunbookStepType.notify,
        notifyMessage: 'nginx restart flow finished — review status.',
      ),
    ],
  ),
  Runbook(
    id: 'starter-journal-errors',
    name: 'Tail and summarize journal errors',
    description:
        'Pulls the last 200 priority<=err journal lines and asks the local '
        'AI to group them.',
    starter: true,
    steps: [
      RunbookStep(
        id: 'pull',
        label: 'journalctl -p err -n 200',
        type: RunbookStepType.command,
        command: 'journalctl -p err -n 200 --no-pager',
      ),
      RunbookStep(
        id: 'digest',
        label: 'AI digest',
        type: RunbookStepType.aiSummarize,
        aiPrompt:
            'Group these errors by service and topic, list each group with a '
            'count, and call out anything that looks like an incident.',
        aiReferenceStepId: 'pull',
      ),
    ],
  ),
  Runbook(
    id: 'starter-deploy-git',
    name: 'Deploy via git pull + service restart',
    description:
        'Pulls the latest commit on a chosen branch, then restarts a chosen '
        'systemd unit. Asks the user for both before running.',
    starter: true,
    params: [
      RunbookParam(
        name: 'repoDir',
        label: 'Repository directory',
        defaultValue: '/srv/app',
        required: true,
      ),
      RunbookParam(
        name: 'branch',
        label: 'Branch',
        defaultValue: 'main',
        required: true,
      ),
      RunbookParam(
        name: 'unit',
        label: 'systemd unit',
        defaultValue: 'app.service',
        required: true,
      ),
    ],
    steps: [
      RunbookStep(
        id: 'pull',
        label: 'git pull',
        type: RunbookStepType.command,
        command: 'cd {{repoDir}} && git fetch && git checkout {{branch}} && '
            'git pull --ff-only',
      ),
      RunbookStep(
        id: 'restart',
        label: 'systemctl restart',
        type: RunbookStepType.command,
        command: 'sudo systemctl restart {{unit}}',
      ),
      RunbookStep(
        id: 'status',
        label: 'status',
        type: RunbookStepType.command,
        command: 'sudo systemctl status {{unit}} --no-pager | head -20',
      ),
    ],
  ),
  Runbook(
    id: 'starter-cert-check',
    name: 'Check TLS cert expiry',
    description:
        'Reports the expiry date for the cert behind a given hostname:port. '
        'Read-only.',
    starter: true,
    params: [
      RunbookParam(
        name: 'host',
        label: 'Host',
        defaultValue: 'example.com',
        required: true,
      ),
      RunbookParam(
        name: 'port',
        label: 'Port',
        defaultValue: '443',
        required: true,
      ),
    ],
    steps: [
      RunbookStep(
        id: 'expiry',
        label: 'openssl s_client',
        type: RunbookStepType.command,
        command:
            'echo | openssl s_client -servername {{host}} -connect {{host}}:{{port}} 2>/dev/null '
            '| openssl x509 -noout -dates',
      ),
      RunbookStep(
        id: 'digest',
        label: 'AI digest',
        type: RunbookStepType.aiSummarize,
        aiPrompt:
            'Read the openssl output and report how many days remain until '
            'expiry, plus a yes/no on whether it needs renewing in the next 14 '
            'days.',
      ),
    ],
  ),
  Runbook(
    id: 'starter-process-snapshot',
    name: 'Process + memory snapshot',
    description:
        'Captures top 10 processes by RSS and the system memory summary. '
        'Read-only.',
    starter: true,
    steps: [
      RunbookStep(
        id: 'mem',
        label: 'free -h',
        type: RunbookStepType.command,
        command: 'free -h',
      ),
      RunbookStep(
        id: 'top',
        label: 'top processes',
        type: RunbookStepType.command,
        command: 'ps -eo pid,user,rss,cmd --sort=-rss | head -11',
      ),
      RunbookStep(
        id: 'digest',
        label: 'AI digest',
        type: RunbookStepType.aiSummarize,
        aiPrompt:
            'Summarize whether the server has memory pressure and which '
            'process is using the most.',
      ),
    ],
  ),
];
