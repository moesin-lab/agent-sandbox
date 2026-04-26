# Profiles

## Overview

Profiles are plain env files in `config/profiles/`. Each profile describes the intended operating mode for the sandbox by setting:

- whether proxy variables are injected
- whether MCP services are expected
- the nominal sandbox network mode label

Select a profile with:

```bash
bin/agent-sandbox up <profile>
```

If no profile is passed, `bin/agent-sandbox` falls back to `DEFAULT_PROFILE` from `config/defaults.env`.

## `mcp-only`

File: `config/profiles/mcp-only.env`

Behavior:

- `ENABLE_PROXY=0`
- `ENABLE_MCP_GITHUB=1`
- `ENABLE_MCP_WEB=1`
- `SANDBOX_NETWORK_MODE=isolated`

Use this mode when you want the sandbox to avoid general outbound network access and rely on MCP services for external capabilities.

## `proxy-gated`

File: `config/profiles/proxy-gated.env`

Behavior:

- `ENABLE_PROXY=1`
- `ENABLE_MCP_GITHUB=0`
- `ENABLE_MCP_WEB=0`
- `SANDBOX_NETWORK_MODE=proxy`

Use this mode when ordinary package registries or docs should be reachable through the proxy allowlist, while sensitive destinations remain blocked by proxy rules.

## `hybrid`

File: `config/profiles/hybrid.env`

Behavior:

- `ENABLE_PROXY=1`
- `ENABLE_MCP_GITHUB=1`
- `ENABLE_MCP_WEB=1`
- `SANDBOX_NETWORK_MODE=proxy`

Use this mode when day-to-day development needs both proxy-gated outbound access and MCP sidecars for higher-risk actions.

## Practical Differences

| Profile | Proxy vars in sandbox | MCP sidecars intended | Typical goal |
| --- | --- | --- | --- |
| `mcp-only` | No | Yes | Force external actions through MCP |
| `proxy-gated` | Yes | No | Allow listed egress only |
| `hybrid` | Yes | Yes | Combine proxy convenience with MCP control |

The profile files express intent and runtime environment. They do not yet re-shape the Compose graph dynamically.
