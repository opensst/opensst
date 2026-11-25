# OpenSST Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit `sst update` support that detects DEB, RPM, pacman, or source installations, downloads the matching latest stable release asset, verifies its SHA-256 checksum, and upgrades without breaking package ownership.

**Architecture:** Extend the single Bash executable with a local update subsystem: version constants and comparison, installation detection via package-owner queries, HTTPS release-asset download through `curl`/`wget`, checksum verification, and method-specific apply functions. Publish stable asset aliases (`sst`, `opensst.deb`, `opensst.rpm`, `opensst.pkg.tar.zst`, `SHA256SUMS`) from the existing manual release workflow. Tests use fake download tools, fake package managers, fake `sudo`, and temporary directories only.

**Tech Stack:** Bash, OpenSSH, curl/wget, sha256sum, dpkg/dpkg-deb, rpm/rpmbuild, pacman/makepkg, GNU Make, GitHub Actions.

**Spec:** `docs/specs/2026-11-25-opensst-update-design.md`

## Global Constraints

- Runtime remains `bin/sst`; the installed command remains `sst`.
- `SST_VERSION` is a stable `MAJOR.MINOR.PATCH` string and must equal the release workflow input.
- Release asset aliases are exactly `sst`, `opensst.deb`, `opensst.rpm`, `opensst.pkg.tar.zst`, and `SHA256SUMS`.
- Downloads use `https://github.com/opensst/opensst/releases/latest/download/<asset>`.
- Updates are explicit only: no background checks, no update on other commands.
- No signatures, Sigstore, or attestations. SHA-256 is integrity only.
- Package-owned files are never overwritten directly; DEB uses `dpkg`, RPM uses `rpm`, Arch uses `pacman`.
- Unknown installations, foreign package owners, unowned `/usr/bin/sst`, and Git-tracked source files are refused.
- Source replacement is atomic, preserves mode `0755`, and restores the old file if the new file fails `--version`.
- `curl` is a hard dependency of DEB/RPM/Arch packages; source installs may use `curl` or `wget`.
- Tests must never contact a real network host, a real package database, or a real installation.
- Existing `open`/`list`/`kill`, reconnect, SSH validation, and package ownership behavior must not regress.
- No commit, push, tag, Release, or metadata change without explicit authorization.

## Review Focus

1. **Foreign or unowned package path:** an executable owned by another package, or an unowned `/usr/bin/sst`, must be refused with exit 2 and must never be overwritten.
2. **Git-tracked source path:** running `sst update` from a development checkout must refuse rather than dirty the working tree.
3. **Checksum failure:** a bad or missing `SHA256SUMS` entry must exit 1 before any package-manager or file replacement runs.
4. **Non-interactive apply:** `sst update` without a terminal and without `--yes` must exit 2 before invoking `sudo`.
5. **Package claims success but version does not change:** post-install version verification must fail with exit 1 instead of reporting success.

Each line has a test in the task that owns the code.

---

### Task 1: Version Surface

**Files:**
- Modify: `bin/sst:1-23` (header, usage)
- Modify: `bin/sst:208-223` (dispatch)
- Test: `tests/run.bash` (`test_help`, new `test_version`)

**Interfaces:**
- Consumes: nothing.
- Produces: `SST_VERSION`; `_sst_cmd_version()`.

- [ ] **Step 1: Write the failing test**

Add near `test_help`:

```bash
test_version() {
  run_capture "$SST" --version
  assert_eq "$STATUS" 0 "sst --version exits 0"
  assert_eq "$OUTPUT" "sst 0.1.0" "sst --version prints the embedded version"

  run_capture "$SST" --help
  assert_contains "$OUTPUT" "sst --version" "help documents --version"
}
```

Call `test_version` after `test_help`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: failures for `--version` exiting non-zero and missing help text.

- [ ] **Step 3: Implement `SST_VERSION` and `_sst_cmd_version`**

Add after `set -u`:

```bash
SST_VERSION='0.1.0'
```

Add:

```bash
_sst_cmd_version() {
  printf 'sst %s\n' "$SST_VERSION"
}
```

Add `sst --version` to `_sst_usage`, and dispatch `-V|--version` to `_sst_cmd_version`.

- [ ] **Step 4: Run the full suite**

Run: `make check`

Expected: all tests pass; no syntax errors.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash
git commit -m "feat: add sst version output"
```

---

### Task 2: Version Comparison and Asset Mapping

**Files:**
- Modify: `bin/sst` (new helpers near `_sst_valid_project`)
- Test: `tests/run.bash` (new `test_version_helpers`)

**Interfaces:**
- Consumes: `SST_VERSION`.
- Produces:
  - `_sst_normalize_version <raw>` prints `MAJOR.MINOR.PATCH` or returns 1.
  - `_sst_version_cmp <left> <right>` prints `lt`, `eq`, or `gt`; returns 1 on invalid input.
  - `_sst_asset_for_method <method>` prints the stable asset name; returns 1 for unknown methods.

- [ ] **Step 1: Write failing tests**

```bash
test_version_helpers() {
  run_sourced _sst_normalize_version '1:0.1.0-2'
  assert_eq "$STATUS" 0 "epoch and package release are normalized"
  assert_eq "$OUTPUT" "0.1.0" "normalized version keeps three components"

  run_sourced _sst_normalize_version '0.1.0-rc1'
  assert_eq "$STATUS" 1 "prerelease versions are rejected"

  run_sourced _sst_normalize_version '0.1'
  assert_eq "$STATUS" 1 "short versions are rejected"

  run_sourced _sst_version_cmp 0.1.0 0.1.1
  assert_eq "$OUTPUT" lt "older version compares lt"

  run_sourced _sst_version_cmp 0.1.0 0.1.0
  assert_eq "$OUTPUT" eq "equal versions compare eq"

  run_sourced _sst_version_cmp 0.2.0 0.1.9
  assert_eq "$OUTPUT" gt "newer version compares gt"

  for pair in 'deb opensst.deb' 'rpm opensst.rpm' 'pacman opensst.pkg.tar.zst' 'source sst'; do
    set -- $pair
    run_sourced _sst_asset_for_method "$1"
    assert_eq "$OUTPUT" "$2" "asset for $1"
  done

  run_sourced _sst_asset_for_method unknown
  assert_eq "$STATUS" 1 "unknown update method has no asset"
}
```

Call `test_version_helpers` after `test_version`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: failures for undefined helpers.

- [ ] **Step 3: Implement the helpers**

Rules:
- Strip one leading numeric epoch: `1:0.1.0` → `0.1.0`.
- Strip only a trailing numeric package release: `0.1.0-2` → `0.1.0`.
- Reject anything that is not exactly three numeric components.
- Compare major, then minor, then patch numerically.

- [ ] **Step 4: Run the full suite**

Run: `make check`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash
git commit -m "feat: add update version helpers"
```

---

### Task 3: Update Fixtures and Installation Detection

**Files:**
- Create: `tests/fixtures/bin/dpkg-query`
- Create: `tests/fixtures/bin/rpm`
- Create: `tests/fixtures/bin/pacman`
- Create: `tests/fixtures/bin/sudo`
- Modify: `bin/sst`
- Test: `tests/run.bash` (new `test_update_detection`)

**Interfaces:**
- Consumes: `_sst_self_path` from this task.
- Produces:
  - `_sst_self_path [candidate]` prints an absolute resolved path; returns 1 if it cannot resolve.
  - `_sst_source_eligible <absolute-exe>` returns 0 for an allowed source path, 1 otherwise; sets `_SST_DETECT_ERROR`.
  - `_sst_detect_install <absolute-exe>` prints `deb`, `rpm`, `pacman`, or `source`; sets `_SST_DETECT_ERROR` and returns 1 on refusal.

Fake-tool contract:
- `dpkg-query -S <path>`: if `FAKE_DPKG_OWNER` is non-empty, print `<owner>: <path>`; otherwise exit 1. Multiple owners are simulated with `FAKE_DPKG_MULTI=1`, printing two lines.
- `rpm -qf <path>`: if `FAKE_RPM_OWNER` is non-empty, print it; otherwise exit 1.
- `pacman -Qqo <path>`: if `FAKE_PACMAN_OWNER` is non-empty, print it; otherwise exit 1.
- `sudo`: append `$*` to `$FAKE_SUDO_LOG`; if `FAKE_SUDO_FAIL=1`, exit 1; otherwise `exec "$@"`.

- [ ] **Step 1: Write failing detection tests**

```bash
test_update_detection() {
  local exe="$TMP/detect/sst"
  mkdir -p "$(dirname "$exe")"
  cp "$SST" "$exe"
  chmod +x "$exe"

  run_sourced _sst_self_path "$exe"
  assert_eq "$STATUS" 0 "self path resolves"
  assert_eq "$OUTPUT" "$exe" "self path is absolute"

  run_sourced _sst_detect_install "$exe"
  assert_eq "$STATUS" 0 "writable untracked source install is detected"
  assert_eq "$OUTPUT" source "source method is reported"

  FAKE_DPKG_OWNER=opensst run_sourced _sst_detect_install "$exe"
  assert_eq "$OUTPUT" deb "DEB owner is detected"

  FAKE_RPM_OWNER=opensst run_sourced _sst_detect_install "$exe"
  assert_eq "$OUTPUT" rpm "RPM owner is detected"

  FAKE_PACMAN_OWNER=opensst run_sourced _sst_detect_install "$exe"
  assert_eq "$OUTPUT" pacman "pacman owner is detected"

  FAKE_DPKG_OWNER=otherpkg run_sourced _sst_detect_install "$exe"
  assert_eq "$STATUS" 1 "foreign package owner is refused"
  assert_contains "$_SST_DETECT_ERROR" "otherpkg" "foreign owner is named"

  FAKE_DPKG_MULTI=1 run_sourced _sst_detect_install "$exe"
  assert_eq "$STATUS" 1 "multiple owners are refused"

  run_sourced _sst_source_eligible /usr/bin/sst
  assert_eq "$STATUS" 1 "unowned /usr/bin path is refused"
}
```

Add a Git-tracked test in a temporary repository, skipped when `git` is absent:

```bash
  if command -v git >/dev/null 2>&1; then
    local repo="$TMP/tracked-repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    cp "$SST" "$repo/sst"
    chmod +x "$repo/sst"
    git -C "$repo" add sst
    run_sourced _sst_detect_install "$repo/sst"
    assert_eq "$STATUS" 1 "Git-tracked source file is refused"
  else
    printf '# skip Git-tracked source test: git is unavailable\n'
  fi
```

Call `test_update_detection` after `test_update_version_helpers`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: failures for missing helpers/fixtures.

- [ ] **Step 3: Create fixtures and implement detection**

Implement `_sst_self_path`:
- Use the optional candidate, else `$0`.
- If it has no `/`, resolve with `command -v`.
- Resolve symlinks with `readlink -f`.
- Return 1 if empty or unresolvable.

Implement `_sst_source_eligible`:
- Require a regular executable file named `sst`.
- Refuse paths under `/usr/bin/`.
- If `git` is available, resolve the worktree top level and refuse if `git ls-files --error-unmatch` finds the file.
- Allow when the parent directory is writable by the current user.
- Allow paths under `/usr/local/` (they will use `sudo`).
- Refuse everything else.

Implement `_sst_detect_install`:
- Query DEB, then RPM, then pacman, in that order.
- A definitive owner other than `opensst`, or multiple owners, sets an error and returns 1.
- If no package owns the path, run the source check.

- [ ] **Step 4: Run the full suite**

Run: `make check`

Expected: pass; the Git test may be skipped only when `git` is missing.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash tests/fixtures/bin/dpkg-query \
  tests/fixtures/bin/rpm tests/fixtures/bin/pacman tests/fixtures/bin/sudo
git commit -m "feat: detect sst installation method"
```

---

### Task 4: Installed and Asset Version Readers

**Files:**
- Create: `tests/fixtures/bin/dpkg-deb`
- Modify: `bin/sst`
- Test: `tests/run.bash` (new `test_update_version_readers`)

**Interfaces:**
- Consumes: `_sst_normalize_version`.
- Produces:
  - `_sst_installed_version <method> <exe>` prints the raw installed version; sets `_SST_VERSION_ERROR` and returns 1 on failure.
  - `_sst_asset_version <method> <file>` prints the raw asset version; sets `_SST_VERSION_ERROR` and returns 1 on failure.

Fake-tool contract:
- `dpkg-query -W -f='${Version}' opensst`: print `$FAKE_DPKG_INSTALLED_VERSION`.
- `dpkg-deb -f <file> Version`: print `$FAKE_DPKG_ASSET_VERSION`.
- `rpm -q --qf '%{VERSION}' opensst`: print `$FAKE_RPM_INSTALLED_VERSION`.
- `rpm -qp --qf '%{VERSION}' <file>`: print `$FAKE_RPM_ASSET_VERSION`.
- `pacman -Q opensst`: print `opensst <FAKE_PACMAN_INSTALLED_VERSION>`.
- `pacman -Qip <file>`: print a block with `Version : <FAKE_PACMAN_ASSET_VERSION>`.

- [ ] **Step 1: Write failing reader tests**

```bash
test_update_version_readers() {
  local exe="$TMP/readers/sst" file="$TMP/readers/asset"
  mkdir -p "$(dirname "$exe")"
  cp "$SST" "$exe"
  printf 'x\n' >"$file"

  FAKE_DPKG_INSTALLED_VERSION=0.1.0 run_sourced _sst_installed_version deb "$exe"
  assert_eq "$OUTPUT" 0.1.0 "DEB installed version"
  FAKE_DPKG_ASSET_VERSION=0.1.1 run_sourced _sst_asset_version deb "$file"
  assert_eq "$OUTPUT" 0.1.1 "DEB asset version"

  FAKE_RPM_INSTALLED_VERSION=0.1.0 run_sourced _sst_installed_version rpm "$exe"
  assert_eq "$OUTPUT" 0.1.0 "RPM installed version"
  FAKE_RPM_ASSET_VERSION=0.1.1 run_sourced _sst_asset_version rpm "$file"
  assert_eq "$OUTPUT" 0.1.1 "RPM asset version"

  FAKE_PACMAN_INSTALLED_VERSION=0.1.0-1 run_sourced _sst_installed_version pacman "$exe"
  assert_eq "$OUTPUT" 0.1.0-1 "pacman installed version"
  FAKE_PACMAN_ASSET_VERSION=0.1.1-1 run_sourced _sst_asset_version pacman "$file"
  assert_eq "$OUTPUT" 0.1.1-1 "pacman asset version"

  run_sourced _sst_installed_version source "$exe"
  assert_eq "$OUTPUT" 0.1.0 "source installed version"

  printf "SST_VERSION='0.1.1'\n" >"$file"
  run_sourced _sst_asset_version source "$file"
  assert_eq "$OUTPUT" 0.1.1 "source asset version"

  printf '#!/bin/bash\n' >"$file"
  run_sourced _sst_asset_version source "$file"
  assert_eq "$STATUS" 1 "source asset without version is rejected"
}
```

Call `test_update_version_readers` after `test_update_detection`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: failures for missing functions.

- [ ] **Step 3: Implement the readers**

Use the exact commands from the fake-tool contract:
- DEB installed: `dpkg-query -W -f='${Version}' opensst`
- RPM installed: `rpm -q --qf '%{VERSION}' opensst`
- pacman installed: `pacman -Q opensst` and take field 2
- DEB asset: `dpkg-deb -f <file> Version`
- RPM asset: `rpm -qp --qf '%{VERSION}' <file>`
- pacman asset: `pacman -Qip <file>` and parse the `Version` line
- source: parse `^SST_VERSION='...'` with `sed`

Every failure sets a message in `_SST_VERSION_ERROR` and returns 1.

- [ ] **Step 4: Run the full suite**

Run: `make check`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash tests/fixtures/bin/dpkg-deb
git commit -m "feat: read installed and release versions"
```

---

### Task 5: Download and Checksum Verification

**Files:**
- Create: `tests/fixtures/bin/curl`
- Create: `tests/fixtures/bin/wget`
- Modify: `bin/sst`
- Test: `tests/run.bash` (new `test_update_download`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `_sst_download <url> <dest>` returns 0 on success, 1 on network failure, 127 when no downloader exists; sets `_SST_DOWNLOAD_ERROR`.
  - `_sst_verify_sha256 <file> <sums-file> <asset-name>` returns 0 on match, 1 on mismatch/missing/duplicate; sets `_SST_VERIFY_ERROR`.

Fake-tool contract:
- `curl`: parse the argument after `-o` as destination and the last argument as URL. Append `$*` to `$FAKE_CURL_LOG`. If `FAKE_CURL_FAIL_ASSET` equals the URL basename, exit 22. Copy `$FAKE_CURL_DIR/<basename>` to the destination; exit 22 if missing.
- `wget`: parse the argument after `-O` as destination and the last argument as URL. Same copy/failure behavior with `FAKE_WGET_FAIL_ASSET`.
- Use `#!/bin/bash` shebangs so a restricted `PATH` test still works.

- [ ] **Step 1: Write failing download/checksum tests**

```bash
test_update_download() {
  local dir="$TMP/download" asset="$TMP/download/sst" sums="$TMP/download/SHA256SUMS"
  mkdir -p "$dir"
  printf "SST_VERSION='0.1.1'\n" >"$asset"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  FAKE_CURL_DIR="$dir" run_sourced _sst_download https://example.invalid/sst "$TMP/fetched"
  assert_eq "$STATUS" 0 "curl download succeeds"

  FAKE_CURL_FAIL_ASSET=sst run_sourced _sst_download https://example.invalid/sst "$TMP/failed"
  assert_eq "$STATUS" 1 "download failure is reported"

  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 0 "matching checksum is accepted"

  printf 'x\n' >"$asset"
  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 1 "mismatched checksum is rejected"

  run_sourced _sst_verify_sha256 "$asset" "$sums" missing
  assert_eq "$STATUS" 1 "missing checksum entry is rejected"

  printf 'deadbeef  sst\n' >"$sums"
  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 1 "malformed checksum is rejected"

  printf '%s  sst\n%s  sst\n' "$(sha256sum "$asset" | cut -d' ' -f1)" \
    "$(sha256sum "$asset" | cut -d' ' -f1)" >"$sums"
  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 1 "duplicate checksum entries are rejected"

  (
    PATH=/nonexistent
    # shellcheck disable=SC1090
    source "$SST"
    _sst_download https://example.invalid/sst "$TMP/none"
  ) >/dev/null 2>&1
  STATUS=$?
  assert_eq "$STATUS" 127 "missing downloader returns 127"
}
```

Add a wget-fallback test in a restricted `PATH` containing only the fake `wget`:

```bash
  local only="$TMP/wget-only"
  mkdir -p "$only"
  cp "$FAKEBIN/wget" "$only/wget"
  (
    PATH="$only"
    # shellcheck disable=SC1090
    source "$SST"
    FAKE_WGET_DIR="$dir" _sst_download https://example.invalid/sst "$TMP/wget-fetched"
  )
  STATUS=$?
  assert_eq "$STATUS" 0 "wget fallback succeeds when curl is absent"
```

Call `test_update_download` after `test_update_version_readers`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: failures for missing functions.

- [ ] **Step 3: Implement the downloader and checksum verifier**

`_sst_download`:
- `curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 120 -o <dest> <url>`
- Else `wget -q --tries=2 --timeout=120 -O <dest> <url>`
- Else set `_SST_DOWNLOAD_ERROR='curl or wget is required for sst update'` and return 127.

`_sst_verify_sha256`:
- Require `sha256sum`.
- Parse the sums file for exactly one entry whose filename equals `<asset-name>`, accepting an optional leading `*`.
- Require a 64-hex digest.
- Compute the file digest and compare.
- Missing `sha256sum` returns 127.

- [ ] **Step 4: Run the full suite**

Run: `make check`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/sst tests/run.bash tests/fixtures/bin/curl tests/fixtures/bin/wget
git commit -m "feat: add update download and checksum helpers"
```

---

### Task 6: Update Check, Confirmation, and Source Apply

**Files:**
- Modify: `bin/sst` (new update command, source apply, help)
- Modify: `bin/sst` (dispatch)
- Test: `tests/run.bash` (new `test_update_check`, `test_update_source`, `test_update_interaction`)

**Interfaces:**
- Consumes: `_sst_self_path`, `_sst_detect_install`, `_sst_asset_for_method`, `_sst_download`, `_sst_verify_sha256`, `_sst_installed_version`, `_sst_asset_version`, `_sst_normalize_version`, `_sst_version_cmp`.
- Produces:
  - `_sst_fetch_release <method> <tmpdir>` sets `_SST_ASSET_FILE` and `_SST_LATEST_VERSION`; sets `_SST_UPDATE_ERROR` and returns 1 on failure.
  - `_sst_confirm_update <current> <latest> <method>` returns 0 for yes, 1 for no.
  - `_sst_apply_source <asset-file> <exe> <user|sudo>` returns 0 or 1; sets `_SST_APPLY_ERROR`.
  - `_sst_cmd_update [--check|--yes]` is wired to the `update` subcommand.

- [ ] **Step 1: Write failing check tests**

Create a helper in `tests/run.bash`:

```bash
run_update() {
  local self="$TMP/update-self/sst"
  mkdir -p "$(dirname "$self")"
  cp "$SST" "$self"
  chmod +x "$self"
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  env PATH="$FAKEBIN:$PATH" \
    FAKE_SSH_LOG="${FAKE_SSH_LOG-}" \
    FAKE_SSH_G_LOG="${FAKE_SSH_G_LOG-}" \
    FAKE_CURL_DIR="${FAKE_CURL_DIR-}" \
    FAKE_CURL_FAIL_ASSET="${FAKE_CURL_FAIL_ASSET-}" \
    FAKE_CURL_LOG="${FAKE_CURL_LOG-}" \
    FAKE_WGET_DIR="${FAKE_WGET_DIR-}" \
    FAKE_WGET_FAIL_ASSET="${FAKE_WGET_FAIL_ASSET-}" \
    FAKE_DPKG_OWNER="${FAKE_DPKG_OWNER-}" \
    FAKE_DPKG_MULTI="${FAKE_DPKG_MULTI-}" \
    FAKE_DPKG_INSTALLED_VERSION="${FAKE_DPKG_INSTALLED_VERSION-}" \
    FAKE_DPKG_ASSET_VERSION="${FAKE_DPKG_ASSET_VERSION-}" \
    FAKE_RPM_OWNER="${FAKE_RPM_OWNER-}" \
    FAKE_RPM_INSTALLED_VERSION="${FAKE_RPM_INSTALLED_VERSION-}" \
    FAKE_RPM_ASSET_VERSION="${FAKE_RPM_ASSET_VERSION-}" \
    FAKE_PACMAN_OWNER="${FAKE_PACMAN_OWNER-}" \
    FAKE_PACMAN_INSTALLED_VERSION="${FAKE_PACMAN_INSTALLED_VERSION-}" \
    FAKE_PACMAN_ASSET_VERSION="${FAKE_PACMAN_ASSET_VERSION-}" \
    FAKE_PKG_STATE="${FAKE_PKG_STATE-}" \
    FAKE_PKG_ASSET_VERSION="${FAKE_PKG_ASSET_VERSION-}" \
    FAKE_PKG_FAIL="${FAKE_PKG_FAIL-}" \
    FAKE_SUDO_LOG="$TMP/sudo.log" \
    FAKE_SUDO_FAIL="${FAKE_SUDO_FAIL-}" \
    "$self" "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}
```

Add tests:

```bash
test_update_check() {
  local dir="$TMP/release-check"
  mkdir -p "$dir"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  FAKE_CURL_DIR="$dir" run_update update --check
  assert_eq "$STATUS" 0 "source update check exits 0"
  assert_contains "$OUTPUT" "installed 0.1.0" "check reports installed version"
  assert_contains "$OUTPUT" "latest 0.1.1" "check reports latest version"
  assert_contains "$OUTPUT" "update available" "check reports availability"
  assert_eq "$(cat "$TMP/update-self/sst" | grep -c "SST_VERSION='0.1.0'")" 1 \
    "check does not modify the source file"

  printf "SST_VERSION='0.1.0'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  FAKE_CURL_DIR="$dir" run_update update --check
  assert_contains "$OUTPUT" "up to date" "equal versions are up to date"

  printf "SST_VERSION='0.0.9'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  FAKE_CURL_DIR="$dir" run_update update --check
  assert_eq "$STATUS" 0 "newer installed version is not a failure"
  assert_contains "$OUTPUT" "no downgrade" "newer installed version refuses downgrade"

  printf "SST_VERSION='0.1.1'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  printf 'corrupt\n' >"$dir/sst"
  FAKE_CURL_DIR="$dir" run_update update --check
  assert_eq "$STATUS" 1 "checksum mismatch fails"
  assert_contains "$ERROR" "checksum" "checksum failure is explained"
}
```

Call `test_update_check` after `test_update_download`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: failures because `update` is unknown or returns usage errors.

- [ ] **Step 3: Implement the check path**

Implement `_sst_fetch_release`:
- Determine the asset with `_sst_asset_for_method`.
- Download `SHA256SUMS` and the asset into the temp directory.
- Verify the asset.
- Read the asset version and store it raw in `_SST_LATEST_VERSION`.
- Store the asset path in `_SST_ASSET_FILE`.

Implement `_sst_cmd_update`:
- Parse `--check` and `--yes`; reject both together and any other argument with exit 2.
- Resolve the executable and detect the method; refusal exits 2.
- Use `mktemp -d` and a trap that removes it.
- Read and normalize the installed version; failure exits 1.
- Fetch the release; failure exits 1.
- Print `sst: installed <version> (<method>)` and
  `sst: latest <version> (<method>)`.
- Compare:
  - `eq`: print `sst: <version> is up to date`; exit 0.
  - `gt` (installed newer): print `sst: installed <v> is newer than latest release <v>; no downgrade performed`; exit 0.
  - `lt`: print `sst: update available`.
- If `--check`, exit 0.
- If no `--check`, require a terminal or `--yes`; otherwise exit 2.
- For source, call `_sst_apply_source` after confirmation.
- For package methods in this task, set `_SST_APPLY_ERROR='package update is not available in this build'` and exit 1. Task 7 replaces this branch.

Add `sst update` to usage and dispatch `update`.

- [ ] **Step 4: Add source apply and confirmation tests**

```bash
test_update_source() {
  local dir="$TMP/release-source" target="$TMP/update-self/sst"
  mkdir -p "$dir"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  FAKE_CURL_DIR="$dir" run_update update --yes
  assert_eq "$STATUS" 0 "source update succeeds"
  assert_contains "$(cat "$target")" "SST_VERSION='0.1.1'" "source file is replaced"
  assert_eq "$(stat -c %a "$target")" 755 "source file keeps executable mode"

  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nexit 1\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  FAKE_CURL_DIR="$dir" run_update update --yes
  assert_eq "$STATUS" 1 "broken replacement fails sanity check"
  assert_contains "$(cat "$target")" "SST_VERSION='0.1.1'" "old source file is restored"

  local sudo_target="$TMP/sudo-source/sst" sudo_asset="$TMP/sudo-asset"
  mkdir -p "$(dirname "$sudo_target")"
  cp "$SST" "$sudo_target"
  chmod +x "$sudo_target"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$sudo_asset"
  : >"$TMP/sudo.log"
  FAKE_SUDO_LOG="$TMP/sudo.log" run_sourced \
    _sst_apply_source "$sudo_asset" "$sudo_target" sudo
  assert_eq "$STATUS" 0 "sudo source apply succeeds"
  assert_file_contains "$TMP/sudo.log" "install" "sudo source apply uses sudo install"
  assert_contains "$(cat "$sudo_target")" "SST_VERSION='0.1.1'" \
    "sudo source target is replaced"
}
```

`test_update_interaction`:
- Plain `update` without a TTY and without `--yes` exits 2 and does not create `$FAKE_SUDO_LOG`.
- `--check --yes` exits 2.
- Using `run_sst_tty` with `printf 'n\n'` or `script`, declining confirmation exits 0 and leaves the file unchanged.
- Accepting `y` applies.

- [ ] **Step 5: Run the full suite**

Run: `make check`

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add bin/sst tests/run.bash
git commit -m "feat: add update check and source upgrade"
```

---

### Task 7: Package Upgrade Apply

**Files:**
- Create: `tests/fixtures/bin/dpkg`
- Modify: `tests/fixtures/bin/dpkg-query` (state-file support)
- Modify: `tests/fixtures/bin/rpm`
- Modify: `tests/fixtures/bin/pacman`
- Modify: `bin/sst`
- Test: `tests/run.bash` (new `test_update_packages`)

**Interfaces:**
- Consumes: `_sst_fetch_release`, `_sst_confirm_update`, `_sst_normalize_version`, `_sst_version_cmp`.
- Produces:
  - `_sst_run_privileged <command...>` runs the command directly as root or through `sudo`.
  - `_sst_apply_package <method> <asset-file>` returns 0 or 1; sets `_SST_APPLY_ERROR`.
- Fake-tool state contract:
  - `FAKE_PKG_STATE` is a file containing the installed version.
  - Queries read it when set; otherwise use the `FAKE_*_INSTALLED_VERSION` fallback.
  - Installing commands write `FAKE_PKG_ASSET_VERSION` to the state file when they succeed.
  - `FAKE_PKG_FAIL=1` makes the install command exit 1 without changing the state.

- [ ] **Step 1: Write failing package tests**

```bash
test_update_packages() {
  local dir="$TMP/release-packages" state="$TMP/pkg-state"
  mkdir -p "$dir"
  printf 'dummy\n' >"$dir/opensst.deb"
  printf 'dummy\n' >"$dir/opensst.rpm"
  printf 'dummy\n' >"$dir/opensst.pkg.tar.zst"
  (cd "$dir" && sha256sum opensst.deb opensst.rpm opensst.pkg.tar.zst >SHA256SUMS)

  : >"$TMP/sudo.log"
  printf '0.1.0\n' >"$state"

  FAKE_CURL_DIR="$dir" FAKE_DPKG_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1 FAKE_DPKG_ASSET_VERSION=0.1.1 \
    run_update update --yes
  assert_eq "$STATUS" 0 "DEB update succeeds"
  assert_file_contains "$TMP/sudo.log" "dpkg -i" "DEB uses dpkg -i"
  assert_eq "$(grep -c 'dpkg -i' "$TMP/sudo.log")" 1 "DEB installs once"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_RPM_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1 FAKE_RPM_ASSET_VERSION=0.1.1 \
    run_update update --yes
  assert_eq "$STATUS" 0 "RPM update succeeds"
  assert_file_contains "$TMP/sudo.log" "rpm -Uvh" "RPM uses rpm -Uvh"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_PACMAN_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1-1 FAKE_PACMAN_ASSET_VERSION=0.1.1-1 \
    run_update update --yes
  assert_eq "$STATUS" 0 "pacman update succeeds"
  assert_file_contains "$TMP/sudo.log" "pacman -U --noconfirm" "pacman uses pacman -U"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_DPKG_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1 FAKE_DPKG_ASSET_VERSION=0.1.1 FAKE_PKG_FAIL=1 \
    run_update update --yes
  assert_eq "$STATUS" 1 "package install failure is reported"
  assert_eq "$(cat "$state")" 0.1.0 "failed install does not change state"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_DPKG_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.0 FAKE_DPKG_ASSET_VERSION=0.1.1 \
    run_update update --yes
  assert_eq "$STATUS" 1 "post-install version mismatch fails"

  if (( EUID != 0 )); then
    (
      PATH=/nonexistent
      # shellcheck disable=SC1090
      source "$SST"
      _sst_run_privileged true
    ) >/dev/null 2>&1
    STATUS=$?
    assert_eq "$STATUS" 127 "missing sudo returns 127"
  else
    printf '# skip missing sudo test: running as root\n'
  fi
}
```

Call `test_update_packages` after `test_update_source`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: package update branch is unavailable or commands are not logged.

- [ ] **Step 3: Implement `_sst_run_privileged` and `_sst_apply_package`**

- `_sst_run_privileged`: if `EUID` is 0, `"$@"`; otherwise require `sudo`, set a 127 error if absent, and run `sudo "$@"`.
- DEB: `_sst_run_privileged dpkg -i "$asset"`.
- RPM: `_sst_run_privileged rpm -Uvh "$asset"`.
- pacman: `_sst_run_privileged pacman -U --noconfirm "$asset"`.
- After the command, query the installed version and compare normalized values with the target. A mismatch or failed query sets an error and returns 1.

- [ ] **Step 4: Wire package methods into `_sst_cmd_update`**

Replace the temporary package branch with `_sst_apply_package`. Keep the confirmation and `--yes` behavior unchanged.

- [ ] **Step 5: Run the full suite**

Run: `make check`

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add bin/sst tests/run.bash tests/fixtures/bin/dpkg \
  tests/fixtures/bin/dpkg-query tests/fixtures/bin/rpm tests/fixtures/bin/pacman
git commit -m "feat: upgrade package-managed sst installs"
```

---

### Task 8: Arch Package and Release Assets

**Files:**
- Create: `packaging/build-arch.sh`
- Create: `packaging/release-assets.sh`
- Modify: `packaging/build-deb.sh`
- Modify: `packaging/build-rpm.sh`
- Modify: `Makefile`
- Test: `tests/run.bash` (new `test_arch_package`, `test_release_assets`)

**Interfaces:**
- Consumes: `bin/sst`, `SST_VERSION`, `LICENSE`.
- Produces:
  - `packaging/build-arch.sh <version> <outdir>` creates
    `<outdir>/opensst-<version>-1-any.pkg.tar.zst`.
  - `packaging/release-assets.sh <version> <distdir>` creates stable aliases
    and `SHA256SUMS`.
  - `make package-arch`.

- [ ] **Step 1: Write failing package-script tests**

Add version checks:

```bash
test_package_version_validation() {
  "$ROOT/packaging/build-deb.sh" 1.0 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 2 "deb build rejects a non-semver version"

  "$ROOT/packaging/build-rpm.sh" v1.0.0 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 2 "rpm build rejects a version with a tag prefix"

  "$ROOT/packaging/build-deb.sh" 9.9.9 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 2 "deb build rejects a version that differs from SST_VERSION"

  "$ROOT/packaging/build-rpm.sh" 9.9.9 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 2 "rpm build rejects a version that differs from SST_VERSION"

  "$ROOT/packaging/build-arch.sh" 9.9.9 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 2 "arch build rejects a version that differs from SST_VERSION"

  assert_file_contains "$ROOT/packaging/build-deb.sh" "Depends: bash, openssh-client, curl" \
    "deb metadata depends on curl"
  assert_file_contains "$ROOT/packaging/build-rpm.sh" "Requires: curl" \
    "rpm metadata requires curl"
}
```

Add Arch build test:

```bash
test_arch_package() {
  if ! command -v makepkg >/dev/null 2>&1 || ! command -v bsdtar >/dev/null 2>&1 \
    || (( EUID == 0 )); then
    printf '# skip arch package test: makepkg/bsdtar is unavailable or running as root\n'
    return
  fi
  local out="$TMP/arch"
  mkdir -p "$out"
  "$ROOT/packaging/build-arch.sh" 0.1.0 "$out" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 0 "arch package build succeeds"
  local pkg="$out/opensst-0.1.0-1-any.pkg.tar.zst"
  assert_file "$pkg" "arch package has the expected filename"
  assert_contains "$(bsdtar -xOf "$pkg" .PKGINFO)" "pkgname = opensst" "arch PKGINFO names opensst"
  assert_contains "$(bsdtar -xOf "$pkg" .PKGINFO)" "pkgver = 0.1.0-1" "arch PKGINFO records version"
  assert_contains "$(bsdtar -tf "$pkg")" "usr/bin/sst" "arch package installs /usr/bin/sst"
}
```

Add release-assets test:

```bash
test_release_assets() {
  local dist="$TMP/release-assets"
  mkdir -p "$dist"
  cp "$SST" "$dist/sst"
  chmod +x "$dist/sst"
  printf 'deb\n' >"$dist/opensst_0.1.0_all.deb"
  printf 'rpm\n' >"$dist/opensst-0.1.0-1.noarch.rpm"
  printf 'arch\n' >"$dist/opensst-0.1.0-1-any.pkg.tar.zst"

  "$ROOT/packaging/release-assets.sh" 0.1.0 "$dist" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 0 "release assets script succeeds"
  for file in opensst.deb opensst.rpm opensst.pkg.tar.zst SHA256SUMS; do
    assert_file "$dist/$file" "release assets creates $file"
  done
  assert_file_contains "$dist/SHA256SUMS" "opensst.deb" "checksums include stable DEB alias"
  assert_file_contains "$dist/SHA256SUMS" "opensst.pkg.tar.zst" "checksums include stable Arch alias"

  printf "#!/bin/bash\nSST_VERSION='9.9.9'\n" >"$dist/sst"
  chmod +x "$dist/sst"
  "$ROOT/packaging/release-assets.sh" 0.1.0 "$dist" >"$TMP/stdout" 2>"$TMP/stderr"
  assert_eq "$STATUS" 1 "release assets refuses a raw script with the wrong version"
}
```

Call `test_arch_package` and `test_release_assets` after `test_packages`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: missing scripts and unchanged version handling fail.

- [ ] **Step 3: Implement package scripts**

`build-deb.sh` and `build-rpm.sh`:
- After semver validation, parse `SST_VERSION` from `bin/sst`.
- Reject a version argument that differs.
- Add `curl` to DEB `Depends` and RPM `Requires`.

`build-arch.sh`:
- Validate semver and equality with `SST_VERSION`.
- Require `makepkg`; exit 127 if absent.
- Refuse `EUID == 0` with exit 2.
- Build in a temporary directory with a generated `PKGBUILD`:
  - `pkgname=opensst`, `pkgver=<version>`, `pkgrel=1`, `arch=(any)`,
    `license=(MIT)`, `depends=(bash openssh curl)`.
  - Install `bin/sst` to `/usr/bin/sst` and `LICENSE` to
    `/usr/share/licenses/opensst/LICENSE`.
  - Use local source files and no network.
- Copy the resulting package to `<outdir>`.

`release-assets.sh`:
- Validate the version and required files.
- Copy versioned packages to stable aliases.
- Verify `bash <dist>/sst --version` equals `sst <version>`.
- Generate `SHA256SUMS` over `sst`, the three versioned packages, and the
  three stable aliases, sorted by filename.

`Makefile`:
- Add `package-arch` to `.PHONY` and a target invoking the script.

- [ ] **Step 4: Run the full suite**

Run: `make check`

Expected: pass; Arch tests run on Arch with `makepkg` and skip when unavailable
or root.

- [ ] **Step 5: Commit**

```bash
git add packaging/build-arch.sh packaging/release-assets.sh \
  packaging/build-deb.sh packaging/build-rpm.sh Makefile tests/run.bash
git commit -m "build: add arch package and stable release assets"
```

---

### Task 9: CI and Release Workflow

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Test: `tests/run.bash` (`test_release_workflow`, new `test_ci_workflow`)

**Interfaces:**
- Consumes: `packaging/build-arch.sh`, `packaging/release-assets.sh`, `SST_VERSION`.
- Produces: an Arch package CI job, a release Arch package job, version
  validation, and stable assets in the published Release.

- [ ] **Step 1: Write failing workflow tests**

Extend `test_release_workflow` with:

```bash
  assert_file_contains "$release" "SST_VERSION" "release validates the embedded version"
  assert_file_contains "$release" "package-arch" "release builds an Arch package"
  assert_file_contains "$release" "archlinux:latest" "Arch build uses an Arch container"
  assert_file_contains "$release" "release-assets.sh" "release creates stable asset aliases"
  assert_file_contains "$release" "opensst.pkg.tar.zst" "release publishes the stable Arch alias"
```

Add a CI test:

```bash
test_ci_workflow() {
  local ci="$ROOT/.github/workflows/ci.yml"
  assert_file_contains "$ci" "package-arch" "CI builds an Arch package"
  assert_file_contains "$ci" "archlinux:latest" "CI uses an Arch container"
  assert_file_contains "$ci" "pacman -U" "CI smoke-tests the Arch package"
}
```

Call `test_ci_workflow` after `test_release_workflow`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: missing workflow content failures.

- [ ] **Step 3: Implement CI**

Add `package-arch` to `ci.yml`:
- `needs: test`
- `runs-on: ubuntu-latest`
- `container: archlinux:latest`
- Install `base-devel`.
- Create a non-root builder and make the workspace writable by it.
- Run `packaging/build-arch.sh 0.1.0 dist` as the builder.
- Run `pacman -U --noconfirm dist/opensst-0.1.0-1-any.pkg.tar.zst`.
- Run `sst --help` and `sst --version`.
- Upload `dist/*.pkg.tar.zst`.

- [ ] **Step 4: Implement release workflow**

In `validate`:
- Parse `SST_VERSION` from `bin/sst` and require it to equal `$VERSION`.

Add `package-arch`:
- `needs: test`
- Same container build and smoke test as CI.
- Upload the Arch package artifact.

In `release`:
- Add `package-arch` to `needs`.
- After downloading artifacts, copy `bin/sst` to `dist/sst`.
- Run `packaging/release-assets.sh "$VERSION" dist`.
- Upload all release assets, including `SHA256SUMS` and stable aliases.
- Keep the existing annotated-tag and Release idempotency checks.

- [ ] **Step 5: Run the full suite and parse YAML**

Run: `make check`
Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); YAML.load_file(".github/workflows/release.yml")'`

Expected: tests pass and both files parse.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml tests/run.bash
git commit -m "ci: build and publish the arch package"
```

---

### Task 10: Documentation and Help

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `bin/sst` usage text
- Test: `tests/run.bash` (`test_help`, `test_documentation`)

**Interfaces:**
- Consumes: implemented update behavior and release asset names.
- Produces: user and maintainer documentation matching the code.

- [ ] **Step 1: Write failing documentation tests**

Extend `test_help`:

```bash
  assert_contains "$OUTPUT" "sst update" "help documents update"
  assert_contains "$OUTPUT" "--check" "help documents update --check"
```

Extend `test_documentation` README needles:

```bash
    'sst update' \
    'sst update --check' \
    'opensst.pkg.tar.zst' \
    'pacman -U' \
    'curl or wget' \
    'checksums are not signatures'
```

AGENTS needles:

```bash
    'sst update' \
    'SST_VERSION' \
    'pacman' \
    'stable aliases'
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.bash 2>&1 | grep -E '^not ok|tests, .* failures'`

Expected: missing help and documentation failures.

- [ ] **Step 3: Update README**

Add:
- `--version` and update usage.
- Installation-method table.
- Arch install/uninstall commands using the release package.
- `sst update` behavior, `--check`, `--yes`, exit statuses, no downgrade.
- Requirements: `curl` or `wget`, `sha256sum`, owning package manager,
  `sudo` for system installs.
- Trust boundary: checksums are not signatures.
- Uninstall commands for source, DEB, RPM, and Arch.

- [ ] **Step 4: Update AGENTS**

Add:
- Update safety invariants.
- Package ownership rules.
- Arch package and stable release-asset rules.
- Release steps for bumping `SST_VERSION`, matching the workflow input, and
  smoke-testing Arch.

- [ ] **Step 5: Update usage text**

Add:

```text
  update  Detect the installation method and upgrade to the latest release.
  --version  Print the sst version.
```

Include `--check` and `--yes` descriptions.

- [ ] **Step 6: Run the full suite**

Run: `make check`

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add README.md AGENTS.md bin/sst tests/run.bash
git commit -m "docs: document updating sst"
```

---

### Task 11: Final Verification

**Files:**
- No planned file changes.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: fresh completion evidence.

- [ ] **Step 1: Run final local verification**

```bash
make check
bash -n bin/sst
bash -n tests/run.bash
git diff --check
git status --short
git log --oneline -12
```

Expected: all tests pass; syntax checks pass; no whitespace errors. Report
explicit skips for `dpkg-deb`, `rpmbuild`, or `makepkg` when local tools are
missing.

- [ ] **Step 2: Verify workflow syntax**

```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); YAML.load_file(".github/workflows/release.yml"); puts "workflow YAML parses"'
```

Expected: `workflow YAML parses`.

- [ ] **Step 3: Verify version consistency**

```bash
grep -n "^SST_VERSION=" bin/sst
grep -n "SST_VERSION" .github/workflows/release.yml
grep -n "SST_VERSION" packaging/build-deb.sh packaging/build-rpm.sh packaging/build-arch.sh
```

Expected: one `0.1.0` value and matching validation/build checks.

- [ ] **Step 4: Report exact evidence**

Report:
- Test counts and failures.
- Skipped local packaging tests and why.
- Which update paths are covered by fakes.
- Worktree status and any uncommitted files.
- That no tag, Release, push, or package publication happened without
  authorization.

---

## Implementation status (2026-11-25)

Tasks 1-11 are implemented, committed, and released.

- Local verification: `make check` (269 tests, 0 failures), Bash syntax checks,
  `git diff --check`, workflow YAML parsing, a local Arch package build, and a
  local `release-assets.sh` run over fixture packages.
- Commit: `61bd936` (`feat: add explicit sst update and Arch packaging`).
- CI run `45618869046` passed Test, DEB, RPM, and Arch jobs.
- Annotated tag `v0.1.0` points to `61bd936`.
- Release workflow run `45619039958` passed Validate, Test, DEB, RPM, Arch, and
  Publish jobs.
- GitHub Release `v0.1.0` publishes `sst`, `opensst.deb`, `opensst.rpm`,
  `opensst.pkg.tar.zst`, `SHA256SUMS`, and the three versioned packages.
  All assets pass `sha256sum -c`, and the stable aliases are byte-identical to
  their versioned counterparts.
- End-to-end check: the released `sst update --check` reports
  `0.1.0 is up to date` and exits 0.
