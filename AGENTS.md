# AGENTS.md

Codex instructions for this repository. Full project guidance lives in `CLAUDE.md`; read it before changing code.

## Critical rules

- After source-code changes (`*.swift`, project config, app resources, app scripts), install the DEV app:

```bash
./scripts/dev-install.sh
```

- Docs-only changes do not need a dev install.
- Releases always go through a PR with exactly one release label: `release:patch`, `release:minor`, `release:major`, or `release:skip`.
- Never push directly to `main`, never create `v*` tags by hand, and never hand-edit `MARKETING_VERSION` or `docs/appcast.xml`.
- Use Ponytail rules: smallest behavior-preserving change, delete stale docs before adding new ones, document shipped behavior only unless a roadmap is explicitly requested.
