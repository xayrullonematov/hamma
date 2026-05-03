# Live observability — agentless metrics + AI "Explain this spike"

Hamma's **Health** tab gives you a live, brutalist view of CPU, memory,
disk, network and load on each server — without installing an agent,
without opening another port, and without shipping anything off the box.
It's powered by parsed output from standard Linux tools that already
ship on every distro.

## Architecture

```
SshService.execute()
        │
        ▼
MetricPoller ─── periodic batch ──► top / free / df / /proc/net/dev / /proc/loadavg
        │
        ▼
MetricParsers ─── typed snapshot ──► RollingBuffer (per metric, 60 min)
        │                                    │
        ▼                                    ▼
HealthTab UI                            anomaly detector (z-score + hysteresis)
        │
        ▼
ObservabilityExplainer ──► local LLM ──► LogInsight (re-rendered)
```

### Poller

`MetricPoller` (in `lib/core/observability/metric_poller.dart`) issues
one SSH round-trip per tick, batching every detected source into a
single `bash` command separated by `===HAMMA-<NAME>===` markers. The
parser splits the response by marker and feeds each section to the
appropriate parser in `metric_parsers.dart`. Polling defaults to **5 s**
and is configurable in **2–60 s** range.

### Feature detection

On first start the poller runs a tiny shell probe:

```sh
command -v top >/dev/null 2>&1 && echo TOP
command -v free >/dev/null 2>&1 && echo FREE
command -v df >/dev/null 2>&1 && echo DF
[ -r /proc/net/dev ] && echo NETDEV
[ -r /proc/loadavg ] && echo LOADAVG
```

The `HostCapabilities` set is cached for the SSH session. Tiles only
appear for tools that were actually detected — Alpine boxes without
`top` simply skip the CPU tile rather than show "—" forever.

### Anomaly detection

`RollingBuffer` keeps a fixed-window ring (default 720 samples = 60 min
at 5 s) per metric. Each `push` returns a z-score over the prior N-1
samples. A tile is marked anomalous when:

- the buffer has at least `minSamplesForAnomaly` samples, AND
- `|z| ≥ zScoreThreshold` (default 3.0)

Once flagged, the buffer applies **hysteresis** — it stays anomalous
until `|z| < zScoreThreshold − hysteresis` (default 2.0). This
suppresses banner flapping on noisy series. Disk usage anomalies are
suppressed entirely because a logrotate cycle would otherwise trip them.

### Explain this spike

Tapping **EXPLAIN** on a tile builds a single prompt containing:

1. The metric name and unit.
2. The last ~10 minutes of `(timestamp, value)` samples from the buffer.
3. The most recent `journalctl -n 200` (or `tail /var/log/syslog`)
   tail, fetched in the same call.

The prompt is sent through `AiCommandService` and the response is
parsed as the same strict-JSON `LogInsight` schema the log-triage
screen already understands, so the diagnosis card uses identical
rendering. Any `suggestedCommand` is risk-gated through
`CommandRiskAssessor.assessFast` — critical-risk suggestions are
shown with a **BLOCKED** badge and the copy/run buttons are hidden.

### Zero-trust posture

The explainer **refuses any non-local AI provider**. Calling
`ObservabilityExplainer.explain` with `AiProvider.openAi` (or any other
remote provider) throws `ObservabilityExplainerException` before a
single byte of metrics or log lines leaves the device. The Health tab
mirrors this with a header pill — `LOCAL AI ON` when the user has
configured a local provider, or `LOCAL AI REQUIRED FOR EXPLAIN` (and
disabled Explain buttons) otherwise.

The same guarantee applies to the `WATCH WITH AI` cross-link, which
hands off to the existing `WatchWithAiScreen` — that screen already
enforces local-only.

## Out of scope (v1)

- Cross-server fleet view of metrics.
- Persistent / historical metric storage — buffers are in-memory and
  drop on tab close or reconnect.
- Background alerts when the app is closed — needs a daemon.
- Container-level (per-Docker) metrics — tracked separately.
- Custom user-defined metric commands.
