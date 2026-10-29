# ai-sandbox

A reusable, disposable Docker sandbox for running AI agents (mostly Claude Code with
`--dangerously-skip-permissions`) against a project, isolated from the host. A project consumes this
repo as a **git submodule** and launches the sandbox from IntelliJ (no extra plugins) with a Shell
Script run configuration pointing at `$PROJECT_DIR$/ai-sandbox/sandbox.sh`.

## Status

First version built and tested 2026-10-29 (nothing committed yet); no project migrated yet.
Origin: https://github.com/zodac/ai-sandbox. Repo map:

- `sandbox.sh` - the host launcher (all commands; `init` scaffolds a project).
- `image/base/` - the shared base image; `image/final/` - Claude Code + entrypoint/launch/setup.
- `templates/` - what `init` copies: `configuration/` and the IntelliJ `run/` configs.
- `examples/android-gradle` (from DiceFive) and `examples/java-maven` (from Diurnal) - complete
  project configurations, both built and verified.
- `scripts/update-versions.sh` - pin bumps for the base and project Dockerfiles.
- `VERSION` + `.github/workflows/publish.yml` - every push to `master` is tagged X.Y.Z and released, then
  VERSION is bumped (same mechanism as code-quality-config). Consuming projects pin a tag, never a branch.

The four `sandbox-*/` directories in the repo root are the per-project sandboxes this repo replaces -
reference material only (git-ignored), to be deleted once everything has been migrated:

- `sandbox-dicefive/` - the best/newest: bind-mounted `.claude-history`, host timezone, Claude version
  label fallback, Android SDK/NDK/emulator. Treat its scripts as the canonical behaviour.
- `sandbox-diurnal/` - JDK 26 + Maven, port `8071:8081`, npm + Playwright setup steps.
- `sandbox-home_theatre/` - like diurnal, plus `update_versions.sh` (the pin-bump script).
- `sandbox-sping_boot/` - the oldest copy.

## Layout in a consuming project

```
<project>/
├── ai-sandbox/                    ← this repo (submodule; never edited per project)
└── ai-sandbox-configuration/      ← committed in the project (override with SANDBOX_CONFIG_DIR)
    ├── sandbox.conf               ← runtime settings (sourced bash variables; env vars override)
    ├── Dockerfile                 ← optional: `FROM ${BASE_IMAGE}`, adds the project's toolchains
    ├── setup.d/*.sh               ← optional: per-open setup hooks, run as `dev`
    ├── entrypoint.d/*.sh          ← optional: start-up hooks, run as root
    ├── bin/                       ← optional: helper scripts on PATH
    └── .claude-history/           ← ~/.claude bind mount (self-ignoring)
```

## Design decisions (agreed)

- **Three-layer image**: `ai-sandbox-base:<content-hash>` (shared by all projects) → the project's
  Dockerfile (optional) → a thin final layer with Claude Code + the sandbox scripts. Claude Code is on
  top so its near-daily releases never invalidate a project's (possibly 10 GB) toolchain layers.
  Downloads belong in their own build stages, COPY'd in, so a base rebuild only re-copies them.
- **Base stays minimal**: only what every sandbox needs (Debian, nested Docker, Node for Claude, git,
  gh, jq, python3, ...). Toolchains (JDK, Maven, Gradle, Android, ImageMagick, fonttools, ...) and
  **Playwright** belong to each project's own Dockerfile - Playwright is NOT in the base.
- **Version pins**: every Dockerfile keeps pinned versions with `# BEGIN DEBIAN PACKAGES` /
  `# END DEBIAN PACKAGES` blocks, because the update-versions scripts (here and in most of the
  user's repos) depend on that shape. Configuration is Dockerfile-based for now; if we ever move to
  declarative package lists (apt/pip files), flag that the version-update tooling needs a new
  solution.
- **Independence**: every docker name (container, image, hostname, cache volumes) is derived from the
  project directory's basename **plus a short hash of its absolute path**, so separate checkouts and
  separate IntelliJ instances never share state. Relaunching the *same* project replaces its running
  sandbox (they would share `~/.claude`); `attach` opens a second shell into the running one.
- **Resume must keep working**: `run claude --dangerously-skip-permissions --continue|--resume`
  (verbatim, as existing run configs use), plus `continue` / `resume` shorthands.
- **IntelliJ run configs** are generated into the project's `.run/` (committed). They must contain no
  host file paths or personal information - only `$PROJECT_DIR$`-relative paths.
- Only the project directory (and the config dir) is mounted; never `$HOME` or the host Docker socket.
  `--privileged` is required for the nested daemon - it guards against accidents, not hostile code.

## Working rules

- Don't commit unless asked.
- Finished work goes on `master`, ready for review. A feature branch is fine for testing, but merge
  it back into `master` (and delete it) before handing the work over - never leave it on a branch.
- Keep the existing scripts' style: `set -euo pipefail`, heavily commented "why" explanations,
  `[sandbox]`/`[setup]` log prefixes, guarded/idempotent setup steps.
