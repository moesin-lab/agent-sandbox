# Verification

## Scope

This repository has two layers of verification:

- lightweight file and shell checks that are safe to run during development
- runtime checks that bring the Docker stack up and validate each profile's expected behavior

If you are working in a shared or already-running environment, do not run the profile scripts blindly. They start and stop the local stack.

## Safe Local Checks

These checks do not start containers:

```bash
test -f docs/verification.md
test -x scripts/verify-mcp-only.sh
bash -n scripts/verify-mcp-only.sh
bash -n scripts/verify-proxy-gated.sh
bash -n scripts/verify-hybrid.sh
```

## Profile Verification

### `mcp-only`

1. Run `bin/agent-sandbox up mcp-only`.
2. From the sandbox, try `curl -I https://api.github.com`.
3. Expect the request to fail.

Script:

- `scripts/verify-mcp-only.sh`

### `proxy-gated`

1. Run `bin/agent-sandbox up proxy-gated`.
2. From the sandbox, request `https://registry.npmjs.org` and expect success.
3. From the sandbox, request `https://api.github.com` and expect failure.

Script:

- `scripts/verify-proxy-gated.sh`

### `hybrid`

1. Run `bin/agent-sandbox up hybrid`.
2. From the sandbox, request `https://registry.npmjs.org` and expect success.
3. From the `mcp-web` container, request `http://localhost:3102/health` and expect success.

Script:

- `scripts/verify-hybrid.sh`

## Validation Scripts

- `scripts/verify-mcp-only.sh`
- `scripts/verify-proxy-gated.sh`
- `scripts/verify-hybrid.sh`
