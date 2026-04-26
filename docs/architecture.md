# Architecture

## Overview

This repository is a starter kit for running an agent inside a Docker-managed sandbox with two controlled escape hatches:

- MCP services for sensitive or high-value capabilities
- An HTTP proxy for allowlisted general network access

The top-level entrypoint is `bin/agent-sandbox`. It loads defaults from `config/defaults.env`, overlays one profile from `config/profiles/*.env`, exports any proxy variables required by that profile, and then delegates lifecycle actions to Docker Compose in `orchestration/compose.yaml`.

## Components

### `sandbox/`

The `sandbox` image is the interactive runtime. It mounts:

- `runtime/workspaces` at `/workspace`
- `runtime/logs` at `/runtime/logs`
- `runtime/state` at `/runtime/state`
- `runtime/home` at `/home/node`

Its entrypoint prepares runtime directories, starts the watchdog, invokes the MCP startup helper, and then launches the container command.

### `mcp/`

The `mcp` module contains small service processes that expose controlled capabilities. The current starter kit ships:

- `mcp-github`
- `mcp-web`

`mcp/lib/profile-loader.js` validates the JSON profile definition used to decide which services a given MCP profile exposes.

### `proxy/`

The proxy service runs Squid and copies the configured allowlist and blocklist into the container at startup. Profiles that enable proxy access inject:

- `HTTP_PROXY=http://proxy:3128`
- `HTTPS_PROXY=http://proxy:3128`

That makes ordinary CLI tools in the sandbox follow the repository-managed egress path instead of using unrestricted direct network access.

### `orchestration/`

`orchestration/lib/common.sh` provides shared helpers for locating the project root and loading env files. `orchestration/lib/profile.sh` loads the selected profile and exports the proxy environment expected by Compose and the sandbox container.

`orchestration/compose.yaml` declares the sandbox, proxy, and MCP services as one stack.

## Runtime Flow

1. `bin/agent-sandbox up <profile>` loads default config and the chosen profile.
2. The profile toggles proxy environment variables and records which services are expected for that mode.
3. `docker compose` builds and starts the stack.
4. The sandbox uses repository-managed mounts for workspace, logs, state, and home data.
5. Network access from the sandbox either fails directly, routes through Squid, or combines proxy access with MCP sidecars, depending on the selected profile.

## Current Scope

This implementation is intentionally a starter kit. The compose file statically defines all services, and the profile env files primarily control network environment and operational intent rather than dynamically removing services from the Compose graph. The docs and verification scripts should therefore be read as guidance for the current scaffold, not as a claim of fully policy-driven orchestration.
