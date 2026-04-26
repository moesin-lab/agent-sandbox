# Agent Containment Starter Kit Design

## Summary

This repository is a macOS + Docker Desktop focused starter kit for running coding agents inside a constrained sandbox while preserving a usable developer workflow.

The project turns three ideas into one cohesive system:

1. A `sandbox` module that runs the agent in a Docker container with opinionated defaults and limited direct network reach.
2. An `mcp` module that exposes sensitive or high-value external capabilities through controlled tools instead of direct shell networking.
3. A `proxy` module that provides an alternate gated egress path for allowlisted traffic such as package registries and docs.

The project is not only a Docker sandbox template. It is a single repository reference implementation where `sandbox`, `mcp`, and `proxy` are first-class modules, can be composed into standard operating modes, and are packaged behind a unified operator interface.

## Goals

- Provide an opinionated, mostly turnkey setup for running an agent safely on macOS + Docker Desktop.
- Make direct access to sensitive remote targets harder than using the intended controlled path.
- Support three standard runtime modes: `mcp-only`, `proxy-gated`, and `hybrid`.
- Keep the repository extensible so new MCP services, proxy rules, and runtime profiles can be added without restructuring the project.
- Keep runtime data self-contained inside the repository instead of spreading state across the host machine.

## Non-Goals

- Cross-platform support for Windows, WSL, or generic Linux in the first version.
- A full GitHub automation product with complete workflow coverage.
- A general purpose orchestration platform for many concurrent agent instances.
- A dashboard or web UI in the first version.
- Support for multiple proxy implementations in v1.

## Problem Statement

Coding agents tend to fall back to their strongest prior habits. If they can run unrestricted shell commands, they often prefer direct `curl` or CLI calls over safer, higher-level integrations. For services such as GitHub, this creates abuse and rate-limit risks:

- MCP may exist, but the agent can bypass it.
- Fine-grained tokens do not solve retry storms or reckless request patterns.
- Prompt instructions are not a reliable enforcement boundary.

The system therefore needs infrastructure-level containment:

- The agent should not be able to directly reach sensitive endpoints by default.
- Sensitive capabilities should be exposed through explicitly controlled interfaces.
- Ordinary development tasks should still remain practical.

## Design Principles

### Controlled capability egress

Dangerous or high-value network actions should flow through dedicated, inspectable service boundaries. The design treats shell networking as untrusted by default.

### Opinionated defaults

The repository should be directly usable with minimal edits. Users should not need to design their own layout before they can start.

### Stable module boundaries

The system should separate:

- the agent runtime container,
- the controlled external capability layer,
- the network egress control layer,
- the orchestration layer that composes them.

### Extension by configuration

Profiles, rules, and service selection should live in configuration files rather than hard-coded shell logic wherever possible.

### Repository-local runtime state

Host-side mounts, logs, state, and persistent home data should live under repository-managed runtime directories that are ignored by Git.

## Repository Shape

The repository should be organized around stable responsibilities rather than ad hoc scripts:

```text
.
├── bin/
├── config/
├── docs/
├── mcp/
├── orchestration/
├── proxy/
├── runtime/
├── sandbox/
└── templates/
```

### `sandbox/`

Owns the agent container runtime:

- Dockerfile
- entrypoint
- watchdog
- startup wrapper
- shell initialization
- runtime mount conventions

Its responsibility is to provide a stable, constrained execution cabin for the agent.

### `mcp/`

Owns controlled external capabilities and should treat services as composable modules:

- `services/` for concrete capability providers such as `github/` and `web/`
- `profiles/` for capability sets exposed to different agent roles or use cases

This keeps the project extensible. Adding a new tool surface should mean adding a service module and wiring it into a profile, not rewriting the sandbox.

### `proxy/`

Owns the gated network egress implementation:

- one default proxy implementation in v1
- rules directory for allowlist and blocklist policy
- validation artifacts for egress behavior

Proxy logic remains independent from the sandbox so the proxy can evolve or be replaced later.

### `orchestration/`

Owns composition and lifecycle:

- service composition files
- mode selection logic
- health checks
- environment assembly
- operator commands used by the `bin/` entrypoint

It should assemble modules; it should not absorb their internal behavior.

### `config/`

Owns all user-tunable project settings:

- environment variables
- path defaults
- profile declarations
- MCP service/profile selection
- proxy rule selection
- workspace mapping

This is the main extensibility layer.

### `templates/`

Owns example host integrations and starter config:

- sample `.env`
- sample shell function wrapper
- sample override files

Users can copy or adapt these without mutating core source files.

### `runtime/`

Owns mutable host-side runtime state and is Git-ignored:

- `runtime/workspaces/`
- `runtime/home/`
- `runtime/logs/`
- `runtime/state/`

This directory makes the repository self-contained and avoids reliance on a fixed host path like `~/cc_mnt`.

### `docs/`

Owns operator and maintainer documentation:

- quick start
- architecture
- profiles
- security model
- extension guide
- verification guide
- troubleshooting

## Runtime Modes

The repository should ship with three first-class runtime profiles.

### `mcp-only`

Characteristics:

- agent container does not get general outbound network access
- sensitive operations are only available through MCP services
- web lookups, GitHub actions, and similar capabilities are delegated to the controlled service layer

Primary use case:

- safest default mode for automated agent work where abuse resistance matters more than convenience

### `proxy-gated`

Characteristics:

- agent container uses the repository's proxy for outbound access
- allowlisted dependency and documentation endpoints are reachable
- sensitive targets such as GitHub API remain blocked at the egress layer

Primary use case:

- development tasks that need package installation and docs access while still preventing direct access to protected targets

### `hybrid`

Characteristics:

- ordinary outbound traffic goes through the allowlisted proxy path
- sensitive actions still require MCP
- combines day-to-day developer convenience with capability containment for higher-risk operations

Primary use case:

- default interactive development profile when users need both package fetching and safe GitHub/tool access

## Mode Representation

Modes should be represented as data, not as fragile shell branching.

Each mode configuration should declare:

- which services are enabled
- whether proxy variables are injected into the sandbox
- which MCP profile is exposed
- which proxy rule set applies
- which health checks are expected
- which runtime dependencies need to start

As a result, adding a future profile such as `offline-strict` or `research-heavy` should be configuration work, not a major code rewrite.

## Host Runtime Layout

The repository should own the host-side mounted data layout.

Recommended directories:

```text
runtime/
├── home/
├── logs/
├── state/
└── workspaces/
```

### `runtime/workspaces/`

Contains the projects or links that the sandbox is allowed to operate on. This is the repository-local equivalent of the prior `~/cc_mnt` convention.

### `runtime/home/`

Contains persistent user home data for the sandboxed runtime, such as shell history and tool state.

### `runtime/logs/`

Contains logs from sandbox lifecycle scripts, watchdog processes, proxy services, and MCP services.

### `runtime/state/`

Contains sockets, lock files, pid files, and other ephemeral runtime state that should remain inspectable and local to the repository.

All runtime directories should be ignored by Git, with tracked placeholders only where needed to preserve structure.

## Host Integration

The current `claude-sandbox()` shell function demonstrates the desired ergonomics but hard-codes too many personal environment assumptions:

- fixed mount root
- fixed image name
- fixed container name
- fixed Dockerfile location
- implicit project path rules

The repository should keep the ergonomics while moving the logic into a project-owned entrypoint such as `bin/agent-sandbox`.

The shell integration then becomes a thin convenience layer that delegates into the repository, rather than being the repository's source of truth.

## Capability Boundaries

### Sandbox boundary

The sandbox module should assume the agent may attempt arbitrary shell operations. Therefore:

- network policy must not rely on prompt compliance
- sensitive remote access must not depend on shell discipline
- mounted host paths should be explicit and narrow

### MCP boundary

The MCP layer is the controlled channel for high-value actions. At minimum, the first version should include:

- a GitHub-oriented service skeleton for protected external operations
- a web-oriented service skeleton for search/fetch style use cases

These do not need to be feature-complete in v1, but they must demonstrate the intended control plane.

### Proxy boundary

The proxy layer is for gated ordinary network access, not privileged capability execution. Its policy should focus on:

- allowing package registries and docs sources
- blocking protected or abuse-sensitive targets
- making the allowed/blocked surface explicit and reviewable

## Security Model

This project is a containment starter kit, not a hard security sandbox against a determined adversary.

Threat model it addresses:

- accidental or model-driven misuse of shell networking
- direct API hammering by retries or improvisational scripts
- workflow drift away from controlled MCP paths

Threat model it does not fully address in v1:

- hostile code running with kernel escape objectives
- strong tenant isolation for mutually untrusted workloads
- advanced supply chain verification
- secret exfiltration prevention beyond the chosen mount and env boundaries

The docs should state this plainly so operators understand the system as a practical abuse-reduction mechanism rather than a formal security boundary.

## First Version Deliverables

The first version should deliver one complete working loop, not every possible feature.

### Included in v1

- one runnable sandbox image and startup path
- one watchdog and start-wrapper arrangement
- one default proxy implementation
- one GitHub MCP service skeleton
- one web MCP service skeleton
- one unified operator command
- three standard runtime profiles
- repository-local runtime directories
- verification scripts and documentation

### Explicitly excluded from v1

- multiple proxy engines
- multi-instance orchestration
- Windows or WSL support
- complete GitHub automation workflows
- graphical management interfaces

## Operator Experience

The repository should expose one clear control surface.

Example command family:

- `bin/agent-sandbox up mcp-only`
- `bin/agent-sandbox up proxy-gated`
- `bin/agent-sandbox up hybrid`
- `bin/agent-sandbox shell`
- `bin/agent-sandbox logs`
- `bin/agent-sandbox doctor`
- `bin/agent-sandbox down`

These commands should be the stable user interface. Lower-level implementation details in `orchestration/` remain private to the project.

## Verification Requirements

The project is only credible if its boundaries are testable. The first version should include verification steps that prove:

1. the sandbox starts and lands in the expected workspace
2. direct access to blocked targets fails in `mcp-only`
3. allowlisted traffic succeeds and blocked targets fail in `proxy-gated`
4. `hybrid` enables ordinary egress while preserving MCP-only access for sensitive actions
5. watchdog, logs, and runtime state files behave as expected

This validation should be represented both in documentation and in executable verification scripts where practical.

## Documentation Plan

At minimum, the docs set should contain:

- `README.md` for a five-minute startup path
- `docs/architecture.md`
- `docs/profiles.md`
- `docs/security-model.md`
- `docs/extending.md`
- `docs/verification.md`

The documentation should be written for two audiences:

- operators who want to use the template immediately
- maintainers who want to extend it safely

## Extensibility Plan

The project should preserve extension room in three directions.

### Service extensibility

New MCP services should be addable under `mcp/services/` without reworking the sandbox.

### Policy extensibility

New allowlists, blocklists, and runtime profiles should be addable under `config/` and `proxy/rules/` without code duplication.

### Entry-point extensibility

Host convenience commands can evolve or be swapped, but should remain thin wrappers over the repository-owned operator command.

## Migration of Existing Materials

The design should absorb proven pieces from the existing local setup:

- Docker image conventions from `~/.claude/docker-sandbox`
- watchdog and start-wrapper behavior already used for managed sidecar processes
- the ergonomics learned from `~/.zsh/functions.zsh`
- the operational lessons documented in the article about abuse prevention and containment

However, the project should avoid copying personal path assumptions directly. Existing scripts should be normalized into repository-local configuration and module boundaries.

## Open Implementation Direction

The next phase should convert this design into a concrete implementation plan that specifies:

- exact file layout
- startup and compose strategy
- profile config format
- default proxy choice
- MCP service skeleton shape
- verification script list

That plan should stay tightly scoped to the first working version described above.
