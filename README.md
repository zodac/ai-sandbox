# ai-sandbox

A disposable Docker container for running **Claude Code with `--dangerously-skip-permissions`** (or
any other agent) against a project, isolated from the host machine. A project includes this repo as a
**git submodule**, describes what it needs in a directory of its own beside it, and launches it from
IntelliJ with a plain Shell Script run configuration.

```
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
└── .run/*.run.xml                 ← the IntelliJ run configurations (committed)
```

## Quick start

```bash
cd <project>
git submodule add https://github.com/zodac/ai-sandbox.git ai-sandbox
ai-sandbox/sandbox.sh init      # creates ai-sandbox-configuration/ (with empty bin/, entrypoint.d/, setup.d/) and .run/ - never overwrites
```

Then edit `ai-sandbox-configuration/sandbox.conf` (and its `Dockerfile` if the project needs a JDK,
Maven, an Android SDK, ...). [`examples/`](examples) has complete configurations to start from:

| Example                                      | Taken from | Adds                                                                            |
| -------------------------------------------- | ---------- | ------------------------------------------------------------------------------- |
| [`android-gradle`](examples/android-gradle)  | DiceFive   | JDK 25, Android SDK/NDK/emulator (`emulator.sh`), ImageMagick 7, ffmpeg, Playwright libs |
| [`java-maven`](examples/java-maven)          | Diurnal    | JDK 26, Maven, Playwright libs + browser, ImageMagick/librsvg/optipng, port 8071 |

In IntelliJ, the run configurations appear on their own (`.run/` is loaded without any plugin):

| Run configuration                | Does                                                                   |
| -------------------------------- | ---------------------------------------------------------------------- |
| `Claude Sandbox`                 | a fresh interactive Claude session                                     |
| `Claude Sandbox (Continue Last)` | `claude --continue`: the most recent session                           |
| `Claude Sandbox (Resume Any)`    | `claude --resume`: pick a previous session from a list                 |
| `Claude Sandbox (Shell)`         | a bash shell instead of Claude                                         |
| `Claude Sandbox (Attach Shell)`  | a second shell in the sandbox that is already running                  |
| `Claude Sandbox (Stop)`          | stop and remove the running sandbox (the closest thing to a Stop button) |

They reference the launcher only as `$PROJECT_DIR$/ai-sandbox/sandbox.sh`, so they hold no host path
and are safe to commit. All but `Stop` have **Execute in the terminal** ticked: Claude's TUI needs a
real PTY, and without one `sandbox.sh` falls back to non-interactive mode.

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
ai-sandbox/sandbox.sh init             # scaffold ai-sandbox-configuration/ and .run/
ai-sandbox/sandbox.sh update-versions  # bump the version pins in the base + project Dockerfiles
```

`continue` and `resume` are shorthands for `run claude --dangerously-skip-permissions --continue` /
`--resume`; the long forms still work. The transcripts they resume from live in
`ai-sandbox-configuration/.claude-history/`, which survives every restart, and Claude finds them
because the project is always mounted at the same `/work`.

## Why this is safe

- **Only the project directory is mounted** (→ `/work`, plus its configuration again at
  `/opt/ai-sandbox/config`). No `$HOME`, no SSH keys, no other projects are visible to the agent.
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
overrides it (`SANDBOX_PORTS= ai-sandbox/sandbox.sh` publishes nothing, once).

| Setting                 | Default        | Meaning                                                                                       |
| ----------------------- | -------------- | --------------------------------------------------------------------------------------------- |
| `SANDBOX_PORTS`         | *(empty)*      | `host:container` pairs to publish                                                             |
| `SANDBOX_CACHE_VOLUMES` | *(empty)*      | `name:/container/path` pairs, each a named volume `<sandbox-name>-<name>` that survives teardown |
| `SANDBOX_NPM_DIRS`      | *(empty)*      | dirs (relative to the project, `.` = root) to `npm install` on open, when the lockfile changed |
| `SANDBOX_ENV`           | *(empty)*      | extra `KEY=VALUE` environment (no spaces inside a value)                                      |
| `SANDBOX_RUN_ARGS`      | *(empty)*      | extra `docker run` flags, passed through as-is                                                |
| `SANDBOX_HISTORY_DAYS`  | `14`           | days of Claude session history (transcripts, file history, tool results) to keep; older is deleted at startup |
| `SANDBOX_NAME`          | derived        | pin the docker name prefix instead of deriving it from the checkout's path                    |
| `SANDBOX_TZ`            | host's zone    | the sandbox's timezone (IANA name)                                                            |

Two more are read from the environment only: `PROJECT_DIR` (default: the submodule's parent) and
`SANDBOX_CONFIG_DIR` (default: `$PROJECT_DIR/ai-sandbox-configuration`).

## Start-up and per-open setup

At every start, as root, [`entrypoint.sh`](image/final/entrypoint.sh) starts the nested `dockerd`,
applies the host's timezone, hands the mount points to `dev`, and runs the project's
`entrypoint.d/*.sh` (in name order; a failure is reported, not fatal). Then, as `dev`,
[`launch.sh`](image/final/launch.sh) recovers Claude's login from its own snapshot if an abrupt
teardown lost it, and re-asserts the sandbox's Claude settings (Remote Control at startup, permissions
bypassed, and the `SANDBOX_HISTORY_DAYS` transcript cleanup).

Every **interactive** open (not `run <cmd>`) then runs [`setup.sh`](image/final/setup.sh), whose
steps are guarded so a re-open is a fast no-op:

1. `git submodule update --init`, if the project has an uninitialised submodule.
2. `npm install` in each `SANDBOX_NPM_DIRS` dir that has a `package.json`, when its lockfile changed.
3. `.claude/hooks/tests/run-hook-tests.sh`, if the project has PreToolUse guards: they fail silently,
   so they are proven here, in the environment that will run them, before any work happens.
4. The project's `setup.d/*.sh`, in name order, with `step`/`skip`/`warn`/`none` and `STATE_DIR` (for
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

| Mount                                       | Kind             | Holds                                                         |
| ------------------------------------------- | ---------------- | ------------------------------------------------------------- |
| `ai-sandbox-configuration/.claude-history/` | bind-mounted dir | Claude auth, session transcripts, memory, onboarding state; the shell history |
| `<name>-docker`                             | named volume     | the nested Docker's images/layers/build cache                 |
| `<name>-<cache>`                            | named volume     | each `SANDBOX_CACHE_VOLUMES` entry (`~/.m2`, `~/.gradle`, ...) |

`.claude-history/` is a plain directory in the checkout (with a `*` `.gitignore` of its own, so no
project `.gitignore` needs to know about it): inspect it with `ls`, back it up with `cp -r`, wipe it
with `rm -rf`. The rest are pure rebuildable caches, so they stay named volumes.

**Shell history** (`shell`, `attach`, and any interactive bash in the sandbox) is kept in
`.claude-history/.sandbox-state/bash_history` and written after every command, so it survives a
closed tab, a re-attach and a new container alike.

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
project's are the project's.

> If configuration ever moves from Dockerfiles to declarative package lists (apt/pip files), the
> version tooling — this script and the projects' own — needs a new solution: it depends on the
> Dockerfile shape above.

## Releases

Every push to `master` that changes more than documentation (Markdown files and `.claude/`) is released by
[`.github/workflows/publish.yml`](.github/workflows/publish.yml): it is tagged with the version in
[`VERSION`](VERSION), gets a GitHub release with a changelog grouped by commit `[Category]`, and `VERSION`
is bumped to the next patch. For a minor or major release, edit `VERSION` before pushing. Projects pin a
**tag** of this repo as their submodule, and move to the newest one with their own update scripts.

## Notes

- **`gh` ships no credentials, and nothing persists any.** A `gh auth login` is entered per session and
  dies with the container. That is deliberate: adding a token passthrough or a volume for
  `~/.config/gh` is a policy decision that has already been taken the other way.
- **Windows (Git Bash)** works the same: point the run configurations' interpreter at Git Bash
  (`C:\PROGRA~1\Git\bin\bash.exe`, the 8.3 path avoiding IntelliJ's space-escaping bug); `sandbox.sh`
  converts paths for Docker Desktop itself.
