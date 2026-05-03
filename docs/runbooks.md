# Hamma Runbooks

Hamma Runbooks turn ad-hoc multi-step ops procedures (deploys, rollbacks, cert
rotations, log triage) into named, parameterized, AI-assisted, risk-gated
workflows. They live next to your snippets and ride the same encrypted cloud
sync transport when you tag them `team`.

## Overview

A runbook is a JSON document with:

- `name` / `description` — what it does and when to use it.
- `params` — values collected once at run start (`{{paramName}}` interpolation).
- `steps` — ordered list of typed nodes the runner walks.
- `serverId` — pin to one server, or omit to make it global.
- `team` — opt in to ride the cloud sync transport.

Runbooks are persisted in `flutter_secure_storage` under `runbooks_v1` and
exposed to the dashboard via the **Runbooks** tab on every server. A curated
**starter pack** ships in source code (see
`lib/core/runbooks/starter_pack.dart`) and is read-only — editing a starter
copies it into your personal list.

## Step types

The on-disk JSON discriminator (`type` field) is **hyphenated**. The Dart
camelCase enum names are also accepted on read for back-compat with any
existing saved blob; new writes always use the hyphenated form.

| `type`          | Purpose                                                 |
| --------------- | ------------------------------------------------------- |
| `command`       | Execute bash on the active SSH session.                 |
| `prompt-user`   | Pause and ask the operator for a value at runtime.      |
| `wait-for`      | `time` (sleep), `regex` (match prior output), `manual`. |
| `branch`        | Regex-gated `if/else` jump to another step id.          |
| `ai-summarize`  | Run prior output through the configured AI for digest.  |
| `notify`        | Surface a toast / system notification.                  |

Every step also supports:

- `continueOnError` — keep running even if this step fails.
- `skipIfRegex` + `skipIfReferenceStepId` — conditional skip when a previous
  step's stdout matches a pattern.

### `branch` step

A `branch` step evaluates `branchRegex` (multiline) against the stdout of
`branchReferenceStepId` (or the previous step if unset). On a match the
runner jumps to the step whose id matches `branchTrueGoToStepId`; otherwise
it jumps to `branchFalseGoToStepId`. Either target may be omitted to mean
"fall through to the next step" — that's how you write a one-armed `if`.

Jump targets may point forward (skip ahead) or backward (loop). To keep
runaway loops loud rather than silent, the runner caps total step
executions at `steps.length * 8` and aborts the run with `cancelled` if the
ceiling is hit.

## Templating

Inside any string field you can interpolate:

- `{{paramName}}` — value from `params` or set by a `promptUser` step.
- `{{step.<id>.stdout}}` — captured stdout from an earlier step.

Unknown tokens are left intact so partially-rendered commands stay visible.

## Safety model

Every `command` step is graded by `CommandRiskAssessor` before execution.
Anything above `LOW` triggers an inline confirm dialog showing the rendered
command, the risk level, and the assessor's explanation — exactly the same
gate the AI Assistant safety queue uses today. Refusing the gate marks the
step `cancelled` and stops the run unless `continueOnError: true`.

`aiSummarize` steps prefer the local LLM (zero-trust). If the active provider
is a hosted one, the digest is still produced but the output crosses your
network boundary the same way the rest of the AI Assistant does.

## Authoring walkthrough

1. Open a server's **Runbooks** tab.
2. Tap **NEW** for a blank runbook, or **ASK AI** to draft one from a goal
   sentence ("rotate the letsencrypt cert on this host") via the local model.
3. Add parameters and steps. Use the drag handle to reorder.
4. Use **DRY RUN** to see exactly which commands would hit the wire — no SSH
   side effects.
5. **SAVE**. Validation runs first; missing fields are listed inline.
6. Tap the runbook to launch the live-progress run view. The big red **STOP**
   button cancels at the next step boundary; the in-flight command finishes
   on its own (see *Cancellation semantics* below).

## Cancellation semantics

The runner exposes a `RunbookCancellation` token with two surfaces:

- A polled `isCancelled` flag the main loop checks between steps.
- An `onCancel(VoidCallback)` listener API the SSH adapter uses to register
  a teardown callback.

The dashboard's run-screen wires every command through `streamCommand`,
which returns an `SSHSession` we can `close()`. Pressing **STOP** flips the
flag *and* fires every registered listener, which terminates the in-flight
SSH session immediately rather than waiting for the remote command to
drain. The cancelled command is reported as status `cancelled` (not
`failed`), and all later steps are skipped with the same status.

## Sync ride-along

Runbooks tagged `team: true` are pushed through the existing snippet sync
transport (`BackupCrypto` over the configured cloud destination) under the
sibling object key `snippets/runbooks.aes`. Per-runbook newest-wins merge
honours the same tombstone discipline as snippet sync. Non-team runbooks
never leave the originating device.

## Starter pack

The repo ships with six curated runbooks covering everyday ops:

- Find what is hogging port and disk
- Restart nginx safely (config-test gated)
- Tail and summarize journal errors
- Deploy via `git pull` + service restart
- Check TLS cert expiry
- Process + memory snapshot

Pull from `lib/core/runbooks/starter_pack.dart` and copy any of them into your
personal list as a starting point for your own workflows.
