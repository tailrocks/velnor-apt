# Feed coverage proof and known gaps (B2, re-proven W4)

The old `NO_WORKFLOWS_REQUIRED.md` Class-C omission is gone: the generator
at pin `4dec6b9e` (product `velnor-workflow-runtime-v1-1394e1960cdf0265`,
schema 2, G1 apt port) ships typed APT feed primitives, and every omitted
workflow below has a generated replacement in this tree. This file is the
file-by-file proof, the verify-path proof against live inputs, and the
disposition of the three B2 generator defects (all fixed: signed
publication imports the GPG key with an agreement check; tag auto-resolve
passes the full `ls-remote` argv; artifacts download into `incoming/` and
`public/`).

## Replacement proof (omitted → generated)

| Omitted workflow | Generated replacement | Proof |
| --- | --- | --- |
| `ci.yml` (static aggregate, `ci-required`) | `ci-pr.yml` + `ci-main.yml` (generated aggregates) | Both render a `ci-required` job; the ruleset-required context is produced again. |
| `ci-apt.yml` (verify lanes + contract gate) | `release.yml` `verify` job | Fetches source assets, verifies attestations (`ci-release-package-signer.yml`, tag ref + commit), runs `apt-verify` per suite, uploads verified inputs. Nothing mutates. |
| `publish.yml` (verify → reprepro → sign → deploy) | `release.yml` `publish` + `deploy` + `feed-result` jobs | Prior-pair recovery, `apt-publish` (key import + agreement, assemble + sign + record), `apt-channel-update`, rollback deploy guard, Pages deploy, fail-closed result. |
| `package-update.yml` (channel dispatcher) | `release.yml` `channel`/`version`/`commit` dispatch inputs + schedule | Both suites handled in one workflow; empty version/commit auto-resolves the channel head. |
| `package-updater.yml` (verify + mutate lanes, state PRs) | verify-before-mutate inside `release.yml` + `apt-channel-update` | No more state-PR churn: `package-state.json` / `package-state-preview.json` (schema `velnor.apt-package-state.v1`) are emitted into the served tree. |
| `renovate.yml` (scheduled writer) | DEFERRED at W4 (see below) | s2 validation requires the velnor provider for the writer, unsatisfiable on public repos; re-add once the generator admits a hosted writer. |
| Composite actions (`aggregate`, `cache-contract`, `run-gate`) | Eliminated by design | Generated steps invoke the pinned `velnor-workflow` product binary + SHA-pinned external actions; no local actions exist or are referenced. |

Secrets present: `APT_GPG_PRIVATE_KEY`, `APT_GPG_PASSPHRASE`
(repository secrets). Required environment `package-feed` exists (no
reviewers).

## Fixed defects (B2 → G1, all closed)

### 1. Signed publication imports the key and proves agreement (was: no GPG key import)

The generated `release.yml` publish job exports both secrets and
`apt-publish` imports the private key, then requires the imported
private signer to agree with the committed public `velnor.gpg`
(`agree_imported_key`) before any signing. A publish without the import
fails before signing.

### 2. Tag auto-resolve passes the full argv (was: `ls-remote` dropped)

`run_resolve_commit` passes the full argv (`&argv`, like every other
`run_fixed`/`run_in` caller), and a fake-git test asserts the executed
command line. Scheduled runs (empty `commit` input) resolve again; the
explicit-`commit` workaround is no longer needed.

### 3. Artifacts download into their expected directories (was: v4 layout mismatch)

The verify job uploads `path: incoming` and publish downloads with
`path: incoming` (likewise `path: public` for the staged tree), so prior
recovery finds `incoming/release-record.json.sha256` where it expects it.

## Verify-path proof (W4, s2 tree, read-only)

Dispatch `35631756757` (`stable`, `v0.1.274`, explicit commit
`120f223655587ab0bcf2530cd4b203e0375a9dca`) on the W4 branch
(`rollout/velnor-wave`, s2 tree at pin `4dec6b9e`):
Admit gone by design (no runner lanes under inc3) → **Verify apt feed
success** ("stable feed inputs are coherent" in the job log,
`apt-incoming` uploaded with the hidden sentinel) → Publish skipped
(off `main`) → Deploy skipped → **Feed result success**. No mutation:
publish/deploy skip off the default branch by construction.

- Run: https://github.com/tailrocks/velnor-apt/actions/runs/35631756757
- The verify sequence is unchanged from B2: `apt-fetch` 8/8 coherence
  inputs, `gh attestation verify` on both debs (signer
  `tailrocks/velnor/.github/workflows/ci-release-package-signer.yml`,
  `--source-ref refs/tags/v0.1.274`, `--source-digest 120f2236…`), live
  fingerprint read from committed `velnor.gpg` equals the pinned signer
  `7E66E3A53F9B3B5CA61D0F53261EDAC957DEB801`, `apt-verify
  --verify-oci true` coherent.
- No publish dispatch was run: the proof procedure requires verify only,
  and publication stays on the normal release mechanism (scheduled runs
  on `main` publish new upstream versions; nothing here publishes).

## Verify-path proof (B2, historical, v1 tree)

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

The same sequence also passed inside CI: dispatch `35280645007` on main
(runner `github`, channel `stable`, version `v0.1.274`, explicit commit)
completed Admit success → **Verify apt feed success** ("stable feed inputs
are coherent" in the job log, `apt-incoming` uploaded) → Publish failure
(defect 3, fail-closed) → Deploy skipped → Feed result fail-closed. Policy
dispatch `35280641908` on main completed Policy success (11/11).
