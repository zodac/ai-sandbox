# ai-sandbox

A disposable Docker container for running **Claude Code with `--dangerously-skip-permissions`** (or
any other agent) against a project, isolated from the host machine. A project includes this repo as a
**git submodule**, describes what it needs in a directory of its own beside it, and launches it from
IntelliJ with a plain Shell Script run configuration.

```text
<project>/
├── ai-sandbox/                    ← this repo, as a git submodule (never edited per project)
├── ai-sandbox-configuration/      ← the project's sandbox settings (committed)
│   ├── sandbox.conf               ← runtime settings: ports, cache volumes, env, ...
│   ├── Dockerfile                 ← optional: FROM ${BASE_IMAGE} + the project's toolchains
│   ├── setup.d/*.sh               ← optional: per-open setup steps, run as `dev`
│   ├── entrypoint.d/*.sh          ← optional: start-up hooks, run as root
│   ├── bin/                       ← optional: helper scripts, on the sandbox's PATH
│   ├── .dockerignore              ← keeps .claude-history out of the image build
│   └── .claude-history/           ← Claude's ~/.claude (auth, transcripts, memory) - ignores itself
├── .claude/settings.json          ← gets "attribution": false + the org's hook guards from init (committed)
├── CLAUDE.md or .claude/CLAUDE.md ← the project's rules; init adds the import of the organisation rules
└── .run/*.run.xml                 ← the IntelliJ run configurations (committed)
```

## Quick start

```bash
cd <project>
git submodule add https://github.com/zodac/ai-sandbox.git ai-sandbox
ai-sandbox/sandbox.sh init      # once: creates ai-sandbox-configuration/ (with empty bin/, entrypoint.d/, setup.d/) and .run/ - never overwrites
```

`init` is a one-time step for a project that is starting to use ai-sandbox; after that, `update` keeps
it current (see [Upgrading a project](#upgrading-a-project)). It also imports the
[organisation rules](#organisation-rules-claudemd) into the project's `CLAUDE.md` and sets
`"attribution": false` and the organisation's hook guards in `.claude/settings.json`.

Then edit `ai-sandbox-configuration/sandbox.conf` (and its `Dockerfile` if the project needs a JDK,
Maven, an Android SDK, ...). [`examples/`](examples) has complete configurations to start from:

| Example                                      | Taken from | Adds                                                                                     |
| -------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------- |
| [`android-gradle`](examples/android-gradle)  | DiceFive   | JDK 25, Android SDK/NDK/emulator (`emulator.sh`), ImageMagick 7, ffmpeg, Playwright libs |
| [`java-maven`](examples/java-maven)          | Diurnal    | JDK 26, Maven, Playwright libs + browser, ImageMagick/librsvg/optipng, port 8071         |

In IntelliJ, the run configurations appear on their own (`.run/` is loaded without any plugin):

| Run configuration                | Does                                                                     |
| -------------------------------- | ------------------------------------------------------------------------ |
| `Claude Sandbox`                 | a fresh interactive Claude session                                       |
| `Claude Sandbox (Continue Last)` | `claude --continue`: the most recent session                             |
| `Claude Sandbox (Resume Any)`    | `claude --resume`: pick a previous session from a list                   |
| `Claude Sandbox (Shell)`         | a bash shell instead of Claude                                           |
| `Claude Sandbox (Attach Shell)`  | a second shell in the sandbox that is already running                    |
| `Claude Sandbox (Stop)`          | stop and remove the running sandbox (the closest thing to a Stop button) |
| `Claude Sandbox (Paste Image)`   | hand the clipboard's image to Claude (see *Pasting an image* below)      |

They reference the launcher only as `$PROJECT_DIR$/ai-sandbox/sandbox.sh`, so they hold no host path
and are safe to commit. All but `Stop` and `Paste Image` have **Execute in the terminal** ticked:
Claude's TUI needs a real PTY, and without one `sandbox.sh` falls back to non-interactive mode.

**Pasting an image.** Ctrl+V of a screenshot doesn't work in the sandbox: Claude reads the clipboard
itself, and the sandbox is deliberately given no access to the host's display (that would let it log
keystrokes or read every password you copy). Instead, copy the screenshot, run
`Claude Sandbox (Paste Image)` (`sandbox.sh paste-image`), then press Ctrl+V in Claude. It saves the
clipboard's image into Claude's temporary directory, which the sandbox can see, and replaces the
clipboard with that file's path, which Claude attaches as the image. It runs on the host (wl-paste or
xclip on Linux, osascript on macOS, PowerShell on Windows) and never touches the sandbox. For a
keyboard shortcut, add it as an IntelliJ External Tool (*Settings → Tools → External Tools*: program
`$ProjectFileDir$/ai-sandbox/sandbox.sh`, arguments `paste-image`, working directory
`$ProjectFileDir$`) and bind it under *Keymap → External Tools*.

## Organisation rules (CLAUDE.md)

[`rules/CLAUDE.md`](rules/CLAUDE.md) holds the rules every ai-sandbox project shares. A project doesn't
copy them: its own `CLAUDE.md` imports the file, so moving the submodule to a newer tag updates the rules
too. The project's own rules stay in its `CLAUDE.md`, under the import. `init` adds the import line (and
`update` adds it to a project that lacks it):

| Project file                            | Import line                       |
| --------------------------------------- | --------------------------------- |
| `CLAUDE.md` (used if it exists)         | `@ai-sandbox/rules/CLAUDE.md`     |
| `.claude/CLAUDE.md` (created if needed) | `@../ai-sandbox/rules/CLAUDE.md`  |

An import path is relative to the file that contains it, hence the `../`. Claude ignores an import it
can't resolve without any warning, so check with `/memory` that `rules/CLAUDE.md` is listed. The rules
also apply when Claude runs on the host, not just in the sandbox.

`init` also sets `"attribution": false` in the project's `.claude/settings.json` (merged with `jq` when
the host has it), which drops Claude's commit trailers and PR footer. Releases of Claude Code older
than the boolean form reject it; they accept `{"commit": "", "pr": ""}` instead.

It also registers the organisation's PreToolUse guards from [`rules/hooks/`](rules/hooks), which enforce
the rules rather than state them - today [`guard-git-branch.sh`](rules/hooks/guard-git-branch.sh), which
blocks a command that creates a git branch (rule 1). The command is
`"$CLAUDE_PROJECT_DIR"/ai-sandbox/rules/hooks/guard-git-branch.sh`, so it applies on the host too, and a
fix reaches the project with its next tag. Each sandbox open runs their tests and warns if one is not
registered. The hooks need `jq` wherever Claude runs.

## Commands

```bash
ai-sandbox/sandbox.sh                  # interactive Claude session (--dangerously-skip-permissions)
ai-sandbox/sandbox.sh continue         # ... continuing the last session
ai-sandbox/sandbox.sh resume           # ... choosing a previous session
ai-sandbox/sandbox.sh shell            # a bash shell instead
ai-sandbox/sandbox.sh run <cmd...>     # an arbitrary command (e.g. `run mvn -v`)
ai-sandbox/sandbox.sh attach [cmd...]  # another shell (or command) in the RUNNING sandbox
ai-sandbox/sandbox.sh build            # (re)build the image; a launch does this anyway
ai-sandbox/sandbox.sh stop             # stop & remove a running sandbox
ai-sandbox/sandbox.sh prune            # reclaim disk in the nested docker (see Persistence)
ai-sandbox/sandbox.sh paste-image      # the clipboard's image, for Claude (see Pasting an image)
ai-sandbox/sandbox.sh init             # once, for a new project: scaffold ai-sandbox-configuration/ and .run/
ai-sandbox/sandbox.sh update [X.Y.Z]   # upgrade: submodule -> newest (or given) tag, plus what it adds
ai-sandbox/sandbox.sh update-versions  # bump the version pins in the base + project Dockerfiles
ai-sandbox/sandbox.sh update-versions --project-only  # ... the project's alone, leaving the submodule clean
ai-sandbox/sandbox.sh update-versions --project-only --packages-only  # ... its Debian packages alone
```

`continue` and `resume` are shorthands for `run claude --dangerously-skip-permissions --continue` /
`--resume`; the long forms still work. The transcripts they resume from live in
`ai-sandbox-configuration/.claude-history/`, which survives every restart. Claude finds them by the
directory it runs in: the project's host path (see *Host paths* under Persistence), linked at each
launch to the sessions of earlier launches, which ran in `/work`.

## Why this is safe

- **Only the project directory is mounted** (→ `/work` and its own host path, plus its configuration
  again at `/opt/ai-sandbox/config`). No `$HOME`, no SSH keys, no other projects are visible to the agent. The
  one thing copied in from the host's home is a sanitised git config (see *Notes*).
- **The host Docker socket is NOT mounted.** The sandbox runs its *own* nested Docker daemon, so any
  container a session spins up lives and dies *inside* the sandbox.
- **Runs as a non-root user** (`dev`, matching your host UID/GID) so files written under `/work` stay
  owned by you. (Claude also refuses `--dangerously-skip-permissions` as root.)
- **What `--privileged` actually costs — read this before trusting the list above.** The nested daemon
  needs it, and it is not free: the container holds `CAP_SYS_ADMIN`, `CAP_SYS_MODULE` and `CAP_MKNOD`,
  and the host's raw block devices are visible inside it. Root in here can therefore `mount` the host
  disk and read/write **the entire host filesystem** regardless of what is or is not bind-mounted; and
  `dev` has passwordless `sudo`. **So: the mount list is a guard against ACCIDENTS - a careless
  `rm -rf`, a runaway test, an agent with permissions skipped - and a good one. It is NOT a security
  boundary against deliberately hostile code** (a malicious dependency or build script). Closing that
  gap means dropping `--privileged` for a runtime built for it, such as
  [`sysbox-runc`](https://github.com/nestybox/sysbox).

## Independence: one sandbox per checkout

Every docker name — container, image, hostname, cache volumes — is derived from the project
directory's name **plus a short hash of its full path** (e.g. `dicefive-1a2b3c-sandbox`), and Claude's
state is a directory inside the checkout. So different projects, and different checkouts of the same
project, never share anything: run as many as you like, each in its own IntelliJ window. The one
thing two sandboxes can still collide on is a published host port, which fails loudly.

**Relaunching the same checkout replaces its running sandbox.** Two copies would share `~/.claude`,
whose login state Claude rewrites in place, and used to take *both* down. The new launch stops the old
container once its own image build is done (so the outgoing session stays usable throughout) and waits
for the name to free up. Each launcher tears down the container it started **by id**, never by name,
so a departing session can never stop the one that replaced it. For a second terminal in the same
sandbox, use `attach`.

## The image: three layers

| Layer       | Image                     | From                                   | Holds                                                                       |
| ----------- | ------------------------- | -------------------------------------- | --------------------------------------------------------------------------- |
| 1. base     | `ai-sandbox-base:<hash>`  | [`image/base/`](image/base)            | Debian 13, nested Docker, Node, git, gh, jq, python3, sudo, the `dev` user  |
| 2. project  | `<name>-sandbox-project`  | `ai-sandbox-configuration/Dockerfile`  | the project's toolchains (optional)                                         |
| 3. final    | `<name>-sandbox`          | [`image/final/`](image/final)          | Claude Code (pinned to the latest release) + the sandbox scripts            |

- **The base is shared.** Its tag is a hash of `image/base/` and your UID/GID, so every project on
  the same submodule commit uses one image, and it is never rebuilt once it exists. It stays minimal
  on purpose: anything only some projects use (a JDK, Maven, Playwright, ImageMagick, fonttools, ...)
  belongs in that project's Dockerfile.
- **Claude Code is on top**, so its near-daily releases rebuild one thin layer, never a project's
  (possibly 10 GB) toolchains. `sandbox.sh` reads the latest version from the npm registry and passes
  it as a build arg: the container is `--rm`, so a runtime self-update would land in a layer teardown
  deletes (and an unpinned install is a cache hit that never moves). Offline, it reuses the version the
  existing image records in its `net.zodac.sandbox.claude-code-version` label.
- **A launch always rebuilds first** — Docker's layer cache makes that a near-instant no-op when
  nothing changed.

### Writing a project Dockerfile

Start from [`templates/configuration/Dockerfile`](templates/configuration/Dockerfile) or an example.

- Begin with `ARG BASE_IMAGE` and build the runtime stage `FROM ${BASE_IMAGE}`. The configuration
  directory is the build context, so it can `COPY` its own files.
- **A download of any size goes in a build stage of its own** and is `COPY`'d in near the top. A
  changed base (a pin bump here) re-runs the project's layers, but then only as local copies from the
  cached stages, never as fresh downloads.
- **Pin every version**, and keep apt packages in `# BEGIN DEBIAN PACKAGES` / `# END DEBIAN PACKAGES`
  blocks (one `name="version" \` per line, both `--mount` flags on the `RUN` line): that is the shape
  `update-versions` - and most projects' own update scripts - rely on.
- Stay root (the default). Anything that must run as the sandbox user uses `runuser -u dev -- ...`.
- `ENV` values reach the session as-is: the entrypoint switches to `dev` with `setpriv`, which keeps
  the environment, so there is no allow-list to maintain.
- Never `COPY` `.claude-history` (Claude's OAuth tokens): `sandbox.sh` creates a `.dockerignore`
  excluding it if the directory has none, and warns if an existing one doesn't.

## sandbox.conf

Plain bash, sourced on the host before every launch; an environment variable of the same name
overrides it (`SANDBOX_PORTS= ai-sandbox/sandbox.sh` publishes nothing, once). A `SANDBOX_*` name the
file sets that is not listed here gets a warning, since it would otherwise silently do nothing.

| Setting                  | Default        | Meaning                                                                                                                           |
| ------------------------ | -------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `SANDBOX_PORTS`          | *(empty)*      | `host:container` pairs to publish                                                                                                 |
| `SANDBOX_CACHE_VOLUMES`  | *(empty)*      | `name:/container/path` pairs, each a named volume `<sandbox-name>-<name>` that survives teardown                                  |
| `SANDBOX_NPM_DIRS`       | *(empty)*      | dirs (relative to the project, `.` = root) to `npm ci` on open, when the lockfile changed; one with no `package.json` warns       |
| `SANDBOX_ENV`            | *(empty)*      | extra `KEY=VALUE` environment; a bash array for a value with spaces: `("KEY=a b")`                                                |
| `SANDBOX_BUILD_ARGS`     | *(empty)*      | `KEY=VALUE` build args for the project's Dockerfile, in the same two forms: how it learns anything from outside its build context |
| `SANDBOX_RUN_ARGS`       | *(empty)*      | extra `docker run` flags, passed through as-is                                                                                    |
| `SANDBOX_HISTORY_DAYS`   | `14`           | days of Claude session history (transcripts, file history, tool results) to keep; older is deleted at startup                     |
| `SANDBOX_REMOTE_CONTROL` | `true`         | whether Claude starts its Remote Control bridge with each session                                                                 |
| `SANDBOX_NAME`           | derived        | pin the docker name prefix instead of deriving it from the checkout's path                                                        |
| `SANDBOX_TZ`             | host's zone    | the sandbox's timezone (IANA name)                                                                                                |

Two more are read from the environment only: `PROJECT_DIR` (default: the submodule's parent) and
`SANDBOX_CONFIG_DIR` (default: `$PROJECT_DIR/ai-sandbox-configuration`).

## Start-up and per-open setup

At every start, as root, [`entrypoint.sh`](image/final/entrypoint.sh) starts the nested `dockerd`,
applies the host's timezone, hands the mount points to `dev`, and runs the project's
`entrypoint.d/*.sh` (in name order; a failure is reported, not fatal). Then, as `dev`,
[`launch.sh`](image/final/launch.sh) recovers Claude's login from its own snapshot if an abrupt
teardown lost it, and re-asserts the sandbox's Claude settings (`SANDBOX_REMOTE_CONTROL`, permissions
bypassed, and the `SANDBOX_HISTORY_DAYS` transcript cleanup).

Every open **from a terminal** then runs [`setup.sh`](image/final/setup.sh), whose steps are guarded so
a re-open is a fast no-op. That includes `run <cmd>` in a terminal: only a launch with no TTY on stdin
(a script, a pipe) skips it.

1. `git submodule update --init`, if the project has an uninitialised submodule.
2. `npm ci` (`npm install` where there is no lockfile) in each `SANDBOX_NPM_DIRS` dir, when its lockfile
   changed. `ci` because `install` trusts the hidden `node_modules/.package-lock.json`, so it can report
   "up to date" over packages that do not match it.
3. Playwright's Chromium, for each of those dirs that declares Playwright, when its version changed. Only
   the browser: its OS libraries are the project's to bake in (see `examples/java-maven`'s
   `playwright-deps` stage), and it belongs in a `pw:/home/dev/.cache/ms-playwright` cache volume.
4. Claude's background jobs (`~/.claude/jobs/<id>`) unchanged for `SANDBOX_HISTORY_DAYS`, which the
   transcript cleanup does not cover (a job's `tmp/` can hold gigabytes). Pinned jobs are kept.
5. The PreToolUse guards, which fail silently, so they are proven here, in the environment that will run
   them, before any work happens: the organisation's ([`rules/hooks/`](rules/hooks), also checked for
   being registered in `.claude/settings.json`), then the project's
   `.claude/hooks/tests/run-hook-tests.sh`, if it has one.
6. The project's `setup.d/*.sh`, in name order, with `step`/`skip`/`warn`/`none` and `STATE_DIR` (for
   "already done" markers, persisted with `~/.claude`) available.

## Shutdown — how the container is torn down

`sandbox.sh` stops **and removes** the container whenever the launcher ends:

- **closing the terminal tab or quitting IntelliJ** — SIGHUP/SIGTERM fires the launcher's trap. *This
  is the everyday "stop" in terminal mode*, where IntelliJ shows no ■ Stop button.
- the **`Claude Sandbox (Stop)`** run configuration, or `ai-sandbox/sandbox.sh stop`.
- `exit` / Ctrl-D in the session.
- **starting the same project's sandbox again** (see *Independence*).

The trap runs `docker stop -t 10` (the grace lets Claude finish its atomic rewrite of `.claude.json`),
and `docker run` is launched as `… & wait` so the trap fires the instant the signal arrives rather
than after IntelliJ has escalated to SIGKILL. `--rm` then removes the container, and the nested
`dockerd` plus everything it spun up dies with it.

## Persistence

`<name>` is the derived sandbox name (`docker ps` shows it).

| Mount                                       | Kind             | Holds                                                                         |
| ------------------------------------------- | ---------------- | ----------------------------------------------------------------------------- |
| `ai-sandbox-configuration/.claude-history/` | bind-mounted dir | Claude auth, session transcripts, memory, onboarding state; the shell history |
| `<name>-docker`                             | named volume     | the nested Docker's images/layers/build cache                                 |
| `<name>-<cache>`                            | named volume     | each `SANDBOX_CACHE_VOLUMES` entry (`~/.m2`, `~/.gradle`, ...)                |

`.claude-history/` is a plain directory in the checkout (with a `*` `.gitignore` of its own, so no
project `.gitignore` needs to know about it): inspect it with `ls`, back it up with `cp -r`, wipe it
with `rm -rf`. The rest are pure rebuildable caches, so they stay named volumes.

**Shell history** (`shell`, `attach`, and any interactive bash in the sandbox) is kept in
`.claude-history/.sandbox-state/bash_history` and written after every command, so it survives a
closed tab, a re-attach and a new container alike.

**Host paths work in the sandbox.** On a Linux or macOS host the project is mounted a second time at
its host path (the same directory), and Claude runs there. So a file dragged from IntelliJ into the
terminal, a path from *Copy Absolute Path* or a host build's stack trace opens in the sandbox, and the
file paths Claude prints are links IntelliJ can open. `/work` is still mounted, for scripts and older
transcripts. Claude keys its sessions by the directory it runs in, so each launch links that key to
`.claude-history/projects/-work`, where the sessions of earlier launches are (and still the one real
directory: a moved checkout, or an older ai-sandbox in `/work`, finds them all), and copies the
project's `/work` settings in `.claude.json` (backed up first, to
`.sandbox-state/claude.json.before-host-path`). The up-arrow prompt history of earlier launches stays
with `/work`. On Windows, Claude runs in `/work` as before.

**Claude's temporary directory** (its session scratchpads: the screenshots and other files it shows you)
is `.claude-history/.sandbox-state/tmp`, not the container's `/tmp`, so those files are on the host.
On a Linux or macOS host it is mounted inside the container at its **host** path. The
`[image] <path>` lines Claude prints then name a file the host can open: in IntelliJ's terminal (whose
`TERMINAL_EMULATOR`, like `TERM_PROGRAM` and `COLORTERM`, is passed into the sandbox so Claude knows
the terminal) the path is a link that opens the picture in the IDE. On Windows it is mounted at
`/opt/ai-sandbox/tmp` instead, which the host cannot open, but the files are still in that directory.
Files older than `SANDBOX_HISTORY_DAYS` are deleted at the next launch.

**The `-docker` volume is the one that grows.** Every nested build leaves layers and BuildKit cache
behind; measured at 77 GB on a two-month-old sandbox of a build-heavy project. The image bakes in a
BuildKit GC policy ([`daemon.json`](image/base/daemon.json): 20 GB cap, a week's retention), and
`sandbox.sh prune` reclaims the rest immediately — inside the running sandbox if there is one, so the
session is untouched. Remove a sandbox's volumes entirely with `docker volume rm <name>-docker ...`.

The host's own Docker keeps every rebuild's layers too; with multi-GB project images, cap its build
cache in the host's `/etc/docker/daemon.json` (then restart Docker):

```json
"builder": { "gc": { "enabled": true, "policy": [ { "maxUsedSpace": "100GB" } ] } }
```

## Updating versions

`ai-sandbox/sandbox.sh update-versions` bumps every `FROM image:tag` (within its major) and every
pinned package in a `BEGIN/END DEBIAN PACKAGES` block, in this repo's base Dockerfile **and** the
project's. Then launch to prove the new pins install. The base's pins are this repo's to commit; a
project's are the project's, so a project consuming this repo as a submodule uses `--project-only`.
A project whose own update script manages its image tags (a JDK proven before it is pinned, a Maven kept
in step with `pom.xml`) adds `--packages-only` and calls it for the Debian packages alone, which resolve
against the base's Debian release - so there is no need to re-implement that mapping per project.

The pins must keep moving, because Debian removes a superseded package version from its repositories and
a dead pin fails the build on any host that does not already have the image.
[`.github/scripts/update_dependency_versions.sh`](.github/scripts/update_dependency_versions.sh) bumps
everything this repo pins - the base, both examples, the GitHub Actions, the linters' images and the
`code-quality-config` submodule (see [Linting](#linting)) - so run it whenever a clean build fails on a
missing package version, then `./sandbox.sh build`. The
[`monthly_version_update.yml`](.github/workflows/monthly_version_update.yml) workflow runs it on the 1st
of each month (leaving out `android-gradle`, too large to prove on a hosted runner), proves the result
builds and still lints, and pushes it to `master`, which releases it.

> If configuration ever moves from Dockerfiles to declarative package lists (apt/pip files), the
> version tooling — this script and the projects' own — needs a new solution: it depends on the
> Dockerfile shape above.

## Upgrading a project

```bash
ai-sandbox/sandbox.sh update          # or: update 1.2.3
```

This is the one command for taking a project to a new release. It moves the submodule to the newest
`X.Y.Z` release tag (or the one given) - which brings every change to the launcher, the image and the
organisation rules - and then, run by **that** release, adds what the release brings to the project:

- **new run configurations** in `.run/` (one you deleted comes back, as it is part of the set);
- **new settings** the release needs: the organisation rules import in `CLAUDE.md`, and
  `.claude/settings.json`'s `"attribution": false` and hook guards.

It never overwrites or deletes a file: what is already there is the project's. The configuration
directory is not re-scaffolded either (a `Dockerfile` you removed stays removed). A release that needs an
existing file changed does it as a step of its own in `update`, and says so. Running `update` again does
no harm. It refuses if the submodule has local changes, and it doesn't commit: review and commit the moved
submodule along with any files it added or changed. The next launch rebuilds the image.

`init` is not part of upgrading: it is for a new project only, and on a project that is set up already
(it has `ai-sandbox-configuration/sandbox.conf`) it fails with an error that suggests `update`. Upgrading
from 1.2.2 or older shows that error too, because that release's `update` ends by running the new
release's `init`. The submodule has moved by then, so run `update` once more to add what the release
brings.

A project's own update script can still move the tag itself. If it does, run `ai-sandbox/sandbox.sh update`
afterwards with that tag (`update X.Y.Z`): with the submodule already there, it only adds what the release
brings. `update` only exists from 1.1.0, so a project on 1.0.x moves by hand once, and lets that release's
`init` add the rest: `git -C ai-sandbox fetch --tags && git -C ai-sandbox checkout <tag> && ai-sandbox/sandbox.sh init`.

## Developing ai-sandbox in its own sandbox

This repo is its own sandbox project. It runs its **working tree**, not a published tag: making the repo
a submodule of itself would nest one copy per release under any consumer that clones `--recursive`.
`sandbox.sh` spots this case (an `ai-sandbox-configuration/` of its own, and no superproject) and uses
the repo itself as the project. Its configuration (a `Dockerfile` that adds `shellcheck`), its run
configurations (launching `$PROJECT_DIR$/sandbox.sh`) and its `.claude/` files are committed, so `init`
isn't needed here and refuses to run. The run configurations are in `.idea/runConfigurations/`, not
`.run/`: IntelliJ loads every `*.run.xml` in a project, a submodule's included, so a consuming project
would get them too, and they would shadow its own configurations of the same name with a script path
that doesn't exist there. Edits to `image/` or `sandbox.sh` take effect at the next launch:
if one breaks the sandbox, fix it from the host.

## Linting

The workflows, shell scripts, Dockerfiles and Markdown are linted by
[`.github/scripts/lint_workflows.sh`](.github/scripts/lint_workflows.sh) (actionlint),
[`lint_shell_scripts.sh`](.github/scripts/lint_shell_scripts.sh) (ShellCheck),
[`lint_dockerfiles.sh`](.github/scripts/lint_dockerfiles.sh) (hadolint) and
[`lint_markdown.sh`](.github/scripts/lint_markdown.sh) (markdownlint), run from the repository root. Each
runs its linter from a Docker image pinned in the script, with the rules every project shares from the
[`code-quality-config`](https://github.com/zodac/code-quality-config) submodule (pinned to a release tag):
after cloning, run `git submodule update --init`. The submodule is for this repo's own linting only - a
project consuming ai-sandbox has no use for it, and doesn't get it unless it clones `--recursive`.

The release workflow runs all four before it tags anything, so a documentation-only push (which isn't
released) is not linted in CI: run `lint_markdown.sh` before pushing one.

## Releases

Every push to `master` that changes more than documentation (Markdown files and `.claude/`) is released by
[`.github/workflows/publish.yml`](.github/workflows/publish.yml): it is tagged with the version in
[`VERSION`](VERSION), gets a GitHub release with a changelog grouped by commit `[Category]`, and `VERSION`
is bumped to the next patch. For a minor or major release, edit `VERSION` before pushing. Projects pin a
**tag** of this repo as their submodule, and move to the newest one with their own update scripts. The
base and the `java-maven` example are built and the tree is [linted](#linting) first, and a failure stops
the release; `android-gradle`
is too large to build on a hosted runner.

## Notes

- **The host's git settings are copied in on every launch**, so identity, aliases and preferences need
  no configuring in the sandbox: `git config --global --includes` and the global ignore file, as of that
  launch, with a repository's own `.git/config` still taking precedence. Left out are credentials and
  URL rewrites, anything matching token/password/secret, commit signing, LFS and other host programs,
  and host paths ([`export_git_config`](sandbox.sh) has the list). Aliases are copied as they are, so
  keep secrets out of them. A `git config --global` in a session lasts until the container goes. The base
  image has `vim` (and so `vi`); a host `core.editor` naming anything else needs adding to the project's
  Dockerfile.
- **This is settings, not access: a sandbox can commit but not push.** The image has no SSH client and
  no credentials, so pushing or fetching a private remote needs a `gh auth login` and an HTTPS remote.
- **`gh` ships no credentials, and nothing persists any.** A `gh auth login` is entered per session and
  dies with the container. That is deliberate: adding a token passthrough or a volume for
  `~/.config/gh` is a policy decision that has already been taken the other way.
- **Windows (Git Bash)** works the same: point the run configurations' interpreter at Git Bash
  (`C:\PROGRA~1\Git\bin\bash.exe`, the 8.3 path avoiding IntelliJ's space-escaping bug); `sandbox.sh`
  converts paths for Docker Desktop itself.
