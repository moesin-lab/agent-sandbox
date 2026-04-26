# Extending

## Add an MCP Service

1. Create a new service entry under `mcp/services/<name>/`.
2. Expose a process entrypoint, following the current `server.js` pattern.
3. Add the service name to the relevant MCP profile JSON in `config/mcp-profiles/`.
4. If the new service needs its own Compose service, add it to `orchestration/compose.yaml`.
5. Document its purpose and trust boundary in `docs/security-model.md` or a service-specific document.

Keep MCP services narrow. A small, reviewable interface is better than exposing a general shell wrapper under a new name.

## Add a New Profile

1. Create `config/profiles/<profile>.env`.
2. Set the profile toggles used by `orchestration/lib/profile.sh`.
3. Decide whether the profile should inject proxy variables.
4. Decide which MCP services are intended to be available.
5. Document the mode in `docs/profiles.md`.
6. Add a verification script if the new mode has behavior worth checking repeatedly.

Profiles are currently configuration overlays. If a new mode requires stronger service isolation, update the Compose and launcher logic as part of the same change instead of relying on docs alone.

## Change Proxy Rules

Edit:

- `config/proxy-rules/allowlist.txt`
- `config/proxy-rules/blocklist.txt`

Then rerun the relevant verification script to confirm:

- allowed endpoints still succeed
- blocked endpoints still fail

Prefer exact domains over broad wildcard thinking. The smaller the allowlist, the easier it is to reason about accidental exposure.

## Extend Verification

The current scripts in `scripts/` are the executable baseline for profile checks. When behavior changes:

- update the relevant script
- update `docs/verification.md`
- keep the script safe to run from the repository root
- make cleanup explicit so operators do not leave stray containers behind
