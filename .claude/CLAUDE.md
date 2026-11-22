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

- `sandbox.sh` - the host launcher (all commands). `init` sets a project up, ONCE. `update` is the only
  way to a new release: it moves the submodule to the newest tag and exec's that version's
  `init --update` (`add_release_content`), which adds the release's new settings and never overwrites the
  project's files - except the run configs, which it syncs to the release (adds, overwrites, removes any
  `.run/Claude Sandbox*.run.xml` the release no longer has; from 1.3.0) and removes every other
  `Claude Sandbox` config IntelliJ could load instead of them (see *Gotchas*).
  So a release's migrations belong in `add_release_content`, idempotent; one that must change
  an existing file is a step of its own there. `init` on a set-up project (`sandbox.conf` exists) fails
  and suggests `update`; the `update` of 1.2.2 and older exec's the new release's plain `init`, so that
  upgrade ends in the error, with the submodule moved, and a second `update` adds the content.
- `image/base/` - the shared base image; `image/final/` - Claude Code + entrypoint/launch/setup.
- `templates/` - what `init` copies (`configuration/`, once) and `update` adds when new (the IntelliJ `run/` configs).
- `rules/CLAUDE.md` - the organisation rules every consuming project shares. `init` adds an import of it
  to the project's `CLAUDE.md` (`@../ai-sandbox/...` from `.claude/CLAUDE.md`, because an import path is
  relative to the file holding it, and an unresolved one is dropped silently). `init` also sets
  `"attribution": false` in the project's `.claude/settings.json` and registers the guards in
  `rules/hooks/` (today `guard-git-branch.sh`, rule 1) as `"$CLAUDE_PROJECT_DIR"/<submodule>/rules/hooks/...`
  PreToolUse hooks; `setup.sh` runs `rules/hooks/tests/` on every open and warns about an unregistered
  one. This repo imports its working-tree copy (above) and has the same settings.
- `ai-sandbox-configuration/`, `.idea/runConfigurations/` - this repo is **its own sandbox**, running its
  working tree (`self_hosted` in `sandbox.sh`: a config dir of its own and no superproject → `PROJECT_DIR`
  is the repo). Not a self-submodule: every tag would gitlink the previous one, nesting a copy per release
  under any consumer that clones `--recursive`. `init` refuses here; its outputs are committed by hand (the
  run configurations are the templates with `@SANDBOX_DIR@/` removed, in `.idea/runConfigurations/` -
  never `.run/`, see *Run configs* below). A broken edit to `image/` or `sandbox.sh` breaks this sandbox
  too - fix it from the host.
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
- **Not `--privileged`** (from 1.3.0): the nested daemon gets `CAP_SYS_ADMIN` + `CAP_NET_ADMIN`, seccomp and
  AppArmor off and `--cgroupns private`; `entrypoint.sh` (`open_up_for_dockerd`) makes the cgroup tree
  writable (moving everything to an `init` child so the controllers can be delegated) and only
  `/proc/sys/net` - never all of `/proc/sys` (`systempaths=unconfined` would expose
  `kernel.core_pattern`, a host escape). Host devices come in only through `SANDBOX_DEVICES` (`update`
  adds `/dev/kvm` to a configuration that uses it: `ensure_devices_setting`); `SANDBOX_PRIVILEGED=true`
  is the escape hatch. Also on by default: the local-network block (an nft table in `entrypoint.sh`,
  `SANDBOX_BLOCK_LOCAL_NETWORK` / `SANDBOX_LOCAL_NETWORK_ALLOW`; DNS to resolv.conf's servers stays open,
  as this host's is the LAN router), loopback-only ports, `--pids-limit 32768`, the base's FROMs pinned
  by digest (the update script refreshes a digest only where one is pinned) and Docker's APT key checked
  against its fingerprint. The block FAILS CLOSED: the entrypoint refuses to start if nft fails or its
  self-test (a probe of the gateway and 169.254.169.254, checked by the rules' `rejected` counter) shows
  nothing refused. **`dev` has no sudo** (`SANDBOX_SUDO=true` restores it; the entrypoint writes the rule
  at start): the entrypoint opens `SANDBOX_DEVICES` to `dev` through a `sandbox-devices` group, and
  `prune` runs as root through `SANDBOX_ROOT_COMMAND`. **The files the host runs are read-only** in the
  sandbox (`SANDBOX_PROTECTED_PATHS`: the submodule, sandbox.conf, .git/hooks, .claude
  settings/hooks, .idea, .run, .vscode, .envrc), and creating a missing one is reported at teardown
  (`report_created_host_files`); this repo's own sandbox.conf lists a smaller set, as work here edits
  sandbox.sh, settings.json and .idea/runConfigurations. **.git/config stays writable** (the user's call:
  read-only broke `git submodule init`, `git branch -u`, `git config --local`); the keys in it (and each
  submodule's) that make git run a program are recorded at launch and any added/changed one is reported at
  teardown (`report_risky_git_config`, `RISKY_GIT_KEYS`). Claude is told all this by a managed-policy
  `/etc/claude-code/CLAUDE.md` the entrypoint writes at start (`write_claude_note`), and a `sudo` in a
  session is a script in /usr/local/bin saying what to do instead. All of it guards against accidents, not
  hostile code: the nested daemon's `docker` group is still root, and SYS_ADMIN without a user
  namespace has ways out. A real boundary needs sysbox or a rootless
  nested daemon without sudo. **Remote Control stays on by default: the user relies on it.**

- **Containers are `--rm`, deliberately** (the user asked; keep it). A kept container would be frozen at
  its creation: the old image after a rebuild, and the old mounts/ports/env from before a `sandbox.conf`
  edit. Restarting one saves almost nothing (the entrypoint and nested dockerd run again either way; a
  no-op relaunch is ~4s). Everything worth keeping is in volumes or `.claude-history`. A launch skips
  `docker build` when none of its inputs changed (`build_key`, a label on the final image; from 1.3.0) -
  `sandbox.sh build` always builds. A launch from a terminal asks before replacing a running sandbox
  (`confirm_replace`; `SANDBOX_REPLACE=true` or no terminal skips it), and an unknown command word is
  refused instead of launched (from 1.3.0).
- **Run configs stay in the project's root `.run/`**, generated by `init` and synced by `update` (the
  "Claude Sandbox" name prefix is ai-sandbox's: the project's own edits to those are overwritten) - not
  shipped inside the submodule. The interactive ones, and Paste Image (from 1.3.0, beside the running
  sandbox), run in the Terminal tool window (`EXECUTE_IN_TERMINAL`); Stop runs in the Run window.
  Committed files would hardcode the submodule's directory name. The templates are named
  `*.run.xml.template` on purpose: IntelliJ loads any `*.run.xml` in a consuming project, and the
  unsubstituted templates (`@SANDBOX_DIR@/sandbox.sh`) then shadowed the generated configs of the same
  name, failing with "Shell script not found". The same goes for this repo's own configurations: from
  1.1.0 to 1.2.1 they were in `.run/`, and every consumer's IntelliJ loaded them from the submodule, where
  `$PROJECT_DIR$/sandbox.sh` doesn't exist ("Shell script not found" again). They are in
  `.idea/runConfigurations/` now (the one `.idea/` path `.gitignore` lets through), which IntelliJ reads
  only from the project's own root; Publish's lint job fails on any committed `*.run.xml`.
- **Shell history** (interactive bash only) lives in `.claude-history/.sandbox-state/bash_history`,
  appended per command (`image/final/bashrc.sh`), because a closed IntelliJ tab kills `docker exec`
  without bash ever saving.
- **Git settings** are a sanitised copy of the host's global config (`export_git_config` in `sandbox.sh`,
  installed by `launch.sh` via `.sandbox-state`), not a mount of `~/.gitconfig`. Credentials stay out: the
  sandbox can commit but not push (no SSH client, per-session `gh auth login`).
- **The project is also mounted at its host path, and Claude runs there** (`mirrored_path`,
  `SANDBOX_WORKDIR`; not on Windows, where it stays `/work`), so host paths (drag and drop, Copy Path)
  work inside, and the file paths Claude prints - links, with `TERMINAL_EMULATOR` passed in - open on
  the host (`file:///work/...` opened nothing). `/work` stays mounted. Claude keys three things by its
  cwd, resolved through symlinks: `projects/<key>`, `.claude.json`'s `projects` map and
  `history.jsonl`'s `project`. `launch.sh`'s `link_project_state` keeps that non-destructive:
  `projects/<host key>` is a symlink to `projects/-work` (still the one real dir, so moved checkouts and
  older tags find everything), the `/work` entry in `.claude.json` is copied once (backup:
  `.sandbox-state/claude.json.before-host-path`), and `history.jsonl` is left alone (old up-arrow
  prompts are not offered). Whether Claude follows the symlinked project dir is checked only by the
  user, in a logged-in sandbox.
- **No clipboard in the sandbox, by design**: mounting the X11 socket gives keylogging/screen capture,
  and Wayland (data-control) lets it read every copy without focus. `sandbox.sh paste-image` (and the
  `Paste Image` run config) runs on the HOST, on demand: it saves the clipboard's PNG into
  `.sandbox-state/tmp/pastes/` and puts its in-sandbox path on the clipboard (Ctrl+V still works). The
  running session gets the image by itself through a Claude Code **channel**: `image/final/paste-channel.mjs`,
  an MCP server with the experimental `claude/channel` capability, polls `pastes/` and pushes each new image
  as a prompt (one short turn per paste: it asks Claude for a one-line acknowledgement, not to read the
  image yet; one session claims each image via `pastes/.claimed/`). It is an **approved channel plugin**,
  `sandbox-paste@ai-sandbox`, from a plugin marketplace in the image (`image/final/claude-plugins/`), approved
  by `/etc/claude-code/managed-settings.json` (`channelsEnabled`, `allowedChannelPlugins`); `launch.sh`
  installs it once into the config dir and adds `--channels plugin:sandbox-paste@ai-sandbox` to an
  interactive `claude` (not to a subcommand, `-p`, or a `claude` typed in a shell).
  `SANDBOX_PASTE_CHANNEL=false` turns it off. Why a plugin: a plain server needs
  `--dangerously-load-development-channels`, whose confirmation dialog shows at every start, with no setting
  to skip it. Managed settings are read ONLY from `/etc/claude-code` (this build compiles out the path
  override), so the approval cannot be tested from inside a sandbox, where `dev` has no root.
  It answers with protocol `2025-06-18`: Claude drops channel messages on the newest ("modern") revision.
  Rejected: a per-message UserPromptSubmit hook (runs on every message for a rare feature) and tmux
  send-keys (tmux takes over scrollback and the mouse in IntelliJ's terminal).
  Tested on X11 only; the Wayland, macOS and Windows branches are untested.
- **The final image sets `LANG=C.UTF-8`** (unless the project image set one): Debian sets none, and the
  C locale mangled non-ASCII text in bash, `git` and vim.
- **Claude's temp dir** (`CLAUDE_CODE_TMPDIR`: scratchpads, so its screenshots) is
  `.claude-history/.sandbox-state/tmp`, mounted at its own host path where it can be
  (`mirrored_path` in `sandbox.sh`), and the host's `TERMINAL_EMULATOR`/`TERM_PROGRAM`/`COLORTERM`
  are passed in. Claude prints a file it shows as `[image] <path>`, a link only when it knows the
  terminal (`TERMINAL_EMULATOR=JetBrains-JediTerm` for IntelliJ) - and only an openable one when the
  path exists on the host. Inline pictures are not possible in IntelliJ: Claude Code draws them only in
  kitty/ghostty (kitty graphics) and iTerm2 3.5+. The IntelliJ plugin's IDE integration (selection
  context, IDE diffs) was deliberately left out: it needs the host's `~/.claude/ide` tokens and a
  route to the plugin's host-loopback websocket, i.e. a channel from the sandbox into the host IDE.
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
   ai-sandbox-configuration/.claude-history/`. Transcripts resume because the old sandboxes ran in
   `/work` too, and `launch.sh` links the host path's key to `projects/-work`. Then `git rm -r sandbox` +
   `rm -rf sandbox` (the ignored history is unrecoverable - confirm).
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
- **A scratch project inside a project breaks its run configs.** Claude's scratchpad is in the project tree
  (`.claude-history/.sandbox-state/tmp`), and IntelliJ loads a `*.run.xml` from anywhere in it: a scratch
  `init` test's `.run/` shadowed this repo's configs after an IDE restart ("Shell script not found",
  2026-11-22). `sandbox.sh` now deletes `*.run.xml` there at shutdown (`remove_scratch_run_configs`, from the
  teardown trap and `stop`). Still, delete a scratch project when its test is done. Diurnal and Home Theatre
  had the other kind: a hand-made `Claude Sandbox` config in `.idea/workspace.xml` still pointing at the
  deleted `sandbox/sandbox.sh`. From 1.3.0, `init`/`update` remove both (`remove_shadowing_run_configs`): any
  `Claude Sandbox*.run.xml` outside the root `.run/`, `.idea/runConfigurations/Claude_Sandbox*.xml`, and the
  `Claude Sandbox*` Shell Script configurations in `workspace.xml` (backup: `workspace.xml.before-ai-sandbox`).
- **Never test `--network host` (`SANDBOX_RUN_ARGS`).** With the host's network namespace and NET_ADMIN, the
  nested dockerd re-addressed the HOST's docker0 (172.16.0.1/20 from `/etc/docker/daemon.json`'s pools →
  172.17.0.1/16) and added a NAT rule to match, cutting every default-bridge container - Tracker
  Profiles' live sandbox included - off the network (2026-11-22; repaired by hand from a host-network
  container: address back, stray masquerade rule deleted). `sandbox.sh` now refuses `--network host`.
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
      version doesn't have (before 1.3.0, `sandbox.sh` launches with an unknown word as the command) - needs the user's
      explicit go-ahead for that project, after you've said what it will do.
    - Before any `sandbox.sh` call there, check `docker ps --format '{{.Names}}' | grep sandbox`; if the
      project's sandbox is running, say so before going further.
    - Never `docker stop`/`kill`/`rm` a `*-sandbox` container, or delete its volumes, unless you created it.
    - Test launches belong in a scratch project in the scratchpad (`PROJECT_DIR=<scratch>`), whose
      container and volumes you clean up afterwards.
