# OpenSST Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, test, package, publish, and install a portable `sst` Bash CLI for reconnectable remote tmux sessions.

**Architecture:** A single executable Bash script owns CLI parsing, SSH safety validation, remote tmux command construction, terminal cleanup, and reconnect behavior. Dependency-light Bash tests drive the executable through a fake SSH binary; DEB/RPM scripts package the same executable into `/usr/bin/sst`, while `make install` installs to `/usr/local/bin` or a user prefix. GitHub Actions runs tests, package smoke tests, and a manually triggered tag/release workflow.

**Tech Stack:** Bash, OpenSSH client, remote tmux, GNU Make, `dpkg-deb`, `rpmbuild`, GitHub Actions, GitHub CLI.

**Spec:** `docs/specs/2026-11-25-opensst-design.md`

## Global Constraints

- The runtime is `bin/sst`, installed as executable `sst`; it is never sourced by users.
- Runtime must not depend on Omarchy, Ghostty, Python, Mosh, autossh, or systemd.
- Project names must match `^[A-Za-z0-9][A-Za-z0-9_-]*$`.
- `open` runs `tmux new-session -A -D -s <project>` with a PTY.
- `list` runs `tmux list-sessions` once without a PTY.
- `kill` runs `tmux kill-session -t =<project>` once without a PTY.
- Only `open` may reconnect; only SSH status 255 after at least 30 seconds qualifies; retries wait 2 seconds.
- `kill` and `list` never retry, including on status 255.
- All operations preflight remote tmux in the same SSH invocation and return 127 when tmux is absent.
- DEB/RPM package name is `opensst`; packaged executable path is `/usr/bin/sst`.
- Source installation defaults to `/usr/local/bin/sst`; `PREFIX` must be overridable.
- DEB dependencies are `bash` and `openssh-client`; RPM dependencies are `bash` and `openssh-clients`.
- Release versions are stable `MAJOR.MINOR.PATCH`; tags are `v<version>`; initial version is `0.1.0`.
- Releases are manual `workflow_dispatch` only; ordinary pushes never tag or release.
- Versioning, commits, tags, pushes, Releases, and GitHub metadata changes require explicit authorization.
- Tests must never contact a real remote host.
- Git uses the HTTPS remote `https://github.com/opensst/opensst.git`; no global Git configuration changes.
- No package-owned Omarchy file may be modified.

## Review Focus

- SSH options that consume separate or attached values (`-p 2222`, `-p2222`, `-oRemoteCommand=...`, `-J host`, `--`) must not be mistaken for destinations or remote commands.
- Effective `RemoteCommand` from SSH configuration must fail closed; explicit `-o RemoteCommand=none` must be accepted.
- Fast connection failures must not loop, management commands must never replay, and reconnect must preserve the exact SSH arguments and project.
- Package contents, dependencies, install paths, and release tag ordering must remain consistent across DEB, RPM, source install, and GitHub Actions.
- Installation must not leave the old Bash function shadowing the executable or silently mix `/usr/bin/sst` with `/usr/local/bin/sst`.

---

### Task 1: Test Harness, CLI Shell, and Repository Bootstrap

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `bin/sst`
- Create: `tests/run.bash`
- Create: `tests/fixtures/bin/ssh`

**Interfaces:**
- Consumes: Nothing.
- Produces: executable `bin/sst`; `_sst_usage()`; `_sst_main(argv...) -> exit status`; test helpers `pass`, `fail`, `assert_eq`, `assert_contains`, `run_capture`; fake SSH driven by `FAKE_SSH_LOG`, `FAKE_SSH_G_LOG`, `FAKE_SSH_G_FAIL`, `FAKE_SSH_G_REMOTE_COMMAND`, `FAKE_SSH_EXIT`, and `FAKE_SSH_EXEC_REMOTE`.

- [ ] **Step 1: Create the failing help/usage tests**

Create `tests/run.bash` with a pure-Bash harness. The first tests must assert:

```text
sst --help exits 0 and prints open, list, kill, and --help lines
sst -h exits 0 and prints the same usage
sst with no arguments exits 2 and prints usage to stderr
sst unknown exits 2 and prints usage to stderr
```

Run the script directly through a captured invocation that does not require SSH or a terminal. Use temporary output files rather than command substitution when a test needs terminal semantics.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `bash tests/run.bash`

Expected: FAIL because `bin/sst` does not exist or has no help behavior.

- [ ] **Step 3: Implement the minimal CLI shell**

Create `bin/sst` with:

```bash
#!/usr/bin/env bash
set -u

_sst_usage() { ... }

_sst_main() {
  case ${1-} in
    -h|--help) _sst_usage ;;
    '') _sst_usage >&2; return 2 ;;
    *) _sst_usage >&2; return 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  _sst_main "$@"
fi
```

The sourcing guard is required so later unit tests can call internal functions without executing the CLI.

Create a Makefile with `test` and `check`; `check` runs `bash -n bin/sst` and `bash -n tests/run.bash` before `test`. Create `.gitignore` containing `/dist/`, `*.deb`, `*.rpm`, and temporary test paths.

Create the fake SSH fixture. It must:

- Log configuration probes containing `-G` to `FAKE_SSH_G_LOG`.
- Log real connection arguments to `FAKE_SSH_LOG`, one escaped line per invocation.
- Return `FAKE_SSH_EXIT`, default 0.
- Emit `remotecommand <value>` unless `FAKE_SSH_G_REMOTE_COMMAND` is unset or `none`.
- Fail configuration resolution when `FAKE_SSH_G_FAIL=1`.
- When `FAKE_SSH_EXEC_REMOTE=1`, execute the final remote command with `/bin/bash` under `PATH=/nonexistent` to exercise the missing-tmux path.

- [ ] **Step 4: Run tests and syntax checks**

Run: `make check`

Expected: all Task 1 tests PASS; both Bash syntax checks pass.

- [ ] **Step 5: Initialize Git and commit**

```bash
git init -b main
chmod +x bin/sst tests/run.bash tests/fixtures/bin/ssh
git add .gitignore Makefile bin/sst tests/run.bash tests/fixtures/bin/ssh \
  docs/specs/2026-11-25-opensst-design.md \
  docs/plans/2026-11-25-opensst-implementation.md
git commit -m "test: bootstrap sst CLI and test harness"
```

Do not add a remote or push yet.

### Task 2: Project and SSH Argument Validation

**Files:**
- Modify: `bin/sst`
- Modify: `tests/run.bash`
- Modify: `tests/fixtures/bin/ssh`

**Interfaces:**
- Consumes: `_sst_main`, fake SSH logs.
- Produces: `_sst_valid_project(name) -> 0|1`; `_sst_validate_ssh(argv...) -> 0|1`; destination parsing and fail-closed `RemoteCommand` checking.

- [ ] **Step 1: Add failing validation tests**

Because command dispatch is not implemented until Tasks 3 and 4, test the internal validator directly by sourcing `bin/sst`. Add tests proving:

```text
_sst_valid_project accepts Work, project-x, api_2, Work-tab1
_sst_valid_project rejects '', -bad, .hidden, 'Work;id', 'Work space', 'Work/other'
_sst_validate_ssh -p 2222 devbox returns 0
_sst_validate_ssh -p2222 devbox returns 0
_sst_validate_ssh -J jump@example devbox returns 0
_sst_validate_ssh -oRemoteCommand=none devbox returns 0
_sst_validate_ssh -- devbox returns 0
_sst_validate_ssh returns 1 with no destination
_sst_validate_ssh devbox extra returns 1 for a positional remote command
_sst_validate_ssh devbox -p returns 1 for a missing option value
_sst_validate_ssh -o RemoteCommand='printf bad' devbox returns 1
_sst_validate_ssh devbox returns 1 when fake ssh -G fails
```

Count only real connection log lines; configuration probes belong in the `-G` log. Command-level project rejection tests are added in Tasks 3 and 4 when those commands exist.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `bash tests/run.bash`

Expected: new tests FAIL because validation and management dispatch are absent.

- [ ] **Step 3: Implement validation**

Add `_sst_valid_project` using `[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]`.

Add `_sst_validate_ssh` with this value-taking option set:

```text
BbcDEeFIiJLlmOoPpQRSWw
```

Parsing rules:

- `--` ends options.
- Arguments beginning with `-` are option clusters.
- A value-taking letter consumes the rest of its cluster or the next argument when it ends the cluster.
- The first non-option is the sole destination.
- Any second non-option is a positional remote command and fails validation.
- Missing destination fails validation.
- After parsing, run `command ssh -G "${argv[@]}"`; failure is a validation failure.
- Scan each resolved line. `remotecommand none` is accepted; any other `remotecommand` line fails.

The CLI must print a concise diagnostic and return 2 on validation failure before invoking a real connection. Do not call `eval`.

- [ ] **Step 4: Run tests and syntax checks**

Run: `make check`

Expected: all validation tests PASS, and invalid cases show zero real connection lines.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash tests/fixtures/bin/ssh
git commit -m "feat: validate projects and SSH arguments"
```

### Task 3: List and Kill Operations

**Files:**
- Modify: `bin/sst`
- Modify: `tests/run.bash`

**Interfaces:**
- Consumes: `_sst_valid_project`, `_sst_validate_ssh`.
- Produces: `_sst_remote_command(project, operation) -> stdout`; `_sst_require_ssh() -> 0|127`; `_sst_cmd_list(argv...)`; `_sst_cmd_kill(argv...)`.

- [ ] **Step 1: Add failing list/kill tests**

Add tests proving:

```text
sst list -p 2222 devbox invokes ssh with -T before host and the fixed list command
sst kill -p 2222 devbox Work invokes ssh with -T before host and exact =Work
sst kill devbox 'Work;id' exits 2 and makes no SSH connection
sst kill devbox Work exits 255 from fake ssh after exactly one connection
sst list devbox exits 255 from fake ssh after exactly one connection
sst list/kill do not emit terminal-reset escape sequences
sst list/kill with missing remote tmux return 127 and mention installing tmux or fixing PATH
sst list with no local ssh in PATH exits 127 with a clear error
```

Assert that management operations never contain `-t` in the real connection log.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `bash tests/run.bash`

Expected: list/kill tests FAIL.

- [ ] **Step 3: Implement fixed remote commands and dispatch**

Construct a single-quoted-safe remote command that first checks:

```sh
command -v tmux >/dev/null 2>&1 || {
  printf '%s\n' 'sst: remote tmux not found; install tmux or add it to PATH' >&2
  exit 127
}
```

Then `exec tmux list-sessions`, or `exec tmux kill-session -t =<project>`. The fixed suffix is based only on the validated project.

`list` and `kill` parse the final project only for `kill`, validate, then call:

```bash
_sst_ssh -T "${argv[@]}" "$remote"
```

Return the SSH status unchanged. Do not call `_sst_disarm`, sleep, or retry.

- [ ] **Step 4: Run tests**

Run: `make check`

Expected: all Task 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash
git commit -m "feat: add remote session listing and exact removal"
```

### Task 4: Open, Terminal Safety, and Reconnect

**Files:**
- Modify: `bin/sst`
- Modify: `tests/run.bash`

**Interfaces:**
- Consumes: validation, remote command construction.
- Produces: `_sst_disarm()`; `_sst_ssh(argv...)`; `_sst_open_session(argv..., project) -> exit status`; `_sst_cmd_open(argv...)`.

- [ ] **Step 1: Add failing open tests**

Add end-to-end tests proving:

```text
sst open with non-TTY stdin/stdout exits 2 and does not connect
sst open -p 2222 devbox Work under script(1) invokes -t and new-session -A -D -s Work
sst open devbox 'Work;id' under script(1) exits 2 and makes no SSH connection
sst open returns 127 with missing remote tmux
sst open returns a fast 255 after exactly one connection attempt
```

Add sourced unit tests proving:

```text
a qualifying 255 calls _sst_disarm after the failed attempt
a qualifying 255 logs the reconnect message and retries with identical argv/project
the retry returns 0 and ends the loop
a non-255 retry result ends the loop with that status
```

For the unit test, source `bin/sst`, override `_sst_ssh`, `_sst_disarm`, and `sleep`, then call `_sst_open_session -p 2222 devbox Work`. The validator and TTY checks remain in `_sst_cmd_open`, so the sourced session loop can be tested without a terminal. On the first `_sst_ssh` call set `SECONDS=$((SECONDS + 31))` and return 255; use a temporary call log because the retry loop runs in a subshell.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make check`

Expected: new open tests FAIL.

- [ ] **Step 3: Implement open and reconnect**

`_sst_cmd_open` must require `[[ -t 0 && -t 1 ]]`, take the final argument as project, validate it and the preceding SSH argv, then delegate to `_sst_open_session`.

`_sst_open_session` runs the remote command with a PTY:

```bash
started=$SECONDS
_sst_ssh -t "${argv[@]}" "$remote"
rc=$?
_sst_disarm
```

Return immediately unless `rc == 255` and `SECONDS - started >= 30`. In that case print a reconnect notice to stderr and run a foreground subshell loop that sleeps 2 seconds, retries the identical command, disarms after each attempt, and exits on any non-255 status.

`_sst_disarm` writes the same terminal-reset sequences used before:

```bash
printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1004l\e[?1049l\e[?25h'
```

`_sst_ssh` is a thin `command ssh "$@"` wrapper so it remains independently testable.

- [ ] **Step 4: Run tests**

Run: `make check`

Expected: all runtime tests PASS without waiting 30 seconds.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash
git commit -m "feat: add reconnectable interactive sessions"
```

### Task 5: Source Installation and DEB/RPM Packaging

**Files:**
- Modify: `Makefile`
- Modify: `tests/run.bash`
- Create: `packaging/build-deb.sh`
- Create: `packaging/build-rpm.sh`
- Create: `README.md` (minimal packaging prerequisite; completed in Task 6)
- Create: `LICENSE`

**Interfaces:**
- Consumes: `bin/sst`, README.md, LICENSE.
- Produces: `make install|uninstall`; `make package-deb|package-rpm`; `packaging/build-deb.sh VERSION [OUTDIR]`; `packaging/build-rpm.sh VERSION [OUTDIR]`.

- [ ] **Step 1: Add failing installation tests**

Add tests proving:

```text
make install PREFIX=<tmp>/user installs <tmp>/user/bin/sst executable and --help works
make install PREFIX=/usr/local DESTDIR=<tmp>/root installs <tmp>/root/usr/local/bin/sst
make uninstall removes the installed file
make install performs no sudo operation
```

If `dpkg-deb` is available, add a package test asserting `opensst_0.1.0_all.deb`, `Package: opensst`, `Version: 0.1.0`, `Architecture: all`, and `/usr/bin/sst` in the archive. If unavailable, print a skip message. Apply the analogous conditional test for `rpmbuild` and `opensst-0.1.0-1.noarch.rpm`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make check`

Expected: installation/package tests FAIL because targets and scripts are absent.

- [ ] **Step 3: Create package documentation prerequisites, Makefile, and builders**

First create a minimal `README.md` describing `sst` as an SSH/tmux session manager and the full MIT `LICENSE` with `Copyright (c) 2026 duanhongyi`. Task 6 completes the README and adds maintainer documentation.

Use conventional variables:

```make
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DESTDIR ?=
```

`install` uses `install -Dm755 bin/sst "$(DESTDIR)$(BINDIR)/sst"`. `uninstall` removes the same path. Package targets call the scripts with an explicit version and `dist/`.

`build-deb.sh` stages `/usr/bin/sst`, `/usr/share/doc/opensst/README.md`, `/usr/share/doc/opensst/copyright`, and `DEBIAN/control` with package dependencies `bash, openssh-client`; builds with `dpkg-deb --root-owner-group`.

`build-rpm.sh` creates a deterministic `opensst-$VERSION.tar.gz`, generates a `noarch` spec, and invokes `rpmbuild -bb` with an isolated topdir. The spec uses `Requires: bash, openssh-clients`, installs `%{_bindir}/sst`, and includes README.md and LICENSE via `%doc`.

Both scripts reject invalid versions and report missing tools clearly. Neither invokes sudo or contacts the network.

- [ ] **Step 4: Run available local checks**

Run: `make check`

Expected: installation tests PASS; package tests either PASS or print explicit skips for missing packagers.

- [ ] **Step 5: Commit**

```bash
chmod +x packaging/build-deb.sh packaging/build-rpm.sh
git add Makefile packaging tests/run.bash README.md LICENSE
git commit -m "feat: add source install and Linux package builds"
```

### Task 6: User and Maintainer Documentation

**Files:**
- Modify: `README.md`
- Create: `AGENTS.md`
- Modify: `tests/run.bash`

**Interfaces:**
- Consumes: final CLI and Makefile behavior.
- Produces: discoverable user documentation, release governance, and MIT licensing.

- [ ] **Step 1: Add failing documentation checks**

Add tests asserting README.md contains the exact CLI forms, `/usr/local/bin`, `/usr/bin/sst`, DEB/RPM install commands, reconnect timing, `-D` warning, and the command-name conflict note. Assert AGENTS.md contains Release, Version History, and explicit-authorization language. Assert LICENSE contains `MIT License`, `2026`, and `duanhongyi`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `bash tests/run.bash`

Expected: documentation tests FAIL.

- [ ] **Step 3: Complete README.md**

Open with a searchable paragraph covering SSH, tmux, reconnectable remote sessions, Linux, Bash, and CLI. Add CI, latest release, MIT, and Linux badges. Document dependencies, source package installs, upgrade/uninstall, examples, exit behavior, reconnect timing, exact kill, `-D`, security boundaries, development tests, and package building. Explicitly warn that `sst` may conflict with Serverless SST and that packages and source installs should not be mixed.

- [ ] **Step 4: Write AGENTS.md and verify LICENSE**

AGENTS.md must include:

- Project purpose and layout.
- Runtime and test commands.
- Safety invariants from the specification.
- Packaging rules: package name, `/usr/bin/sst`, architecture-independent, dependencies.
- CI description.
- Release process: clean main, version/history update, `make check`, authorized commit/push, manual workflow at exact version, package smoke tests, verify tag/Release/assets.
- Idempotency and no-moving-tag rules.
- Explicit authorization requirements.
- Version History table starting with `0.1.0`.

Verify the existing MIT LICENSE contains `Copyright (c) 2026 duanhongyi`; do not replace it unnecessarily.

- [ ] **Step 5: Run checks and commit**

Run: `make check`

Expected: all documentation and runtime tests PASS.

```bash
git add README.md AGENTS.md tests/run.bash
git commit -m "docs: document usage, safety, and release governance"
```

### Task 7: Continuous Integration and Package Smoke Tests

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `make check`, packaging scripts, GitHub Actions.
- Produces: CI runs for pushes and pull requests; DEB install test on Ubuntu; RPM install test in Fedora; uploaded package artifacts.

- [ ] **Step 1: Write the CI workflow**

Triggers: `push` and `pull_request`. Set top-level `permissions: contents: read`.

Jobs:

- `test`: Ubuntu, checkout, run `make check`.
- `package-deb`: needs `test`; build with `packaging/build-deb.sh 0.1.0 dist`; install the local DEB; run `sst --help`; upload DEB.
- `package-rpm`: needs `test`; install `rpm` with apt; build with `packaging/build-rpm.sh 0.1.0 dist`; run a disposable Fedora container that executes `dnf install -y /dist/*.rpm` and `sst --help`; upload RPM.

Use only official actions with fixed major versions. Do not use repository secrets. Keep artifact retention short.

- [ ] **Step 2: Validate YAML syntax and referenced local paths**

Run available local checks, including a parser if present, and manually verify every `run:` path and script name. Run:

```bash
make check
grep -n "workflow\|package-deb\|package-rpm\|sst --help" .github/workflows/ci.yml
```

Expected: local checks PASS and all referenced paths exist.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: test runtime and Linux packages"
```

Full CI success is verified after the authorized initial push in Task 9.

### Task 8: Manual Release Workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: CI-tested runtime and package scripts.
- Produces: manual `workflow_dispatch` version input; verified DEB/RPM assets and SHA256SUMS; annotated `v<version>` tag; GitHub Release with generated notes.

- [ ] **Step 1: Write the release workflow**

Use `workflow_dispatch` with required string input `version`. Top-level permissions are `contents: read`.

Jobs:

- `validate`: require `refs/heads/main`; require stable SemVer; checkout with full tags; reject an existing tag at a different commit.
- `test`: needs validate; run `make check`.
- `package-deb`: needs test; build DEB and smoke-install it on Ubuntu.
- `package-rpm`: needs test; build RPM and smoke-install it in Fedora.
- `release`: needs both package jobs; set `contents: write`; download packages; generate `SHA256SUMS`; create/reuse an annotated tag only when it points to `GITHUB_SHA`; create the Release with `--verify-tag --generate-notes`; upload DEB, RPM, and SHA256SUMS. If the Release already exists, leave it unchanged and exit successfully.

Use `GH_TOKEN: ${{ github.token }}`. Do not trigger a release on push or PR. Do not delete, replace, or move existing tags/releases.

- [ ] **Step 2: Verify workflow structure and safety strings**

Run:

```bash
make check
grep -n "workflow_dispatch\|contents: write\|verify-tag\|generate-notes\|SHA256SUMS" .github/workflows/release.yml
```

Expected: local checks PASS; workflow is manual-only; only the final job has write permission.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add verified manual release workflow"
```

Do not run the workflow or create a tag in this task.

### Task 9: Initial Git Publication and GitHub Metadata

**Files:**
- Modify: `.git/config` locally only (remote and credential helper).
- No tracked file changes.

**Interfaces:**
- Consumes: complete verified repository.
- Produces: `main` pushed to `opensst/opensst`; public repository description and topics; CI run evidence.

- [ ] **Step 1: Run the complete local gate**

```bash
make check
bash -n bin/sst
bash -n tests/run.bash
git status --short
```

Expected: all tests PASS; no syntax errors; only intended files are staged/committed and the worktree is clean.

- [ ] **Step 2: Configure the HTTPS remote and local credential helper**

```bash
git remote add origin https://github.com/opensst/opensst.git
git config --local credential.helper '!gh auth git-credential'
git remote -v
```

Do not run `gh auth setup-git` and do not modify global Git configuration.

- [ ] **Step 3: Push main**

```bash
git push -u origin main
```

Expected: `main` is created remotely and tracks `origin/main`.

- [ ] **Step 4: Set and verify repository metadata**

Use `gh repo edit opensst/opensst` with the exact description:

```text
Reconnectable SSH sessions with remote tmux — open, list, and kill named Linux sessions from a portable Bash CLI.
```

Topics:

```text
ssh tmux openssh ssh-client terminal remote-development persistent-sessions session-manager linux bash cli developer-tools
```

Verify with:

```bash
gh repo view opensst/opensst --json description,repositoryTopics,visibility,url
```

Expected: public repository, exact description, all topics present.

- [ ] **Step 5: Verify workflows and CI**

```bash
gh workflow list --repo opensst/opensst
gh run list --repo opensst/opensst --limit 5
```

Expected: CI and Release workflows are recognized. CI starts after the push. Inspect failures and fix only through new commits and an authorized follow-up push.

Do not create a tag or release.

### Task 10: Local Migration from the Omarchy Function

**Files:**
- Modify: `~/.bashrc`
- Delete: `~/.config/bash/sst.bash`
- Delete: `~/Nextcloud/Config/omarchy/docs/specs/2026-11-25-sst-config-design.md`
- Remove empty obsolete spec directories only.

**Interfaces:**
- Consumes: installed `~/.local/bin/sst`.
- Produces: fresh shells resolve `sst` to the standalone executable with no old function shadowing it.

- [ ] **Step 1: Install the new CLI**

```bash
make install PREFIX="$HOME/.local"
"$HOME/.local/bin/sst" --help
```

Expected: installation succeeds and help works.

- [ ] **Step 2: Back up and edit .bashrc**

Create a timestamped backup. Remove only this line and its comment:

```bash
# SSH + tmux with automatic reconnect
[[ -r ~/.config/bash/sst.bash ]] && source ~/.config/bash/sst.bash
```

Run `bash -n ~/.bashrc`.

- [ ] **Step 3: Remove the obsolete function file and abandoned spec**

Remove `~/.config/bash/sst.bash` and the abandoned `2026-11-25-sst-config-design.md`. Remove only empty parent spec directories. Do not modify Nextcloud AGENTS.md, report files, or the unrelated empty `~/Nextcloud/Config/sst`.

- [ ] **Step 4: Verify fresh command resolution**

```bash
bash -ic 'type -a sst; sst --help'
```

Expected: `sst` resolves to `$HOME/.local/bin/sst`, not a function, and help succeeds.

Existing interactive shells may still hold the old function; report the one-time `unset -f sst; hash -r` instruction to the user.

### Task 11: Final Verification and Release Readiness Report

**Files:**
- No file changes expected.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: fresh evidence for completion claims and a release-ready status without an unauthorized tag.

- [ ] **Step 1: Run final local verification**

```bash
make check
git status --short
git log --oneline -10
```

Expected: all tests PASS; worktree clean; commits present.

- [ ] **Step 2: Verify remote state and CI**

```bash
git ls-remote --heads origin main
gh repo view opensst/opensst --json description,repositoryTopics,url
gh workflow list --repo opensst/opensst
gh run list --repo opensst/opensst --limit 10
```

Expected: `main` exists; metadata matches; CI and Release workflows exist; CI conclusion is success or any failure is reported honestly with logs.

- [ ] **Step 3: Verify no release was created**

```bash
git ls-remote --tags origin 'v*'
gh release list --repo opensst/opensst
```

Expected: no tag or release unless the user separately authorized one.

- [ ] **Step 4: Report exact evidence**

Report test counts and pass/fail results, package smoke-test CI status, commit hash, installed command path, GitHub metadata, any skipped local package tests, and remaining release action requiring authorization. Do not claim CI success without a fresh successful run.

## Self-Review Notes

- Every specification area maps to a task: runtime safety (Tasks 1-4), installation/package (Task 5), documentation (Task 6), CI (Task 7), release (Task 8), GitHub publication/metadata (Task 9), migration (Task 10), evidence (Task 11).
- The plan does not prescribe a release tag; Task 8 creates the capability, and Task 11 verifies that no unauthorized tag exists.
- Package tests are explicitly conditional locally and authoritative in CI, matching the absence of `dpkg-deb` and `rpmbuild` on this Arch host.