# Ourocode Product Vision

This document records the product boundary for `ourocode` and links the
implementation direction back to the SSOT in GitHub issue #25:

https://github.com/Q00/ourocode/issues/25

`ourocode` should be the terminal-native orchestration layer for Ouroboros work.
It should not become a thin command launcher, and it should not reimplement
Ouroboros execution semantics.

In short: Ouroboros owns execution semantics; `ourocode` owns the operator
experience.

## What Ourocode Owns

- Prompt intake and intent routing for interactive terminal use.
- Child panes, progress surfaces, status, and recoverable session state.
- Human-readable continuation UX after tools produce Seeds, handoffs, evidence,
  reports, or review artifacts.
- Safe bridges into Ouroboros MCP, CLI, plugin, and child-session APIs.
- Clear rendering of trust, permission, ambiguity, failure, and blocked states.
- A durable orchestration timeline that can be replayed or recovered.

## What Ourocode Does Not Own

- Plugin trust policy or firewall semantics.
- Arbitrary shell execution assembled from model output.
- A duplicate plugin registry, marketplace, or package manager.
- Core Ouroboros workflow definitions that belong in Ouroboros itself.
- Hidden automatic permission grants.
- Plugin-internal storage conventions or implementation paths.

## Core Primitives

### Intent Routing

Direct commands and natural-language prompts should resolve through the same
routing boundary. Ambiguous intent should produce clarification or an explicit
blocked state instead of guessing.

### Capability Resolution

Installed capabilities should be resolved through authoritative Ouroboros
surfaces where possible. Resolution should expose identity, command metadata,
trust state, expected inputs, expected outputs, and risk class.

Discovery is read-only. It must never install, trust, or execute by itself.

### Preflight

Before execution, `ourocode` should show what capability will run, why it
matched, what trust boundary applies, and what side effects are expected.
Missing trust should be actionable but non-destructive.

### Invocation And Result Envelope

Core workflows, plugins, and child sessions should report through a shared
envelope for status, output, artifacts, errors, and continuation hints. This
prevents every integration from inventing its own rendering and recovery path.

### Artifacts And Continuations

Generated Seeds, handoffs, reports, logs, and evidence should become first-class
session artifacts. Continuation into `ooo run` or another workflow should be
suggested, confirmed, or blocked according to explicit policy.

Artifact handling should rely on stable runtime or plugin artifact contracts,
not internal storage paths.

### Durable Session Timeline

User intent, routing decisions, trust blocks, invocations, artifacts,
continuation choices, and verification signals should survive refresh and
recovery where possible. A user should be able to inspect how a workflow got
from prompt to outcome.

## Implementation Rules

- Keep implementation issues scoped to one primitive or one thin vertical slice.
- Do not add plugin-specific special cases where a generic capability or
  invocation primitive is the real missing layer.
- Do not route natural language into shell strings.
- Do not treat internal plugin storage paths as public contracts.
- Prefer small modules with explicit data contracts over broad coordinator
  modules that parse, dispatch, render, and persist in one place.
- Add tests at the boundary being introduced: routing, resolution, preflight,
  invocation envelope, artifact projection, trust state, or recovery.

## First Plugin-Orchestration Slice

The first plugin-oriented implementation should start with capability
resolution and preflight, not full natural-language plugin automation.

A good first slice proves that `ourocode` can:

1. Read installed capability metadata through an authoritative surface or fixture.
2. Normalize identity, command metadata, trust state, inputs, outputs, and risk.
3. Resolve a direct command-shaped prompt to one capability.
4. Render a preflight result that explains the match and trust boundary.
5. Stop before execution when the capability is missing, ambiguous, or untrusted.

Only after that layer is stable should `ourocode` add plugin invocation,
artifact continuation, and broader natural-language routing.
