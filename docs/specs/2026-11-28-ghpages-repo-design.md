# GitHub Pages Package Repository Design

Date: 2026-11-28
Status: Approved by the maintainer with conditions (no-warning
guarantee enforced by CI assertions; installation docs kept consistent;
`sst update` retained — rationale in Decisions). Target release: 0.3.0.
Supersedes the release-asset-only pacman design drafted earlier the
same day.

## Intent

Publish one static package-repository site on GitHub Pages (a `gh-pages`
branch of this repository) that serves DEB, RPM, and pacman repositories
for opensst, so users of all three families receive upgrades through
their system package manager (`apt upgrade`, `dnf upgrade`,
`pacman -Syu`). GitHub Release assets remain the installation contract
(`install.sh`, `SHA256SUMS`); the Pages site is the upgrade channel.
A side effect on Arch: once `opensst` is served from a sync database it
stops being a foreign package, silencing the AUR-helper "not in AUR"
warning.

## Why now

- AUR account registration has been closed since 2026-08-01 (second
  closure, still active), blocking AUR publication indefinitely.
- Arch users install via one-shot `pacman -U` and upgrade only via
  `sst update`; DEB/RPM users are in the same position. None are in the
  normal system upgrade flow.
- A single static site can carry all three repository formats with zero
  external infrastructure, zero cost, and no new trust root.

## Goals

- All three families can install once and upgrade forever via their
  system package manager.
- One hosting surface: a `gh-pages` branch, pushed by the existing
  Release workflow. No external host, no mirrors, no signing keys.
- The site always serves exactly the latest release. Downgrades keep
  the existing path: versioned assets on the release page
  (`pacman -U`, `dpkg -i`, `dnf install <url>`), unchanged from today.
- Package bytes on the site are byte-identical to the same version's
  Release assets (same CI artifacts), so the release page `SHA256SUMS`
  verifies them too.
- All offline local tests keep passing without root, network, or real
  hosts; CI exercises real `apt`/`dnf`/`pacman` consumption in
  containers.

## Non-goals

- No GPG signing of any repository metadata. Rationale unchanged: no
  out-of-band public-key distribution channel exists, so signatures
  would be decoration. The trust model is HTTPS transport + the GitHub
  account as publisher, identical to `install.sh`'s documented model
  ("checksums are integrity only; the trust root is the GitHub release
  channel"). Users opt in explicitly per repository:
  apt `[trusted=yes]`, dnf `gpgcheck=0`, pacman `SigLevel = Never`.
- No `pool/`+`dists/` apt archive layout; a flat apt repository is
  sufficient for one package.
- No architecture split: all artifacts are `all`/`noarch`/`any`, so the
  pacman repository has no `$arch` tier.
- No `opensst.files` pacman database (only `pacman -Fy` requests it).
- No changes to `sst update` or `install.sh` behavior (see Decisions).
- No custom domain, no CDN, no analytics.

## Approaches considered

1. **Release-asset pacman database only** (the superseded design):
   `repo-add` output uploaded as a Release asset, served via
   `releases/latest/download`. Zero new surface but covers only Arch,
   serves only the latest version, and depends on redirect behavior.
   Replaced by the user's direction to serve all three families.
2. **archlinuxcn submission** — pacman-only, human approval, covers only
   archlinuxcn users. Remains a possible parallel track; unaffected by
   this design.
3. **GitHub Pages multi-format repository (chosen)** — one static site,
   three formats, always the latest release only, published as a
   **single orphan commit** (maintainer requirements: the branch never
   accumulates git history, and no stale packages are kept). Costs:
   three index generators in CI, a `gh-pages` branch to maintain, and a
   broader revision of the AGENTS.md hosting invariant.

## Site layout (gh-pages branch)

```text
/
├── deb/                              flat apt repository
│   ├── Packages, Packages.gz         dpkg-scanpackages output
│   ├── Release                       apt-ftparchive release output
│   └── opensst_0.3.0_all.deb
├── rpm/                              dnf repository
│   ├── repodata/                     createrepo_c output (gzip)
│   │   └── repomd.xml, *.xml.gz
│   └── opensst-0.3.0-1.noarch.rpm
├── arch/                             pacman repository
│   ├── opensst.db                    repo-add database (latest only)
│   └── opensst-0.3.0-1-any.pkg.tar.zst
└── index.html                        one static page: what this is,
                                      the three config snippets, and a
                                      link to the release page for
                                      checksums
```

Plus a `.nojekyll` marker at the root so GitHub Pages serves the tree
verbatim. The whole tree is regenerated on every release from that
release's artifacts; only the latest version is ever present.

User configuration (also shown on `index.html` and in README):

```ini
# /etc/apt/sources.list.d/opensst.list
deb [trusted=yes] https://opensst.github.io/opensst/deb ./
```

```ini
# /etc/yum.repos.d/opensst.repo
[opensst]
baseurl=https://opensst.github.io/opensst/rpm
gpgcheck=0
```

```ini
# /etc/pacman.conf
[opensst]
Server = https://opensst.github.io/opensst/arch
SigLevel = Never
```

Verified facts this rests on (pacman 7.1.0, local experiments and the
builder check of the superseded design):

- pacman requests exactly `opensst.db` (never `.db.tar.gz`; `.files`
  only via `-Fy`), follows 302 redirects, fetches packages by the
  `%FILENAME%` recorded in the database, honors per-repository
  `SigLevel = Never` overriding a global `Required`, and `repo-add`
  runs fine as non-root.
- `repo-add` produces `opensst.db` as a **symlink** to
  `opensst.db.tar.gz`; committing to git requires materializing it as a
  regular file.
- `repo-add` **deletes the existing same-name entry on every add** and
  a pacman sync database can hold only one entry per package name;
  hand-merging multiple versions makes pacman report "database is
  inconsistent". A latest-only single-entry database is therefore not a
  compromise — it is the only correct pacman form, and it matches the
  maintainer's latest-only requirement exactly.
- The database embeds each package's SHA-256 (`%SHA256SUM%`), so
  pacman verifies package downloads from the repository without any
  signing.
- apt flat repositories and `dnf`/`createrepo_c` repositories are
  standard, widely used layouts; CI smoke tests verify them for real.

## New script: `packaging/site-build.sh`

`packaging/site-build.sh <family> <version> <dist-dir> <site-dir>` with
`<family>` ∈ `deb | rpm | arch`:

- Per-family invocation is deliberate: CI's per-family smoke tests have
  only one family's package on disk, and the release workflow's pacman
  generator runs inside an Arch container while apt/RPM generators run
  natively on ubuntu. Each invocation validates only its own family's
  versioned package file (existence, `sst --version` match, `SST_VERSION`
  match) and touches only its own subdirectory.
- `<site-dir>` may be created empty by the caller or already contain
  other families' subdirectories; the script never removes anything
  outside its own subdirectory. The site is a generated artifact, never
  hand-edited.
- `deb`: copy the deb into `deb/`, then `dpkg-scanpackages` (multivolume
  flat) + `apt-ftparchive release` over `deb/`.
- `rpm`: copy the rpm into `rpm/`, then `createrepo_c --compress-type=gz`
  over `rpm/` (gzip pinned explicitly: zstd repodata is unreadable by
  older dnf4/clients).
- `arch`: copy the package into `arch/`, run `repo-add` in a temp
  directory, materialize `opensst.db` as a regular file (repo-add
  creates a symlink; git cannot commit one usefully), and delete the
  `opensst.db.tar.gz`, `opensst.files*`, and `*.old` artifacts repo-add
  also emits.
- Every invocation also (re)writes `.nojekyll` and `index.html` from the
  repository template `packaging/site-index.html` (idempotent overwrite).
- Each family is skip-gated when its tool is missing (exit 127 with a
  clear message): `dpkg-scanpackages`+`apt-ftparchive`, `createrepo_c`,
  `repo-add` respectively.
- No byte-determinism is claimed or required: index formats embed
  timestamps and file mtimes (verified), and every release force-pushes
  a fresh orphan commit anyway. Correctness comes from per-release
  regeneration, not reproducibility.

## Release workflow (`.github/workflows/release.yml`)

Existing jobs unchanged: `validate`, `test`, `package-deb`,
`package-rpm`, `package-arch` (each builds and smoke-tests its package
and uploads its artifact). New work:

- New job `publish-site` (needs the three package jobs; ubuntu-latest,
  `contents: write`):
  1. download the three artifacts into `dist/`;
  2. install ubuntu tooling: `apt-get install -y dpkg-dev apt-utils
     createrepo-c` (correct package names; `apt-ftparchive` lives in
     `apt-utils`);
  3. run `site-build.sh deb …` and `site-build.sh rpm …` natively;
  4. run `site-build.sh arch …` inside
     `docker run -u "$(id -u):$(id -g)" archlinux:latest` with the
     workspace mounted (repo-add only exists with pacman; `-u` keeps
     the runner user as file owner so later steps are not blocked by
     root-owned files);
  5. create one orphan commit and force-push it as `gh-pages`:
     `git checkout --orphan gh-pages`, a single commit
     "opensst <version>", `git push -f origin gh-pages`. Every release
     replaces the branch with exactly one commit, so git history never
     grows (maintainer requirement). A retry rebuilds and force-pushes
     again; that is the designed mechanism, safe by construction.
- **GitHub Pages activation is a one-time manual maintainer step**
  (Settings → Pages → deploy from branch `gh-pages`, root), performed
  before the first release that ships the site. This keeps the
  repository-settings change under explicit maintainer authorization,
  as AGENTS.md requires; the workflow never touches repository
  settings.
- The existing `release` job (Release assets, `SHA256SUMS`, tag) is
  unchanged and remains the installation contract. `publish-site`
  `needs: release` (serial after it): the site is the upgrade channel
  for a published release and must never advertise a version whose
  Release failed to publish — otherwise the "site bytes are verifiable
  against the release page SHA256SUMS" guarantee would dangle. On
  re-dispatch the `release` job leaves an existing Release unchanged
  and succeeds, so the site job still runs.
- Failure handling: if the site push fails, the job fails loudly. A
  `gh-pages` branch is not a published GitHub Release; re-dispatching
  the workflow is safe and does **not** violate the "never replace a
  published Release" invariant (the release job itself leaves an
  existing Release untouched; the site job just rebuilds the branch).
  Site repair with no new version due = re-dispatch the same version:
  the package jobs rebuild, the site is regenerated and force-pushed.

## CI (`.github/workflows/ci.yml`)

Each family's smoke test generates that family's site subdirectory with
`site-build.sh <family> …` and installs from it via local paths, so no
test contacts GitHub (or any mirror) for the repository itself:

- **pacman** (arch container, root, existing job): build package →
  `site-build.sh arch …` → `pacman -Sy` with a temp config/dbpath →
  `pacman -S --noconfirm --assume-installed bash --assume-installed
  openssh --assume-installed curl opensst` → `sst --version`. The
  `--assume-installed` flags are load-bearing (verified: an empty
  dbpath cannot resolve even installed dependencies) and keep the test
  independent of Arch mirrors.
- **apt** (ubuntu runner, existing DEB job): build deb →
  `site-build.sh deb …` → `apt-get update` against a
  `deb [trusted=yes] file://<abs>/site/deb ./` source →
  `apt-get install opensst` → `sst --version`.
- **dnf** (fedora container, existing RPM job): build rpm →
  `site-build.sh rpm …` → `dnf
  --repofrompath=opensst,file://<abs>/site/rpm
  --setopt=opensst.gpgcheck=0 install opensst` → `sst --version`.
- Every family's smoke test captures stderr and **fails on any
  warning**: the unsigned opt-in flags must be silent, not merely
  functional (maintainer acceptance condition).
- The ubuntu `test` job (`make check`) installs `dpkg-dev apt-utils
  createrepo-c` so the apt/RPM offline tests actually run instead of
  skipping; the pacman family's script test runs inside the Arch
  container job as the non-root builder user (repo-add works as
  non-root, verified). Without this, the new tests would be
  skip-gated on every runner (the maintainer's Arch box has only
  `repo-add`).

## Tests (`tests/run.bash`, offline, non-root)

Skip-gated per missing tool (`repo-add`, `dpkg-scanpackages`,
`apt-ftparchive`, `createrepo_c`), mirroring the existing makepkg
pattern:

- pacman database: exactly one `opensst` entry — the latest version —
  with correct `pkgver`/`%FILENAME%` (unpack the db tarball and read
  `desc`); `opensst.db` is a regular file, not a symlink.
- apt: `Packages` lists exactly the one deb with matching SHA-256 and
  `Filename` fields.
- rpm: `repodata/repomd.xml` exists and references primary metadata
  that lists `opensst`.
- `site-build.sh` rejects version mismatch with `bin/sst SST_VERSION`
  and rejects its family's package file when absent from `<dist-dir>`.
- No test contacts a network host or installs anything.

## Decisions

- **install.sh does not modify apt/dnf/pacman configuration.** Piping
  into `bash` leaves no stdin for confirmation; writing
  `trusted=yes`/`gpgcheck=0`/`SigLevel = Never` into system files is a
  trust decision the user must make knowingly; users of all three
  families expect to own their package-manager configuration; and the
  installer's job is installation, not future-update policy. README and
  the site's `index.html` carry the snippets. Revisit only if users ask
  for an explicit opt-in flag.
- **No signatures anywhere.** Same rationale as `install.sh`'s
  documented trust model; the site adds an indirection, not a new trust
  root. `index.html` and README state this plainly and link to the
  release page `SHA256SUMS` for out-of-band verification (bytes are
  identical). **No-warning guarantee, enforced**: each family's
  opt-in flag is the mechanism designed for unsigned sources
  (verified: pacman `SigLevel = Never` syncs silently on pacman 7.1.0;
  apt `[trusted=yes]` suppresses unsigned-repository warnings by
  documented semantics; dnf `gpgcheck=0` is silent), and every CI
  smoke test asserts stderr is free of warnings — a warning is a test
  failure, not an accepted annoyance.
- **`sst update` stays.** Source installs (`/usr/local/bin`) are
  covered by no repository at all; users who installed via
  `install.sh` without adding repository configuration keep upgrading
  through it; and it coexists with the site — a repo user already at
  the latest version makes `sst update` a no-op, and an upgrade
  through either channel installs the same bytes. Removing it would
  strand two classes of users for zero simplification.
- **Latest version only, orphan single commit.** The site always serves
  exactly the latest release; the `gh-pages` branch is force-replaced
  by one orphan commit per release (maintainer requirements). Old
  packages are not archived on the site; downgrades use the versioned
  Release assets, unchanged from today. On pacman this is also the only
  correct form (a sync database holds one entry per name).
- **Release assets remain the install contract.** `install.sh`, pinned
  `--version` installs, and `SHA256SUMS` are unchanged. The site is
  purely an upgrade channel. `sst update` keeps working for all users
  and installs the same bytes.
- **AGENTS.md invariant revision (maintainer decision; this document is
  the proposal).** The packaging rule
  "Do not maintain a self-hosted apt/dnf/pacman repository in this
  project. Packages are GitHub Release assets with SHA256SUMS." is
  revised to: no repository hosting outside GitHub is maintained; the
  only hosting surfaces are GitHub Release assets (install contract)
  and the `gh-pages` branch of this repository (static repository site
  for apt/dnf/pacman). No external hosts, no mirrors, no signing keys.
  Package files on the site are byte-identical to the same version's
  Release assets and covered by the same `SHA256SUMS`.
- **archlinuxcn** submission remains possible in parallel and is not
  blocked by this design.

## Risks

- **Three index toolchains in CI** (dpkg-dev, createrepo_c, arch
  container repo-add): each is standard, but the release workflow
  becomes the place where all three must succeed. Mitigated by CI
  smoke tests per family and loud failure with safe retry.
- **GitHub Pages availability/latency**: deploys take a minute and the
  CDN caches with `max-age=600`, so an upgrade can lag the release by
  ~10 minutes; outages affect upgrades, not installs (Release assets) —
  the install path has no new dependency.
- **Support floor**: apt ≥ 1.5 (`[trusted=yes]` syntax), dnf4-era
  clients (gzip repodata, pinned explicitly), pacman ≥ 6 (repo-add
  database format). RHEL 7 yum and older apt are out of scope; the
  README states the supported matrix.
- **China network reachability**: github.io is no better than
  github.com; archlinuxcn mirrors (parallel track) cover that audience.
- **apt `trusted=yes` and dnf `gpgcheck=0` optics**: cautious users may
  object to unsigned repositories. The docs state the trust model
  honestly; users who dislike it keep using `install.sh` + `sst update`.

## Documentation changes

- README: new "Upgrades via your system package manager" section with
  the three snippets, the trust-model note, the no-warning guarantee,
  the byte-identical guarantee, the foreign-package side effect (Arch),
  and the `sst update` interplay. The existing Installation section
  must stay consistent with it: one install method each, and the repo
  config is presented as the optional upgrade channel, not a second
  install method.
- AGENTS.md: layout table (`site-build.sh`, `site-index.html`),
  packaging rules (revised invariant above, site layout, latest-only
  policy), release process (publish-site job, one-time manual Pages
  activation step, retry semantics), CI description.
- Version History row for 0.3.0 and version-specific README examples at
  release time, plus `tests/run.bash` version expectations.
