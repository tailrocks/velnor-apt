# Feed coverage proof and known gaps (B2)

The old `NO_WORKFLOWS_REQUIRED.md` Class-C omission is gone: the generator
at pin `048a7bda` (product `velnor-workflow-runtime-v1-32565cc6272a84d4`,
closure-identical to velnor main `19811e71`) ships typed APT feed primitives,
and every omitted workflow below has a generated replacement in this tree. This file is the file-by-file
proof, the verify-path proof against live inputs, and the two remaining
precise generator defects (signed publication lacks the GPG key import;
tag auto-resolve drops `ls-remote` from its argv).

## Replacement proof (omitted → generated)

| Omitted workflow | Generated replacement | Proof |
| --- | --- | --- |
| `ci.yml` (static aggregate, `ci-required`) | `ci-pr.yml` + `ci-main.yml` (generated aggregates) | Both render a `ci-required` job; the ruleset-required context is produced again. |
| `ci-apt.yml` (verify lanes + contract gate) | `release.yml` `verify` job | Fetches source assets, verifies attestations (`ci-release-package-signer.yml`, tag ref + commit), runs `apt-verify` per suite, uploads verified inputs. Nothing mutates. |
| `publish.yml` (verify → reprepro → sign → deploy) | `release.yml` `publish` + `deploy` + `feed-result` jobs | Prior-pair recovery, `apt-publish` (assemble + sign + record), `apt-channel-update`, rollback deploy guard, Pages deploy, fail-closed result. **Except signing: see gap.** |
| `package-update.yml` (channel dispatcher) | `release.yml` `channel`/`version`/`commit` dispatch inputs + schedule | Both suites handled in one workflow; empty version/commit auto-resolves the channel head. |
| `package-updater.yml` (verify + mutate lanes, state PRs) | verify-before-mutate inside `release.yml` + `apt-channel-update` | No more state-PR churn: `package-state.json` / `package-state-preview.json` (schema `velnor.apt-package-state.v1`) are emitted into the served tree. |
| `renovate.yml` (scheduled writer) | `renovate.yml` + `renovate-validate.yml` | Writer runs on github-hosted (no trusted Velnor writer label is declared), skips with a notice until `GH_RENOVATE_TOKEN` is provisioned; config validated on PR. |
| Composite actions (`aggregate`, `cache-contract`, `run-gate`) | Eliminated by design | Generated steps invoke the pinned `velnor-workflow` product binary + SHA-pinned external actions; no local actions exist or are referenced. |

## Remaining gaps (three precise B1 defects)

### 1. Signed publication cannot complete: no GPG key import

The old `publish.yml` step "Import and validate publisher key" (see
`7978284^:.github/workflows/publish.yml`) piped `secrets.APT_GPG_PRIVATE_KEY`
into `gpg --batch --import` and then required the imported private signer to
agree with the committed public `velnor.gpg` before any signing. The generated
`release.yml` has no equivalent: the publish job exports only the
`APT_GPG_PASSPHRASE` environment secret, and `apt-publish` signs with
`gpg --local-user <signer>`, which fails closed with "No secret key" because
nothing imports the secret key into the job keyring.

Consequences:

- The verify path works end to end today: dispatching `Package feed` on any
  ref proves coherence without mutation (publish/deploy skip off `main`).
- A scheduled or dispatched publish on `main` currently fails even earlier,
  at defect 3 below (missing `incoming/…` sidecar in prior recovery) — before
  any assembly or signing. Once defect 3 is fixed, signing (this defect) is
  the next fail-closed stop. The live feed and Pages deployment are untouched
  in all cases.
- This blocks STEP B4 (signed APT publication through the generated flow),
  not the verify/CI/renovate coverage landed here.

Fix direction (generator owner, velnor side): a typed key-secret contract
(`key_secret` name + import step + private-vs-committed-public agreement
check) in `render_apt_release`, with generator unit tests proving a publish
without the import fails before signing and a publish with it signs. That
changes the generator closure, so it ships as a new runtime product + a new
pin — never a hand-edit of `release.yml`.

Secrets already present for that fix: `APT_GPG_PRIVATE_KEY`,
`APT_GPG_PASSPHRASE` (repository secrets). Required environment
`package-feed` exists (no reviewers).

### 2. Tag auto-resolve never works: `ls-remote` dropped from argv

`apt-resolve-commit` (used by the verify job when the `commit` dispatch input
is empty, i.e. on every scheduled run) always fails with "could not resolve":
`run_resolve_commit` calls `run_fixed("git", &argv[1..], …)`, which drops the
`ls-remote` subcommand and executes `git <url> <ref>` ("not a git command").
Present since the original B1 commit; recovery did not introduce it.

Workaround (typed, no generator change): dispatch with an explicit `commit`
(the workflow's `commit` input bypasses resolution entirely). The scheduled
path stays broken until the generator fix: pass the full argv (`&argv`, like
every other `run_fixed`/`run_in` caller), plus a live-`ls-remote` test that
would have caught the dropped subcommand — the existing argv unit test asserts
the vector, never the executed command.

### 3. Publish/deploy reference artifact paths the v4 download never restores

The verify job uploads `path: incoming` (artifact `apt-incoming`) and the
publish job downloads it with `path: .`, then references
`incoming/release-record.json.sha256` — but the v4 download restores the
files without the `incoming/` prefix, so prior recovery fails with
`awk: fatal: cannot open file 'incoming/release-record.json.sha256'`.
Proven live: dispatch `35280645007` (stable, `v0.1.274`, explicit commit)
went Verify success → Publish failure at exactly that line, Deploy skipped,
Feed result fail-closed. The deploy job carries the identical broken pattern
(upload `path: public`, download `path: .`, reference `public/…`).

Fix direction (generator): download each artifact into its expected directory
(`path: incoming` / `path: public`) instead of `path: .`, or reference the
flattened layout — plus a layout assertion test. Like defects 1–2, the fix
changes the generator closure and ships as a new product + pin.

## Verify-path proof (B2, live inputs, verified product binary)

Exact `release.yml` verify-job command sequence against the live
`tailrocks/velnor` `v0.1.274` release, with explicit commit
`120f223655587ab0bcf2530cd4b203e0375a9dca` (which independent
`git ls-remote` confirms as the peeled tag target, matching the committed
`package-state.json` source commit):

- `apt-fetch --suite stable … --version v0.1.274`: 8/8 coherence inputs
  (record + sidecar, manifest + sidecar, both deb + sidecar pairs).
- `gh attestation verify` on both debs: 1 attestation each, signer
  `tailrocks/velnor/.github/workflows/ci-release-package-signer.yml`,
  `--source-ref refs/tags/v0.1.274`, `--source-digest 120f2236…`.
- Live fingerprint read from committed `velnor.gpg` equals the pinned
  signer `7E66E3A53F9B3B5CA61D0F53261EDAC957DEB801`.
- `apt-verify … --verify-oci true`: "stable feed inputs are coherent"
  (record/manifest/deb/identity/live-OCI-index checks all pass).

The same sequence also passes inside CI: dispatch `35280645007` on main
(runner `github`, channel `stable`, version `v0.1.274`, explicit commit)
completed Admit success → **Verify apt feed success** ("stable feed inputs
are coherent" in the job log, `apt-incoming` uploaded) → Publish failure
(defect 3, fail-closed) → Deploy skipped → Feed result fail-closed. Policy
dispatch `35280641908` on main completed Policy success (11/11).
