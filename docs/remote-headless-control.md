# Headless CLI Automation

Ourocode can be used as an interactive TUI or as a headless command surface for
automation. The headless path returns JSON evidence instead of opening the
terminal UI. This document covers local CLI automation; true remote daemons,
webhooks, scheduling, and mobile control are not part of this release.

## Verify

Run the product verification suite:

```bash
./ourocode --verify --format json --project-dir .
```

The JSON result includes a product-facing verification summary. Use
`--format json-debug` when you need raw diagnostic checks, render captures, and
terminal replay evidence.

Useful fields:

```json
{
  "ok": true,
  "status": "passed",
  "verification": {
    "status": "passed",
    "checks": [
      {"name": "startup ready", "passed": true},
      {"name": "tools connected", "passed": true},
      {"name": "agent workspace ready", "passed": true},
      {"name": "guided interview ready", "passed": true},
      {"name": "terminal UI ready", "passed": true}
    ]
  }
}
```

## Headless Prompts

Run a command without opening the TUI:

```bash
./ourocode --prompt "/agents" --format json --project-dir .
./ourocode --prompt "/mcps" --format json --project-dir .
./ourocode --prompt "/sandbox" --format json --project-dir .
```

Run guided work from automation:

```bash
./ourocode --prompt "ooo pm design plugin onboarding" --format json --project-dir .
```

Headless output reports prompt status, product events, a human-facing result,
and a compact workspace summary when the command opens a management view.

For automation, read `result` for the human-facing output and `events` for the
step timeline:

```json
{
  "prompt": "/agents",
  "result_available": true,
  "result": "agents workspace · Agents\nStatus · ready · 0 active · 3 items\nList\n  >> PM interview  ready · ready\nSelected\n  PM interview · ready\n  task · start with ooo pm <goal>\nUse · ooo pm <goal> | /sessions | /cancel | /verify",
  "workspace": {
    "kind": "agents",
    "title": "Agents",
    "status": "ready · 0 active",
    "records": [
      {"title": "PM interview", "state": "ready", "health": "ready"}
    ]
  }
}
```

## Delegated Agents

Use `/agents` for the first-class active-work view:

```bash
./ourocode --prompt "/agents" --format json --project-dir .
```

The TUI also exposes `/sessions` and `/children` for active workspaces and
steering targets. New guided work starts with `ooo pm <goal>`.

`/agents` shows state, task, current output, and actions:

```text
agents workspace · Agents
Status · ready · 0 active · 3 items
List
  >> PM interview  ready · ready
     Question helper  standby · ready
     Verifier  guarded · ready
Selected
  PM interview · ready
  task · start with ooo pm <goal>
  current · waiting for a goal
Use · ooo pm <goal> | /sessions | /cancel | /verify
```

## Plugins

Use `/mcps` or `/mcp` to inspect connected-tool readiness and actions:

```bash
./ourocode --prompt "/mcps" --format json --project-dir .
```

Use `/plugins` and `/skills` to inspect configured plugin and skill surfaces.

Example result:

```text
mcps workspace · Connected tools
Status · connected · 1 item
List
  >> Guided workflows  loaded · ready
Selected
  Guided workflows · loaded
  access · workspace read/write, reviewed commands
  workflows · commands, skills, guided work
Use · /plugins | /verify
```

## Sandbox Posture

Use `/sandbox` to see the current safety posture:

```bash
./ourocode --prompt "/sandbox" --format json --project-dir .
```

The current read path is project-bounded. Parent-directory escapes, symlink
escapes, shell expansion, backslash path escapes, and null-byte paths are
rejected by the interview router sandbox.

Example result:

```text
sandbox workspace · Sandbox
Status · guarded · 4 items
List
  >> Writable Roots  guarded
     Network  review required
     Shell  review required
     Recovery  ready
Selected
  Writable Roots · guarded
  controls · allow project directory, deny parent-directory, deny symlink escape
Use · /preflight <command> | /verify | /cancel
```
