# Security Model

## Goal

The repository is designed to make the safest path the easiest path:

- sensitive capabilities should flow through MCP services
- routine outbound traffic should be constrained by repository-owned proxy rules
- runtime state should stay inside repository-owned directories

## Trust Boundaries

### Host

The host runs Docker and launches the stack through `bin/agent-sandbox`. It is trusted to hold source code, local credentials, and the repository-managed runtime directories.

### Sandbox Container

The sandbox is where the agent runs. It should be treated as less trusted than the host. Its writable footprint is intentionally concentrated in mounted runtime directories and the workspace mount.

### MCP Services

MCP sidecars are the controlled interface for sensitive actions. They are the right place to add auditing, credential scoping, request validation, rate limiting, and allow/deny logic.

### Proxy

The proxy is the controlled interface for general outbound network access. It is responsible for enforcing the allowlist and blocklist shipped in `config/proxy-rules/`.

## Current Enforcement Model

The current implementation enforces part of the intended model:

- proxy-enabled profiles inject `HTTP_PROXY` and `HTTPS_PROXY`
- proxy rules are copied into the Squid container on startup
- runtime data is mounted from repository-managed directories
- MCP profile definitions are validated before use

This starter kit does not yet claim complete isolation against every bypass technique. In particular, profile selection currently influences environment and operator workflow more than it re-wires the Compose topology.

## Threats This Design Targets

- Accidental direct access to sensitive APIs from the sandbox
- Unreviewed tool sprawl inside the agent runtime
- Runtime data leaking into ad hoc host paths
- Overly broad "just use curl" behavior when a narrower capability interface should exist

## Expected Operator Practices

- Run the sandbox with the narrowest profile that still supports the task
- Add new sensitive integrations as MCP services first
- Keep proxy allowlists short and explicit
- Treat verification scripts as environment-changing operations because they start and stop containers
