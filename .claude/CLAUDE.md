# ai-sandbox

@../rules/CLAUDE.md

A reusable, disposable Docker sandbox for running AI agents (mostly Claude Code with
`--dangerously-skip-permissions`) against a project, isolated from the host. A project consumes this
repo as a **git submodule** and launches the sandbox from IntelliJ (no extra plugins) with a Shell
Script run configuration pointing at `$PROJECT_DIR$/ai-sandbox/sandbox.sh`.

## Status

Released as `1.0.0` (2026-10-29). **DiceFive is migrated** (its commit `3ac5e510`), and so is **Diurnal**
(2026-11-06); Home Theatre and Spring Boot are not yet - the user will ask to continue later (see
*Remaining migrations* below).
Origin: <https://github.com/zodac/ai-sandbox>. Repo map:

- `sandbox.sh` - the host launcher (all commands; `init` scaffolds a project; `update` moves its submodule
  to the newest tag and exec's that version's `init`, so a release's migrations belong in `init`, idempotent).
- `image/base/` - the shared base image; `image/final/` - Claude Code + entrypoint/launch/setup.
- `templates/` - what `init` copies: `configuration/` and the IntelliJ `run/` configs.
- `rules/CLAUDE.md` - the organisation rules every consuming project shares. `init` adds an import of it
  to the project's `CLAUDE.md` (`@../ai-sandbox/...` from `.claude/CLAUDE.md`, because an import path is
  relative to the file holding it, and an unresolved one is dropped silently). `init` also sets
  `"attribution": false` in the project's `.claude/settings.json` and registers the guards in
  `rules/hooks/` (today `guard-git-branch.sh`, rule 1) as `"$CLAUDE_PROJECT_DIR"/<submodule>/rules/hooks/...`
  PreToolUse hooks; `setup.sh` runs `rules/hooks/tests/` on every open and warns about an unregistered
  one. This repo imports its working-tree copy (above) and has the same settings.
- `ai-sandbox-configuration/`, `.run/` - this repo is **its own sandbox**, running its working tree
  (`self_hosted` in `sandbox.sh`: a config dir of its own and no superproject → `PROJECT_DIR` is the repo).
  Not a self-submodule: every tag would gitlink the previous one, nesting a copy per release under any
  consumer that clones `--recursive`. `init` refuses here; its outputs are committed by hand (the `.run/`
  files are the templates with `@SANDBOX_DIR@/` removed). A broken edit to `image/` or `sandbox.sh`
  breaks this sandbox too - fix it from the host.
- `examples/android-gradle` (from DiceFive) and `examples/java-maven` (from Diurnal) - complete
  project configurations, both built and verified.
- `code-quality-config/` - a submodule (pinned to a tag, like in DiceFive/Diurnal) holding the shared lint
  rules; `.github/scripts/lint_{workflows,shell_scripts,dockerfiles,markdown}.sh` (ported from DiceFive) run
  each linter from an image pinned in the script; Publish's `lint` job runs all four before it tags (so a
  docs-only push is never linted in CI). Run them before handing work back.
- `VERSION` + `.github/workflows/publish.yml` - every push to `master` is built, tagged X.Y.Z and released,
  then VERSION is bumped (same mechanism as code-quality-config). Consuming projects pin a tag, never a
  branch. `.github/scripts/update_dependency_versions.sh` bumps every pin here (the Dockerfiles,
  the GitHub Actions, the lint images and code-quality-config; `sandbox.sh update-versions` runs its
  `--dockerfiles` mode for a project);
  `.github/workflows/monthly_version_update.yml` runs it
  monthly (via the org's GitHub App token, so its push can touch workflows and triggers Publish): a dead Debian
  pin breaks a clean build.

The four `sandbox-*/` directories in the repo root are the per-project sandboxes this repo replaces -
reference material only (git-ignored), to be deleted once everything has been migrated:

- `sandbox-dicefive/` - the best/newest: bind-mounted `.claude-history`, host timezone, Claude version
  label fallback, Android SDK/NDK/emulator. Treat its scripts as the canonical behaviour.
- `sandbox-diurnal/` - JDK 26 + Maven, port `8071:8081`, npm + Playwright setup steps.
- `sandbox-home_theatre/` - like diurnal, plus `update_versions.sh` (the pin-bump script).
- `sandbox-sping_boot/` - the oldest copy.

## Layout in a consuming project

```text
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

- **Containers are `--rm`, deliberately** (the user asked; keep it). A kept container would be frozen at
  its creation: the old image after a rebuild, and the old mounts/ports/env from before a `sandbox.conf`
  edit. Restarting one saves almost nothing (the entrypoint and nested dockerd run again either way; a
  no-op relaunch is ~4.6s, ~3.1s of it the build check). Everything worth keeping is in volumes or
  `.claude-history`. If launch time matters, speed up the build check instead.
- **Run configs stay in the project's root `.run/`**, generated by `init` - not shipped inside the
  submodule. Committed files would hardcode the submodule's directory name. The templates are named
  `*.run.xml.template` on purpose: IntelliJ loads any `*.run.xml` in a consuming project, and the
  unsubstituted templates (`@SANDBOX_DIR@/sandbox.sh`) then shadowed the generated configs of the same
  name, failing with "Shell script not found".
- **Shell history** (interactive bash only) lives in `.claude-history/.sandbox-state/bash_history`,
  appended per command (`image/final/bashrc.sh`), because a closed IntelliJ tab kills `docker exec`
  without bash ever saving.
- **Git settings** are a sanitised copy of the host's global config (`export_git_config` in `sandbox.sh`,
  installed by `launch.sh` via `.sandbox-state`), not a mount of `~/.gitconfig`. Credentials stay out: the
  sandbox can commit but not push (no SSH client, per-session `gh auth login`).
- **History retention** is `SANDBOX_HISTORY_DAYS` in `sandbox.conf` (default 14) → Claude's
  `cleanupPeriodDays`, validated on the host so a typo fails loudly.

## Migrating a project (the DiceFive playbook)

Work in the project's working tree; the user reviews and commits (or asks for the commit - use the
project's own commit skill/conventions; DiceFive's default branch is `main`, not `master`).

1. `git submodule add https://github.com/zodac/ai-sandbox.git ai-sandbox`, check out the newest **tag**,
   then `ai-sandbox/sandbox.sh init`.
2. **Port** `sandbox/Dockerfile` into `ai-sandbox-configuration/Dockerfile` - a real port, not a copy (the
   user's first attempt was a verbatim copy, which fails: it COPYs entrypoint/launch/setup.sh and
   daemon.json that no longer exist there). Add `ARG BASE_IMAGE`; runtime `FROM ${BASE_IMAGE}`; a
   Playwright stage becomes `FROM ${BASE_IMAGE} AS playwright-deps` (drop its node COPY and bootstrap
   apt); delete everything the base/final layers own (node stage, apt-cache config, bootstrap packages,
   user creation, daemon.json, Docker repo+engine, Claude install + LABEL, script COPYs, WORKDIR,
   HEALTHCHECK, ENTRYPOINT); trim ENV (no DEBIAN_FRONTEND/CLAUDE_CONFIG_DIR/DISABLE_AUTOUPDATER/npm path;
   PATH ends `:${PATH}`) and the tooling apt block (drop what the base has). **Keep the project's
   comments** - its update script may refer to them (DiceFive's JDK 26 note, the `JDK 25  —` stage label).
   Lint with the project's own hadolint config (`code-quality-config/docker/.hadolint.yaml`).
3. Populate `sandbox.conf` from the old `sandbox.sh` (ports, cache volumes) and `setup.sh` (npm dirs);
   move project-specific entrypoint/setup logic into `entrypoint.d/` / `setup.d/`, helpers into `bin/`.
4. History: **stop the old sandbox first**, then `rsync -a --delete sandbox/.claude-history/
   ai-sandbox-configuration/.claude-history/`. Transcripts resume because the container path stays
   `/work`. Then `git rm -r sandbox` + `rm -rf sandbox` (the ignored history is unrecoverable - confirm).
5. Rewrite every `sandbox/` reference outside it (`grep -rIlP '(?<![-\w])sandbox/'`): functional ones
   first (CI workflows, scripts reading the Dockerfile), then docs/comments. Re-read prose for claims that
   are no longer true (e.g. "entrypoint forwards X because sudo strips the environment" - setpriv keeps
   it now). Re-check markdown table alignment after path changes (markdownlint).
6. The project's own update script: new paths; drop its Node section (the base owns Node); its Debian
   release follows the base (`ai-sandbox/image/base/Dockerfile`) and the apt updater must map
   `FROM ${BASE_IMAGE}` to that Debian release; move the `ai-sandbox` submodule to its newest X.Y.Z tag
   (DiceFive's generic `update_submodule_tag`) **before** the Debian sync. Test functions by sourcing the
   script with its entry point cut off, against a temp copy of the Dockerfile.
7. Old IntelliJ run configs live in `.idea/workspace.xml` and duplicate the new `.run/` names - remove
   them, but if the project is open IntelliJ rewrites workspace.xml from memory, so tell the user to check
   Run → Edit Configurations.
8. Verify: run the project's lint scripts; launch; check toolchains, hooks, `continue`/`resume` see the
   real sessions; the user tests the IntelliJ configs.

## Remaining migrations

Both are on `master` and still have a `sandbox/` directory. Start from `examples/java-maven`.

- **Home Theatre** - like Diurnal (no port); its `sandbox/update_versions.sh` is replaced by
  `ai-sandbox/sandbox.sh update-versions`. References in `.claude/CLAUDE.md`,
  `.claude/reference/{deployment-topology,no-personal-info}.md`, `.claude/hooks/tests/run-hook-tests.sh`.
  Its old sandbox kept `~/.claude` in a named volume (`home_theatre-sandbox-claude`), not a directory -
  copy it out of the volume (`docker run --rm -v <vol>:/from -v <dir>:/to ... cp -a /from/. /to/`).
- **Spring Boot template** (`spring-boot-template/`) - the oldest copy; port `8071:8081`. Its sandbox.sh
  names a `~/.claude` volume too, but none exists on this host (2026-10-29), so there is no history to
  carry over. References only in `.dockerignore`.

## Host clean-up still pending (offered, not done)

- Copy the old `dicefive-sandbox-gradle` (26 GB) and `-m2` volumes into `dicefive-b071d2-sandbox-*`, then
  delete the old `dicefive-sandbox-*` volumes (incl. `-claude`) and the `dicefive-sandbox` image (11.9 GB).
- Delete the test leftovers: `bare-project-*`, `android-project-*`, `maven-project-*` images and volumes.
- Once all projects are migrated: delete the `sandbox-*/` reference dirs here and their `.gitignore` line.

## Gotchas learned

- On this host `diff` is aliased to `git diff --word-diff`: use `command diff` for real file diffs. `env` is
  aliased to `env | sort` too: use `command env` to run something with extra variables.
- `COPY --chmod=0644 f /new/dir/f` applies the mode to the directory it creates too, making it
  untraversable - copy into an existing directory.
- `cmd || warn "... $(basename x) ... $?"` reports 0: the command substitution resets `$?`. Capture
  `status=$?` first.
- A submodule is a gitlink: `git status` shows it as `new file: ai-sandbox`, which is expected.
- The publish workflow tags the "Prepare next version" bump commit (as in code-quality-config).
- Cache volume names changed with the path-hashed naming, so a migrated project's first Gradle/Maven run
  re-downloads unless the old volumes are copied across.
- npm in the base's Node skips Claude Code's postinstall script ("not yet covered by allowScripts"); Claude
  works regardless (same as the pre-migration images) - watch it if a Claude release starts needing it.
- **A commit message needs a blank line after its subject.** `255a2c5` (the 1.2.0 feature commit) was
  written as `git commit -F -` with the body straight under the subject, so git folded the whole message
  into one subject line - and the release, being on `master` already, could not be fixed without
  rewriting a pushed commit and tag. Check `git log -1 --format=%s` before pushing.
- **`sandbox.sh update` only exists from 1.1.0.** In a project still on 1.0.x, `ai-sandbox/sandbox.sh
  update` is not a command but a LAUNCH (running `update` in the sandbox): it rebuilds the image and
  REPLACES the project's running sandbox, killing any session in it, before failing with
  `exec: update: not found`. Check the submodule's tag first; from 1.0.x, move it by hand (`git -C
  ai-sandbox checkout refs/tags/X.Y.Z`) and run the new `init`.
- **Sourcing a project's update script to test one function: cut it at its entry point**, found by name
  (`# ── Entry point`), never at a guessed call further down. Diurnal's update calls begin right after
  that marker, so a cut at a later call ran its Java/Maven/Node updates against the real working tree.
- An identical project Dockerfile reuses the host's build cache wholesale (DiceFive's port built in ~5s
  after the example was built), so test builds of real projects are cheap once one variant is cached.

## Working rules

- Don't commit unless asked.
- Work directly on `master` (organisation rule 1: never a feature branch); finished work stays there,
  ready for review.
- Keep the existing scripts' style: `set -euo pipefail`, heavily commented "why" explanations,
  `[sandbox]`/`[setup]` log prefixes, guarded/idempotent setup steps.
- **Never stop, replace or kill another project's sandbox.** The user may have a live Claude session
  in it, and a launch of the same checkout replaces it without asking (this happened to Tracker Profiles
  on 2026-11-14 - see the `update` gotcha above). So, in any project other than a scratch one you made:
    - Run only the commands that never launch or stop: `init`, `build`, `update-versions`, and `update` once
      `git -C <project>/ai-sandbox describe --tags` shows 1.1.0 or newer. Anything else - no command,
      `continue`, `resume`, `shell`, `run`, `attach`, `stop`, `prune`, or a command the submodule's
      version doesn't have (`sandbox.sh` launches with an unknown word as the command) - needs the user's
      explicit go-ahead for that project, after you've said what it will do.
    - Before any `sandbox.sh` call there, check `docker ps --format '{{.Names}}' | grep sandbox`; if the
      project's sandbox is running, say so before going further.
    - Never `docker stop`/`kill`/`rm` a `*-sandbox` container, or delete its volumes, unless you created it.
    - Test launches belong in a scratch project in the scratchpad (`PROJECT_DIR=<scratch>`), whose
      container and volumes you clean up afterwards.
