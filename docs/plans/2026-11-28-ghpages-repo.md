# GitHub Pages Package Repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a latest-only DEB/RPM/pacman repository as a single orphan commit on `gh-pages`, so users of all three families upgrade via their system package manager.

**Architecture:** One per-family generator script (`packaging/site-build.sh deb|rpm|arch`) builds each family's site subdirectory from that release's package artifacts; the Release workflow rebuilds the whole site, commits it as one orphan commit, and force-pushes `gh-pages`. Release assets remain the install contract; the site is the upgrade channel.

**Tech Stack:** Bash, `repo-add` (pacman 7.x), `dpkg-scanpackages` + `apt-ftparchive` (dpkg-dev, apt-utils), `createrepo_c` (createrepo-c), GitHub Actions.

**Spec:** `docs/specs/2026-11-28-ghpages-repo-design.md` (approved; target release 0.3.0)

## Global Constraints

- Local tests: no root, no network, no real hosts; skip-gate per missing tool with a `# skip` message (existing pattern, tests/run.bash:1315).
- New tests read the version dynamically from `bin/sst` (`sed -n "s/^SST_VERSION='\([0-9.]*\)'$/\1/p" bin/sst | head -n1`), never hardcode it — tasks stay version-agnostic until the 0.3.0 bump task.
- `opensst.db` is a regular file (repo-add creates a symlink; git cannot use it) and holds exactly one `opensst` entry (repo-add deletes same-name entries; multi-version dbs are invalid).
- RPM repodata compression is pinned `--compress-type=gz` (zstd unreadable by older dnf4).
- No signatures anywhere; opt-in flags: apt `[trusted=yes]`, dnf `gpgcheck=0`, pacman `SigLevel = Never`. The no-warning guarantee is CI-enforced (stderr assertions).
- Site is latest-only; `gh-pages` gets exactly one orphan commit per release, force-pushed; the workflow never touches repository settings (Pages activation is a one-time manual maintainer step).
- Script exit codes: 0 success, 2 validation error, 127 missing tool.
- `sst update` and `install.sh` behavior is unchanged.
- Site URL base: `https://opensst.github.io/opensst` (repo `opensst/opensst`).

## Review Focus

- **Missing family package in dist-dir** → script must fail (exit 2) before writing anything into the site directory; a partial tree must never exist. Pinned in Task 1.
- **Re-running a family into a site-dir that already has that family's stale files** → files are replaced within the family subdirectory only; other families' subdirectories are untouched. Pinned in Task 1.
- **`opensst.db` committed as a symlink** → pacman on a fresh clone gets a broken db; test asserts `-f` and `! -L`. Pinned in Task 2.
- **repo-add sibling artifacts (`opensst.files*`, `opensst.db.tar.gz`, `*.old`) left in the site** → committed garbage; test asserts the arch directory contains exactly the package and `opensst.db`. Pinned in Task 2.
- **CI consumption smoke test emits a warning on stderr** (unsigned-repo warnings) → test must fail, per the maintainer's no-warning acceptance condition. Pinned in Tasks 6–7.
- **Release job pushes a multi-commit or non-orphan `gh-pages`** → branch history grows; the job asserts `git rev-list --count gh-pages` = 1 before pushing. Pinned in Task 8.

---

### Task 1: `site-build.sh` CLI validation skeleton

**Files:**
- Create: `packaging/site-build.sh` (mode 0755)
- Test: `tests/run.bash` (new function `test_site_build_validation`, called in the invocation list near line 1535)

**Interfaces:**
- Produces: `packaging/site-build.sh <family> <version> <dist-dir> <site-dir>` with `<family>` ∈ `deb|rpm|arch`; exit 0/2/127. Validation runs before any filesystem writes. Family subdirectories `<site>/<family>/` are created lazily by each family's generator (later tasks); validation must not create them.

- [ ] **Step 1: Write the failing test**

`test_site_build_validation` (no tools needed, runs everywhere): with `version` extracted dynamically from `bin/sst`, `dist` containing only the arch package (build via `packaging/build-arch.sh`, skip-gate identically to `test_arch_package`), and empty `site`:

- bad family (`foo`), bad version format (`0x2`), version not matching `SST_VERSION`, missing dist dir, missing arch package file, wrong arg count → each: `STATUS` 2, `stderr` non-empty, site dir still has **no** `arch/` subdirectory ("no partial writes").
- valid invocation with the arch family only reaches "repo-add missing" behavior later; for this task, the script may exit 127 when repo-add is absent (assert 127 and clean stderr message naming repo-add) or 0 when present — assert only that exit is 0 or 127 and no site subdirectory was created by validation itself.
- second call of the arch family into a `site/arch/` pre-populated with a stale file (`printf stale > site/arch/leftover`) → the stale file is removed or overwritten by the generator (Task 2 pins which); for this task assert the call does not touch `site/deb/` or `site/rpm/` when they contain sentinel files.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.bash`
Expected: FAIL — `site-build.sh` does not exist.

- [ ] **Step 3: Implement the skeleton in `packaging/site-build.sh`**

`set -euo pipefail`; usage message on stderr; validation order: arg count → family name in `deb|rpm|arch` → version regex `^[0-9]+\.[0-9]+\.[0-9]+$` → dist dir exists → `SST_VERSION` match (same sed extraction as `packaging/build-arch.sh:13`) → family package file exists (`opensst_<v>_all.deb` / `opensst-<v>-1.noarch.rpm` / `opensst-<v>-1-any.pkg.tar.zst`) → `bash <dist>/sst --version` reports `sst <v>` when the raw asset is present, else skip that probe (CI smoke provides real packages; unit tests may not have `dist/sst`). Dispatch stubs per family (exit 127 "tool missing" placeholders) to be filled by Tasks 2–4.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.bash`
Expected: PASS with the new assertions.

- [ ] **Step 5: Commit**

```bash
git add packaging/site-build.sh tests/run.bash
git commit -m "feat: add site-build.sh validation skeleton"
```

### Task 2: arch family generator

**Files:**
- Modify: `packaging/site-build.sh` (arch branch)
- Test: `tests/run.bash` (new `test_site_build_arch`, skip-gated on `repo-add` and non-root)

**Interfaces:**
- Consumes: Task 1 skeleton.
- Produces: `<site>/arch/` containing exactly `opensst-<v>-1-any.pkg.tar.zst` and `opensst.db` (regular file); `opensst.db` has exactly one `opensst` entry at `<v>-1`.

- [ ] **Step 1: Write the failing test**

Build a real package via `packaging/build-arch.sh` (as `test_arch_package` does), run `site-build.sh arch`, then:

- `site/arch/opensst.db` is a regular file: `[[ -f db && ! -L db ]]`.
- Directory listing of `site/arch` contains exactly the package and `opensst.db` (no `.files`, no `.db.tar.gz`, no `.old`).
- `bsdtar -xOf site/arch/opensst.db opensst-<v>-1/desc` contains `%FILENAME%` → package filename and `%VERSION%` → `<v>-1`; contains exactly one `desc` entry (`bsdtar -tf` filtered by `/desc` count = 1).
- Re-run into the same site dir with a stale `site/arch/leftover` removed and the db/package replaced; `site/deb`/`site/rpm` sentinels untouched (carried from Task 1, now against the real generator).

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.bash`
Expected: FAIL — arch branch is a 127 stub.

- [ ] **Step 3: Implement the arch branch**

Copy the package into `site/arch/` (atomic: copy to temp name, `mv`). Run `repo-add` in `mktemp -d` against the copied package (`repo-add "$tmp/opensst.db.tar.gz" "$tmp/<pkg>"`), then replace the symlink `opensst.db` with the real file (`rm` the symlink, `mv`/`cp` the tarball to `opensst.db`), and copy only `opensst.db` into `site/arch/`. Delete the temp dir via the existing `trap` pattern. Gate: `command -v repo-add` else exit 127 naming repo-add.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.bash`
Expected: PASS (on the maintainer's Arch box, repo-add present).

- [ ] **Step 5: Commit**

```bash
git add packaging/site-build.sh tests/run.bash
git commit -m "feat: site-build.sh generates the arch repository"
```

### Task 3: deb family generator

**Files:**
- Modify: `packaging/site-build.sh` (deb branch)
- Test: `tests/run.bash` (new `test_site_build_deb`, skip-gated on `dpkg-deb` + `dpkg-scanpackages` + `apt-ftparchive`; runs on ubuntu CI, skips on the Arch box)

**Interfaces:**
- Produces: `<site>/deb/` containing the deb, `Packages`, `Packages.gz`, `Release`.

- [ ] **Step 1: Write the failing test**

Build a real deb via `packaging/build-deb.sh` (skip-gate as `test_deb_package`), run `site-build.sh deb`, then:

- `site/deb/Packages` contains `Package: opensst`, `Filename: opensst_<v>_all.deb`, and a `SHA256:` line matching `sha256sum` of the package file.
- `Packages.gz` gunzips to the same content.
- `Release` exists and contains `Origin:`/`Suite:`-style fields written by `apt-ftparchive release`.
- Rerun idempotence: second invocation succeeds and leaves the same set of files.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.bash`
Expected: SKIP on Arch (missing tools) — verify failure on an ubuntu runner or via `docker run ubuntu:latest` with dpkg-dev/apt-utils installed; locally assert the skip message prints.

- [ ] **Step 3: Implement the deb branch**

Copy the deb into `site/deb/` atomically. `cd site/deb && dpkg-scanpackages --multivalue . > Packages` (pipe through `gzip -9 -c > Packages.gz`), then `apt-ftparchive release . > Release`. Gate the three tools; exit 127 naming them. Note in a comment: flat repo, `Filename:` relative to the base, no `pool/` layout (spec non-goal).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.bash` (ubuntu CI test job after Task 7 installs tools; locally expect the skip message).
Expected: PASS on ubuntu, clean skip on Arch.

- [ ] **Step 5: Commit**

```bash
git add packaging/site-build.sh tests/run.bash
git commit -m "feat: site-build.sh generates the flat apt repository"
```

### Task 4: rpm family generator + shared index/nojekyll writing

**Files:**
- Modify: `packaging/site-build.sh` (rpm branch, shared epilogue)
- Create: `packaging/site-index.html` (template)
- Test: `tests/run.bash` (new `test_site_build_rpm`, skip-gated on `rpmbuild` + `createrepo_c`; new `test_site_index`, runs everywhere)

**Interfaces:**
- Produces: `<site>/rpm/` containing the rpm and `repodata/` (gzip-compressed); every successful invocation writes `<site>/.nojekyll` and `<site>/index.html` (from `packaging/site-index.html` with `{{VERSION}}` substituted).
- Template contract: `packaging/site-index.html` contains the literal `{{VERSION}}` once and the three config snippets from the spec (exact `Server`/`baseurl`/`deb` lines).

- [ ] **Step 1: Write the failing tests**

`test_site_build_rpm`: build a real rpm via `packaging/build-rpm.sh` (skip-gate as `test_rpm_package`), run `site-build.sh rpm`, then: `site/rpm/repodata/repomd.xml` exists; the primary metadata file it references (parse `repomd.xml` for the `primary` data href, follow `repodata/` path, gunzip if needed) contains `name="opensst"` and `pkgversion`; no `*.xml.zst` files exist under `repodata/` (gzip pinned).
`test_site_index`: after any family invocation (use arch or the validation-only path if all tools missing — in that case invoke the epilogue indirectly: run the script with a valid family and expect 127, but assert `.nojekyll` and `index.html` are **not** written on failure), assert: on success `index.html` contains `{{VERSION}}`-substituted value, `SigLevel = Never`, `trusted=yes`, `gpgcheck=0`, and `https://opensst.github.io/opensst`; `.nojekyll` exists and is empty.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.bash`
Expected: FAIL — rpm branch is a stub; no template exists.

- [ ] **Step 3: Implement the rpm branch, epilogue, and template**

Rpm: copy the rpm into `site/rpm/` atomically; `createrepo_c --compress-type=gz site/rpm` (tool-gated, exit 127 naming createrepo_c). Epilogue (runs only on overall success, after the family generator): `printf '' > site/.nojekyll`; `sed "s/{{VERSION}}/$version/g" packaging/site-index.html > site/index.html`. Template: static HTML with the spec's three snippets, a plain-language trust-model note ("not signed; transport is HTTPS; verify against the release page SHA256SUMS; bytes are identical"), the support floor (apt ≥ 1.5, dnf4, pacman ≥ 6), and a link to the GitHub releases page.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.bash`
Expected: PASS where tools exist, clean skips otherwise.

- [ ] **Step 5: Commit**

```bash
git add packaging/site-build.sh packaging/site-index.html tests/run.bash
git commit -m "feat: site-build.sh generates the dnf repository and site index"
```

### Task 5: test harness filter for targeted CI runs

**Files:**
- Modify: `tests/run.bash` (invocation list, ~line 1535)

**Interfaces:**
- Produces: env `SST_TESTS_FILTER=<regex>` — when set, only test functions whose names match run (the summary still prints; non-matching tests are skipped with a `# skip` line). Used by Task 6's arch job step.

- [ ] **Step 1: Write the failing test**

Add `test_harness_filter`: run `SST_TESTS_FILTER='^test_documentation$' bash tests/run.bash` in a subshell; assert its combined output contains `README documents` (the filtered test ran) and does not contain `ok` lines from other tests; and the exit status is 0.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.bash`
Expected: FAIL — no filter support.

- [ ] **Step 3: Implement the filter**

Convert the direct invocations at the bottom into a list: for each `test_*` function, if `SST_TESTS_FILTER` is set and the name does not match, print `# skip <name>: SST_TESTS_FILTER` and continue; else call it. Keep the existing order and final summary intact.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.bash`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/run.bash
git commit -m "feat: run.bash supports SST_TESTS_FILTER for targeted runs"
```

### Task 6: CI — arch container repo consumption smoke

**Files:**
- Modify: `.github/workflows/ci.yml` (arch job, after the existing install smoke)

**Interfaces:**
- Consumes: `site-build.sh arch` (Task 2), `SST_TESTS_FILTER` (Task 5).

- [ ] **Step 1: Add the steps**

Two new steps in the arch job: (a) as the `builder` user: `site-build.sh arch "$VERSION" dist site` then `SST_TESTS_FILTER='^test_site_build_arch$' bash tests/run.bash` (repo-add exists in the container; runs as non-root, matching local constraints); (b) as root: temp `pacman.conf` with `[opensst]` `Server = file://<abs>/site/arch` `SigLevel = Never`, then `pacman -Sy --config … --dbpath … --cachedir …` and `pacman -S --noconfirm --assume-installed bash --assume-installed openssh --assume-installed curl --config … --dbpath … --cachedir … opensst` with stderr captured to a file; fail the step if the stderr file is non-empty after filtering pacman's routine progress lines (assert no warnings); then `sst --version` reports the embedded version.

- [ ] **Step 2: Verify locally what is verifiable**

The container steps run only in CI; locally verify the step's script fragment syntax: `bash -n` on the extracted script. Full verification happens on the next CI run.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: pacman repository consumption smoke test"
```

### Task 7: CI — ubuntu test job tools + apt/dnf consumption smokes

**Files:**
- Modify: `.github/workflows/ci.yml` (test job install step; deb job; rpm job)

**Interfaces:**
- Consumes: Tasks 3, 4 generators.

- [ ] **Step 1: Test job installs index tools**

In the `test` job, before `make check`: `sudo apt-get update && sudo apt-get install -y dpkg-dev apt-utils createrepo-c rpm` (`rpm` provides `rpmbuild` for building the test rpm; `createrepo_c` binary ships in the `createrepo-c` package). This makes `test_site_build_deb` and `test_site_build_rpm` actually run in CI.

- [ ] **Step 2: DEB job repo smoke**

After the existing DEB install smoke: `site-build.sh deb "$VERSION" dist site`; write `deb [trusted=yes] file://<abs>/site/deb ./` to a temp sources file under `/etc/apt/sources.list.d/` (job is already privileged); `apt-get update 2>err.log`, `apt-get install -y opensst 2>>err.log` — fail if `err.log` contains `^W:` or `^E:` (no-warning assertion); `sst --version`; remove the temp source.

- [ ] **Step 3: RPM job repo smoke (fedora container)**

The existing RPM smoke runs `docker run fedora:latest`. Add a second `docker run` that mounts `dist` and `site`: inside, `createrepo_c` is available in fedora base? No — install it: `dnf install -y createrepo_c` inside the container, run `site-build.sh rpm` (mount the repo checkout read-only, build site in a writable mounted dir), then `dnf --repofrompath=opensst,file://<abs>/site/rpm --setopt=opensst.gpgcheck=0 install -y opensst` with stderr asserted warning-free (filter `^Warning:`), then `sst --version`.

- [ ] **Step 4: Verify workflow syntax**

Run: `bash -n` fragments; or push to a branch and watch CI (full verification is CI-only).
Expected: YAML parses; CI green on next run.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: apt and dnf repository consumption smoke tests"
```

### Task 8: Release workflow `publish-site` job

**Files:**
- Modify: `.github/workflows/release.yml` (new job after `package-arch`)

**Interfaces:**
- Consumes: `site-build.sh` (all families), artifacts `opensst-deb`, `opensst-rpm`, `opensst-arch`.

- [ ] **Step 1: Add the job**

`publish-site` (ubuntu-latest, `needs: release` — the site is the upgrade channel for a **published** release and must never advertise a version whose Release failed to publish; the `release` job already needs the three package jobs, so artifacts flow transitively; `permissions: contents: write`, `env: VERSION`, `GH_TOKEN`): checkout; download the three artifacts into `dist/` (`pattern: opensst-*`, `merge-multiple: true`); install `dpkg-dev apt-utils createrepo-c`; run `site-build.sh deb` and `site-build.sh rpm` natively; run `site-build.sh arch` via `docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work" -w /work archlinux:latest packaging/site-build.sh arch "$VERSION" dist site`; then publish the orphan commit from a **fresh repository initialized inside `site/`** (pinned mechanism — cannot inherit history from the main checkout by construction): `cd site && git init -b gh-pages && git add -A && git commit -m "opensst $VERSION" && git rev-list --count HEAD` must equal 1 (assert, fail otherwise), then `git push -f "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" gh-pages`. A re-dispatch rebuilds and force-pushes again; that is the designed, safe mechanism (the `release` job still leaves an existing GitHub Release untouched).

- [ ] **Step 2: Self-check the orphan-commit mechanics**

Run the commit fragment locally in a scratch clone in `/tmp/opencode` against a dummy site dir: after push to a temp remote (`git init --bare`), `git rev-list --count` on the remote branch is 1, and a second run replaces (still 1 commit, different sha). This pins the mechanism without touching the real repository.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: publish-site job force-pushes the gh-pages repository"
```

### Task 9: Documentation

**Files:**
- Modify: `README.md`, `AGENTS.md`
- Test: `tests/run.bash` (`test_documentation` needle lists)

**Interfaces:**
- Consumes: final CLI and URLs (all tasks above).

- [ ] **Step 1: Write the failing needles**

Extend `test_documentation`: README gains needles `opensst.github.io/opensst`, `deb [trusted=yes]`, `baseurl=https://opensst.github.io/opensst/rpm`, `SigLevel = Never`, `not signed`, `byte-identical`, `sst update`, `Upgrades via your system package manager`; AGENTS.md gains `site-build.sh`, `gh-pages`, `orphan`, `Pages activation`, `latest-only`, `publish-site`. (Exact list may be adjusted to final wording; needles pin the concepts.)

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash`
Expected: FAIL on the new needles.

- [ ] **Step 3: Write the docs**

README: new "Upgrades via your system package manager" section after Installation — the three snippets, trust-model note (unsigned, HTTPS, byte-identical, SHA256SUMS link), support floor, Arch foreign-package side effect, `sst update` interplay, latest-only/downgrade note. Installation section gains one sentence pointing at the new section (repo config is the optional upgrade channel, not a second install method). AGENTS.md: layout table adds `packaging/site-build.sh` and `packaging/site-index.html`; packaging rules replace the self-hosted-repository prohibition with the revised invariant (GitHub Release assets = install contract; gh-pages static site = upgrade channel; no external hosts/mirrors/signing keys; latest-only; orphan single commit); release process gains the publish-site step, the one-time manual Pages activation step, and retry semantics; CI description gains the three consumption smokes; Version History **row not added yet** (release-time, next task).

- [ ] **Step 4: Run tests**

Run: `bash tests/run.bash`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md tests/run.bash
git commit -m "docs: document the gh-pages upgrade repository"
```

### Task 10: Version bump to 0.3.0 (release preparation — explicit authorization granted)

**Files:**
- Modify: `bin/sst` (`SST_VERSION`), `README.md` (version examples), `tests/run.bash` (hardcoded `0.2.1` expectations), `AGENTS.md` (Version History row)

**Interfaces:**
- Consumes: maintainer approval of 0.3.0 (given).

- [ ] **Step 1: Bump**

`SST_VERSION='0.3.0'` in `bin/sst`; update every `0.2.1` literal in `tests/run.bash` and `README.md` examples to `0.3.0`; add the Version History row (date: release day, changes: gh-pages repository for apt/dnf/pacman upgrades, latest-only, orphan-branch publishing). New site tests keep working unchanged (dynamic version).

- [ ] **Step 2: Full verification**

Run: `make check`
Expected: PASS, no skips other than reported missing local tools.

- [ ] **Step 3: Commit (with maintainer authorization for release-prep changes; push and Release dispatch remain explicit maintainer actions per AGENTS.md)**

```bash
git add bin/sst README.md AGENTS.md tests/run.bash
git commit -m "chore: prepare 0.3.0 (gh-pages repository release)"
```
