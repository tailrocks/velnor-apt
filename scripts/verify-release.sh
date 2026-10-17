#!/usr/bin/env bash
# Plan 010 — verify a velnor-runner release BEFORE reprepro.
#
# tailrocks/velnor is the source of truth. This script downloads a tag's release
# record, its independent checksum, the compiled manifest + checksum, and exactly
# the two deb/checksum pairs directly from the public source repo, resolves the
# tag commit independently, and validates the whole acyclic coherence chain:
# schema, source repo, tag, crate/debian version, resolved commit, every hash
# (record/manifest/deb), the extracted + packaged identity inside each deb, the
# OCI image ref/digest + labels embedded in the record, and the current APT
# signer fingerprint. Any absent / extra / mismatched input exits BEFORE the
# `.reprepro-ok` sentinel is written, so publication never reaches reprepro on a
# bad release and the live Pages deployment is never touched.
#
# Every subcommand that touches release bytes takes `--suite <stable|preview>`.
# The default is `stable`, which behaves exactly as it always has (byte-for-byte
# same inputs, outputs, and tree layout). Both suites share ONE published tree:
# the caller assembles it by running this script once per suite, so each
# subcommand operates on its own suite only.
#
#   stable  — tagged vX.Y.Z release-record flow. `publish` builds a FRESH
#             ./public (stable pool + dists only) exactly as before.
#   preview — the rolling `preview` prerelease of tailrocks/velnor (tag
#             `preview`, target_commitish = the current main commit). A preview
#             has no tag to resolve, so the caller supplies the exact 40-hex
#             commit. Versions follow X.Y.Z~preview.N+<7-hex>; dpkg's `~` keeps
#             every preview strictly below the corresponding release. `publish`
#             NEVER wipes ./public — it only creates dists/preview +
#             pool/preview and signs the preview metadata inside the tree the
#             caller prepared for both suites (stable's conf stanza, stable pool
#             path, publication-record.json, and last-publish stay untouched).
#             Preview attestation gating (gh attestation verify
#             --deny-self-hosted-runners) belongs to the caller, not here.
#
# CALLER CONTRACT for choosing the preview publication mode: decide by whether
# the live $APT_BASE_URL/dists/preview/InRelease exists. If ANY prior preview
# publication exists, prefer the strict path (--prev-dir with the recovered
# rollback pair). Only when no live preview suite exists at all may the caller
# use `publish --suite preview --bootstrap`, which initializes the suite from
# the candidate pair alone (exactly 2 pool debs, 1 version per arch, previous
# pointer = JSON null). Bootstrap refuses to run over an existing preview pool,
# so it can never silently discard a retained rollback.
#
# Subcommands:
#   resolve-commit --version vX.Y.Z
#   download       [--suite stable|preview] --version <version> --dir <incoming>
#   verify         [--suite stable|preview] --version <version> --incoming <dir> \
#                  --commit <sha> --signer <live-fpr> --expect-signer <pinned-fpr> \
#                  [--verify-oci]
#   publish        [--suite stable|preview] [--bootstrap] --version <version> \
#                  --incoming <dir> (--prev-dir <dir> | --bootstrap) \
#                  --previous-pointer <file> \
#                  --signer <live-fpr>            (needs reprepro + gpg)
#
# `verify` is fully offline-testable: point --incoming at a directory of
# fixtures and pass the expected --commit. See test-verify-release.sh.
set -euo pipefail

SOURCE_REPO="tailrocks/velnor"
SOURCE_URL="https://github.com/tailrocks/velnor"
SOURCE_GIT="https://github.com/tailrocks/velnor.git"
RECORD_SCHEMA="velnor.release-record/v1"
PUBLICATION_SCHEMA="velnor.publication-record/v1"
RELEASE_MANIFEST_SCHEMA="velnor.package-release.v1"
REQUIRED_ARCHES="amd64 arm64"
PREVIEW_TAG="preview"
PREVIEW_SOURCE_REF="refs/heads/main"

log()  { printf '%s\n' "verify-release: $*" >&2; }
fail() { printf '%s\n' "verify-release: ERROR: $*" >&2; exit 1; }

# Preview version grammar: <base>~preview.<seq>+<7-hex>. Sets PV_BASE, PV_SEQ and
# PV_SHA on success and fails closed on anything else. Unlike the tagged-release
# invocation form, a `v` prefix is NOT part of the preview grammar.
PREVIEW_VERSION_RE='^([0-9]+[.][0-9]+[.][0-9]+)~preview[.]([0-9]+)\+([0-9a-f]{7})$'
parse_preview_version() {
  [[ "$1" =~ $PREVIEW_VERSION_RE ]] \
    || fail "preview version is not X.Y.Z~preview.N+<7-hex>: $1"
  PV_BASE="${BASH_REMATCH[1]}"
  PV_SEQ="${BASH_REMATCH[2]}"
  PV_SHA="${BASH_REMATCH[3]}"
}

# Reject any suite value that is not the locked pair of suites.
parse_suite() { # $1 = requested suite, $2 = subcommand name
  case "$1" in
    stable|preview) printf '%s\n' "$1" ;;
    *) fail "$2: --suite must be stable or preview (got: ${1:-<missing>})" ;;
  esac
}

# Portable SHA-256 (Linux runners have sha256sum; dev machines may only ship
# shasum). Prints the bare 64-hex digest of a file.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# jq accessor that fails closed when a field is null/absent.
jget() { jq -er "$2" "$1"; }

require_file() {
  [ -f "$1" ] || fail "required file missing: $1"
}

# Extract a .deb's data tree with portable tools (dpkg-deb when present, else
# ar + tar so the check also runs on a developer workstation).
extract_deb() {
  local deb="$1" dest="$2" data
  mkdir -p "$dest"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$deb" "$dest"
    return
  fi
  data="$(ar t "$deb" | grep '^data\.tar' | head -n1)"
  [ -n "$data" ] || fail "deb $deb has no data.tar member"
  ar p "$deb" "$data" | tar -x -C "$dest" -f -
}

# Extract a .deb's control tree with portable tools. The maintainer scripts are
# part of the package contract, so delivery verification must inspect the
# exact postinst shipped by each architecture rather than a checkout copy.
extract_deb_control() {
  local deb="$1" dest="$2" control
  mkdir -p "$dest"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -e "$deb" "$dest"
    return
  fi
  control="$(ar t "$deb" | grep '^control\.tar' | head -n1)"
  [ -n "$control" ] || fail "deb $deb has no control.tar member"
  ar p "$deb" "$control" | tar -x -C "$dest" -f -
}

validate_postinst_quota_contract() {
  local deb="$1" label="$2" control_dir postinst property
  control_dir="$(mktemp -d)"
  extract_deb_control "$deb" "$control_dir"
  postinst="$control_dir/postinst"
  require_file "$postinst"
  # Static package-contract check only: declarations here do not prove that
  # the installed workload slice enforces the limits at runtime.
  for property in CPUQuotaPerSecUSec MemoryMax MemoryHigh MemorySwapMax TasksMax; do
    grep -F -- "--property=$property" "$postinst" >/dev/null \
      || fail "$label postinst does not declare $property"
  done
  rm -rf "$control_dir"
}

# Read one control field from a .deb with portable tools (dpkg-deb when present,
# else the control.tar member, so the check also runs on a developer workstation).
deb_field() {
  local deb="$1" field="$2" ctl tmp
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -f "$deb" "$field"
    return
  fi
  tmp="$(mktemp -d)"
  ctl="$(ar t "$deb" | grep '^control\.tar' | head -n1)"
  [ -n "$ctl" ] || fail "deb $deb has no control.tar member"
  ar p "$deb" "$ctl" | tar -x -C "$tmp" -f -
  awk -v f="$field" '$1 == f":" {print $2}' "$tmp/control"
  rm -rf "$tmp"
}

validate_deb_control_contract() {
  local deb="$1" label="$2" expected_version="$3" expected_arch="$4"
  [ "$(deb_field "$deb" Package)" = velnor-runner ] \
    || fail "$label deb Package is not velnor-runner"
  [ "$(deb_field "$deb" Version)" = "$expected_version" ] \
    || fail "$label deb Version != $expected_version"
  [ "$(deb_field "$deb" Architecture)" = "$expected_arch" ] \
    || fail "$label deb Architecture != $expected_arch"
}

resolve_commit() {
  local version="$1" commit
  # Independent resolution: ask the public git remote, do NOT trust the record.
  commit="$(git ls-remote "$SOURCE_GIT" "refs/tags/${version}^{}" | awk '{print $1}' | head -n1)"
  if [ -z "$commit" ]; then
    commit="$(git ls-remote "$SOURCE_GIT" "refs/tags/${version}" | awk '{print $1}' | head -n1)"
  fi
  [ -n "$commit" ] || fail "could not resolve $version to a commit on $SOURCE_REPO"
  printf '%s\n' "$commit"
}

cmd_resolve_commit() {
  local version="" suite="stable"
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --suite) suite="$(parse_suite "${2:-}" resolve-commit)"; shift 2 ;;
      *) fail "resolve-commit: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "resolve-commit: --version required"
  # A preview has no tag: the caller must supply its target commit.
  [ "$suite" = stable ] \
    || fail "resolve-commit: --suite preview has no tag to resolve; supply the target commit instead"
  resolve_commit "$version"
}

download_preview() {
  local ver="$1" dir="$2"
  parse_preview_version "$ver"
  # GitHub rewrites release asset names on upload: `~` becomes `.`. Match the
  # dotted filenames the rolling release actually serves; `$ver` itself stays
  # the tilde version the grammar and the release name are defined on.
  local asset_version="${ver//'~'/.}"
  # Pull ONLY the coherence inputs from the rolling preview release.
  gh release download "$PREVIEW_TAG" --repo "$SOURCE_REPO" --dir "$dir" \
    --pattern "velnor-runner-preview-${asset_version}-amd64.deb" \
    --pattern "velnor-runner-preview-${asset_version}-amd64.deb.sha256" \
    --pattern "velnor-runner-preview-${asset_version}-arm64.deb" \
    --pattern "velnor-runner-preview-${asset_version}-arm64.deb.sha256" \
    --pattern 'release-manifest.json' \
    --pattern 'SHA256SUMS'
  log "downloaded preview coherence inputs for $ver into $dir"
}

cmd_download() {
  local version="" dir="" suite
  suite=stable
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --dir) dir="$2"; shift 2 ;;
      --suite) suite="$(parse_suite "${2:-}" download)"; shift 2 ;;
      *) fail "download: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "download: --version required"
  [ -n "$dir" ] || fail "download: --dir required"
  mkdir -p "$dir"
  if [ "$suite" = preview ]; then
    # Preview versions never carry the `v` prefix (the grammar rejects it).
    download_preview "$version" "$dir"
    return
  fi
  local ver="${version#v}"
  # Pull ONLY the coherence inputs from the public source release.
  gh release download "$version" --repo "$SOURCE_REPO" --dir "$dir" \
    --pattern 'release-record.json' \
    --pattern 'release-record.json.sha256' \
    --pattern 'manifest.json' \
    --pattern 'manifest.json.sha256' \
    --pattern "velnor-runner-${ver}-amd64.deb" \
    --pattern "velnor-runner-${ver}-amd64.deb.sha256" \
    --pattern "velnor-runner-${ver}-arm64.deb" \
    --pattern "velnor-runner-${ver}-arm64.deb.sha256"
  log "downloaded coherence inputs for $version into $dir"
}

cmd_verify() {
  local version="" incoming="" commit="" signer="" expect_signer="" verify_oci=0 suite
  suite=stable
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --incoming) incoming="$2"; shift 2 ;;
      --commit) commit="$2"; shift 2 ;;
      --signer) signer="$2"; shift 2 ;;
      --expect-signer) expect_signer="$2"; shift 2 ;;
      --verify-oci) verify_oci=1; shift ;;
      --suite) suite="$(parse_suite "${2:-}" verify)"; shift 2 ;;
      *) fail "verify: unknown arg $1" ;;
    esac
  done
  [ -n "$incoming" ] || fail "verify: --incoming required"
  # A prior successful verification must never authorize a failed revalidation.
  rm -f "$incoming/.reprepro-ok"
  [ -n "$version" ] || fail "verify: --version required"
  [ -n "$signer" ] || fail "verify: --signer required"
  [ -n "$expect_signer" ] || fail "verify: --expect-signer required"
  if [ "$suite" = preview ]; then
    [ "$verify_oci" = 0 ] || fail "verify: --verify-oci does not apply to the preview suite (previews ship no OCI record)"
    verify_preview "$version" "$incoming" "$commit" "$signer" "$expect_signer"
    return
  fi

  local ver="${version#v}"
  # Resolve the tag commit independently unless one was supplied (tests supply
  # the expected commit; real runs resolve from the public remote).
  if [ -z "$commit" ]; then
    commit="$(resolve_commit "$version")"
  fi
  case "$commit" in
    *[!0-9a-f]* | "") fail "resolved commit is not lowercase hex: $commit" ;;
  esac
  [ "${#commit}" -eq 40 ] || fail "resolved commit is not 40 hex chars"

  local record="$incoming/release-record.json"
  local record_sum="$incoming/release-record.json.sha256"
  local manifest="$incoming/manifest.json"
  local manifest_sum="$incoming/manifest.json.sha256"
  require_file "$record"
  require_file "$record_sum"
  require_file "$manifest"
  require_file "$manifest_sum"

  # --- exactly the two expected debs, no extras --------------------------------
  local deb_count
  deb_count="$(find "$incoming" -maxdepth 1 -name 'velnor-runner-*.deb' | wc -l | tr -d ' ')"
  [ "$deb_count" = "2" ] || fail "expected exactly 2 debs in $incoming, found $deb_count (extra/missing deb)"

  # --- record + manifest independent checksums ---------------------------------
  local want_record_sum have_record_sum
  want_record_sum="$(awk '{print $1}' "$record_sum")"
  have_record_sum="$(sha256 "$record")"
  [ "$want_record_sum" = "$have_record_sum" ] || fail "record checksum mismatch"

  local want_manifest_sum have_manifest_sum
  want_manifest_sum="$(awk '{print $1}' "$manifest_sum")"
  have_manifest_sum="$(sha256 "$manifest")"
  [ "$want_manifest_sum" = "$have_manifest_sum" ] || fail "manifest checksum mismatch"

  # --- schema / source / tag / version / commit --------------------------------
  [ "$(jget "$record" '.schema')" = "$RECORD_SCHEMA" ] || fail "record schema mismatch"
  [ "$(jget "$record" '.build.repository')" = "$SOURCE_REPO" ] || fail "record repository mismatch"
  [ "$(jget "$record" '.build.tag')" = "$version" ] || fail "record tag mismatch"
  [ "$(jget "$record" '.build.crate_version')" = "$ver" ] || fail "record crate_version mismatch"
  [ "$(jget "$record" '.build.debian_version')" = "$ver" ] || fail "record debian_version mismatch"
  local record_manifest_ver
  record_manifest_ver="$(jget "$record" '.build.manifest_version | select(type == "number" and . > 0 and floor == .)')"
  [ "$(jget "$record" '.build.commit')" = "$commit" ] || fail "record commit does not match the independently resolved tag commit"
  [ "$(jget "$record" '.apt.origin')" = Velnor ] \
    || fail "record APT origin is not Velnor"
  [ "$(jget "$record" '.apt.suite')" = stable ] \
    || fail "record APT suite is not stable"
  [ "$(jget "$record" '.apt.component')" = main ] \
    || fail "record APT component is not main"

  # --- manifest binding (extracted vs packaged identity) -----------------------
  local record_manifest_hash manifest_source manifest_crate manifest_ver
  record_manifest_hash="$(jget "$record" '.build.manifest_sha256')"
  [ "$record_manifest_hash" = "$have_manifest_sum" ] || fail "record manifest hash != sha256(manifest.json)"
  manifest_source="$(jget "$manifest" '.source_sha')"
  manifest_crate="$(jget "$manifest" '.crate_version')"
  manifest_ver="$(jget "$manifest" '.version | select(type == "number" and . > 0 and floor == .)')"
  [ "$manifest_source" = "$commit" ] || fail "manifest source_sha != resolved commit"
  [ "$manifest_crate" = "$ver" ] || fail "manifest crate_version mismatch"
  [ "$record_manifest_ver" = "$manifest_ver" ] || fail "record manifest_version != manifest version"

  # --- OCI ref / digest / labels (record-internal; live query optional) --------
  local index_digest image_ref oci_ver oci_rev oci_src oci_mhash
  index_digest="$(jget "$record" '.oci_index_digest')"
  image_ref="$(jget "$record" '.oci_image_ref')"
  oci_ver="$(jget "$record" '.oci_labels.version')"
  oci_rev="$(jget "$record" '.oci_labels.revision')"
  oci_src="$(jget "$record" '.oci_labels.source')"
  oci_mhash="$(jget "$record" '.oci_labels.manifest_sha256')"
  case "$index_digest" in sha256:*) : ;; *) fail "oci_index_digest not a sha256 digest" ;; esac
  case "$image_ref" in *"$index_digest") : ;; *) fail "oci_image_ref does not pin the index digest" ;; esac
  [ "$oci_ver" = "$ver" ] || fail "oci label version mismatch"
  [ "$oci_rev" = "$commit" ] || fail "oci label revision != commit"
  [ "$oci_src" = "$SOURCE_URL" ] || fail "oci label source mismatch"
  [ "$oci_mhash" = "$record_manifest_hash" ] || fail "oci label manifest hash mismatch"
  if [ "$verify_oci" = "1" ]; then
    verify_oci_live "$record" "$image_ref" "$index_digest" "$ver" "$commit" \
      "$record_manifest_hash" "$oci_src"
  else
    log "skipping live OCI query (record-internal OCI coherence validated); pass --verify-oci in production"
  fi

  # --- per-arch deb hashes + extracted/packaged identity -----------------------
  local record_arches
  record_arches="$(jq -er '[.architectures[].arch] | sort | join(" ")' "$record")"
  [ "$record_arches" = "amd64 arm64" ] || fail "record architectures are not exactly {amd64, arm64}"

  local arch
  for arch in $REQUIRED_ARCHES; do
    local deb="$incoming/velnor-runner-${ver}-${arch}.deb"
    local deb_sum="$incoming/velnor-runner-${ver}-${arch}.deb.sha256"
    require_file "$deb"
    require_file "$deb_sum"
    local want_deb have_deb record_deb record_bin have_bin
    want_deb="$(awk '{print $1}' "$deb_sum")"
    have_deb="$(sha256 "$deb")"
    [ "$want_deb" = "$have_deb" ] || fail "$arch deb sidecar checksum mismatch"
    record_deb="$(jq -er --arg a "$arch" '.architectures[] | select(.arch==$a) | .deb_sha256' "$record")"
    [ "$record_deb" = "$have_deb" ] || fail "$arch deb hash != record deb_sha256"

    local expected_target record_target
    case "$arch" in
      amd64) expected_target=x86_64-unknown-linux-gnu ;;
      arm64) expected_target=aarch64-unknown-linux-gnu ;;
    esac
    record_target="$(jq -er --arg a "$arch" '.architectures[] | select(.arch==$a) | .target' "$record")"
    [ "$record_target" = "$expected_target" ] \
      || fail "$arch record target is not $expected_target"
    validate_deb_control_contract "$deb" "$arch" "$ver" "$arch"

    # Extracted + packaged identity: the identity files shipped INSIDE the deb
    # must agree with the resolved commit and the compiled manifest hash.
    local xdir
    xdir="$(mktemp -d)"
    extract_deb "$deb" "$xdir"
    validate_postinst_quota_contract "$deb" "$arch"
    local bi="$xdir/usr/share/velnor/build-identity.json"
    local pm="$xdir/usr/share/velnor/manifest.json"
    require_file "$bi"
    require_file "$pm"
    [ "$(jget "$bi" '.source_sha')" = "$commit" ] || fail "$arch deb build-identity source_sha != commit"
    [ "$(jget "$bi" '.crate_version')" = "$ver" ] || fail "$arch deb build-identity crate_version mismatch"
    [ "$(sha256 "$pm")" = "$record_manifest_hash" ] || fail "$arch deb packaged manifest hash != record manifest hash"
    # The current package contract ships two binaries: the daemon is the
    # release-record identity and systemd entrypoint; velnorctl is the
    # operator-facing companion. Keep hashing the daemon until Plan 079
    # removes the interim two-binary estate.
    require_file "$xdir/usr/bin/velnor-runner"
    require_file "$xdir/usr/bin/velnorctl"
    record_bin="$(jq -er --arg a "$arch" '.architectures[] | select(.arch==$a) | .binary_sha256' "$record")"
    have_bin="$(sha256 "$xdir/usr/bin/velnor-runner")"
    [ "$have_bin" = "$record_bin" ] || fail "$arch extracted velnor-runner binary hash != record binary_sha256"
    rm -rf "$xdir"
  done

  # --- current APT signer fingerprint ------------------------------------------
  # The live signing key must be the pinned publisher identity; a rotated or
  # unexpected signer stops publication rather than silently re-signing.
  check_signer_fingerprint "$signer" "$expect_signer"

  # --- all checks passed: arm the reprepro sentinel ----------------------------
  : > "$incoming/.reprepro-ok"
  log "release $version is coherent — OK to reprepro (sentinel: $incoming/.reprepro-ok)"
}

# Verify the rolling `preview` release. There is no tag and no release record
# here: the caller supplies the exact main commit, and the source-owned
# release-manifest.json plus the per-deb sidecars and SHA256SUMS carry the
# coherence chain.
verify_preview() {
  local version="$1" incoming="$2" commit="$3" signer="$4" expect_signer="$5"
  local ver="$version"
  [ -n "$commit" ] \
    || fail "verify: --commit is required for the preview suite (a preview has no tag to resolve)"
  case "$commit" in
    *[!0-9a-f]* | "") fail "preview commit is not lowercase hex: $commit" ;;
  esac
  [ "${#commit}" -eq 40 ] || fail "preview commit is not 40 hex chars"

  parse_preview_version "$ver"
  local base="$PV_BASE"
  [ "$PV_SHA" = "${commit:0:7}" ] \
    || fail "preview version suffix ${PV_SHA} does not match the source commit"

  local manifest="$incoming/release-manifest.json"
  local sums="$incoming/SHA256SUMS"
  require_file "$manifest"
  require_file "$sums"

  # --- exactly the two expected preview debs, no extras ------------------------
  # Asset files carry the GitHub-normalized dotted form of the version (`~` is
  # rewritten to `.` on upload); every version-contract check below still uses
  # `$ver` and the release-manifest version field.
  local deb_count asset_version deb_amd64 deb_arm64
  asset_version="${ver//'~'/.}"
  deb_amd64="velnor-runner-preview-${asset_version}-amd64.deb"
  deb_arm64="velnor-runner-preview-${asset_version}-arm64.deb"
  deb_count="$(find "$incoming" -maxdepth 1 -name 'velnor-runner-*.deb' | wc -l | tr -d ' ')"
  [ "$deb_count" = "2" ] || fail "expected exactly 2 preview debs in $incoming, found $deb_count (extra/missing deb)"
  require_file "$incoming/$deb_amd64"
  require_file "$incoming/$deb_arm64"

  # --- manifest schema / source / version / commit ------------------------------
  [ "$(jget "$manifest" '.schema')" = "$RELEASE_MANIFEST_SCHEMA" ] || fail "release-manifest schema mismatch"
  [ "$(jget "$manifest" '.source_repository')" = "$SOURCE_REPO" ] || fail "release-manifest repository mismatch"
  [ "$(jget "$manifest" '.source_ref')" = "$PREVIEW_SOURCE_REF" ] \
    || fail "release-manifest source_ref is not $PREVIEW_SOURCE_REF"
  [ "$(jget "$manifest" '.source_commit')" = "$commit" ] \
    || fail "release-manifest source_commit does not match the caller-supplied commit"
  [ "$(jget "$manifest" '.version')" = "$ver" ] || fail "release-manifest version mismatch"
  [ "$(jq -er '.assets | length' "$manifest")" = "2" ] \
    || fail "release-manifest must list exactly two assets"

  # --- per-arch sidecar, SHA256SUMS, manifest hash, and packaged identity ------
  local arch deb_name release_name deb deb_sum want_deb have_deb manifest_deb sums_line
  for arch in $REQUIRED_ARCHES; do
    deb_name="velnor-runner-preview-${asset_version}-${arch}.deb"
    deb="$incoming/$deb_name"
    deb_sum="$deb.sha256"
    require_file "$deb_sum"
    [ "$(awk 'END{print NR+0}' "$deb_sum")" = "1" ] \
      || fail "$arch preview sidecar must be a single line"
    # Sidecar format: "<64hex>  <name>", or a bare "<64hex>" line — the velnor
    # rolling preview publishes digest-only sidecars, so a missing name field
    # binds the sidecar to its deb by digest alone (SHA256SUMS still pins the
    # name below); a present name field must match exactly.
    if [ -n "$(awk 'NR==1{print $2}' "$deb_sum")" ]; then
      [ "$(awk 'NR==1{print $2}' "$deb_sum")" = "$deb_name" ] \
        || fail "$arch preview sidecar does not name $deb_name"
    fi
    want_deb="$(awk 'NR==1{print $1}' "$deb_sum")"
    case "$want_deb" in
      *[!0-9a-f]* | "") fail "$arch preview sidecar digest is not lowercase hex" ;;
    esac
    [ "${#want_deb}" -eq 64 ] || fail "$arch preview sidecar digest is not 64 hex chars"
    have_deb="$(sha256 "$deb")"
    [ "$want_deb" = "$have_deb" ] || fail "$arch preview deb sidecar checksum mismatch"
    # SHA256SUMS and the release manifest bind the tilde (un-normalized) asset
    # name — GitHub rewrites `~` to `.` only in uploaded filenames, never in the
    # coherence files velnor publishes. Accept either spelling; the digest
    # comparison below is what actually binds the file.
    release_name="velnor-runner-preview-${ver}-${arch}.deb"
    sums_line="$(awk -v n="$release_name" -v f="$deb_name" '$2 == n || $2 == f {print $1}' "$sums")"
    [ "$sums_line" = "$have_deb" ] || fail "$arch preview deb hash is not pinned by SHA256SUMS"
    manifest_deb="$(jq -er --arg n "$release_name" --arg f "$deb_name" \
      '.assets[] | select(.name==$n or .name==$f) | .sha256' "$manifest")"
    [ "$manifest_deb" = "$have_deb" ] \
      || fail "$arch preview deb hash != release-manifest asset sha256"

    # Packaged identity: control fields and the shipped build-identity must agree
    # with the supplied commit and the base X.Y.Z of the preview version.
    validate_deb_control_contract "$deb" "$arch preview" "$ver" "$arch"

    local xdir
    xdir="$(mktemp -d)"
    extract_deb "$deb" "$xdir"
    validate_postinst_quota_contract "$deb" "$arch preview"
    require_file "$xdir/usr/share/velnor/build-identity.json"
    [ "$(jget "$xdir/usr/share/velnor/build-identity.json" '.source_sha')" = "$commit" ] \
      || fail "$arch preview deb build-identity source_sha != commit"
    [ "$(jget "$xdir/usr/share/velnor/build-identity.json" '.crate_version')" = "$base" ] \
      || fail "$arch preview deb build-identity crate_version != $base"
    require_file "$xdir/usr/bin/velnor-runner"
    require_file "$xdir/usr/bin/velnorctl"
    rm -rf "$xdir"
  done
  [ "$(awk 'NF{c++} END{print c+0}' "$sums")" = "2" ] \
    || fail "SHA256SUMS must contain exactly the two preview deb lines"

  # --- current APT signer fingerprint ------------------------------------------
  check_signer_fingerprint "$signer" "$expect_signer"

  # --- all checks passed: arm the reprepro sentinel ----------------------------
  : > "$incoming/.reprepro-ok"
  log "preview $ver (base $base, sequence $PV_SEQ) is coherent — OK to publish the preview suite (sentinel: $incoming/.reprepro-ok)"
}

verify_oci_live() {
  local record="$1" image_ref="$2" index_digest="$3" ver="$4" commit="$5"
  local mhash="$6" source="$7"
  command -v docker >/dev/null 2>&1 || fail "--verify-oci requires docker/buildx"
  local index_json
  index_json="$(docker buildx imagetools inspect "$image_ref" --format '{{json .}}')" \
    || fail "could not inspect $image_ref"
  printf '%s' "$index_json" | jq -e --arg d "$index_digest" '.manifest.digest == $d' >/dev/null \
    || fail "live OCI index digest != record oci_index_digest"

  # An OCI index has no image config of its own. Bind the exact two platform
  # manifests, then inspect and validate each child config independently.
  local image_repo="${image_ref%@*}" arch platform_arch platform_digest child_json
  local live_ver live_rev live_source live_mhash
  for arch in $REQUIRED_ARCHES; do
    case "$arch" in amd64) platform_arch=amd64 ;; arm64) platform_arch=arm64 ;; esac
    platform_digest="$(jq -er --arg a "$arch" \
      '.architectures[] | select(.arch==$a) | .oci_platform_digest' "$record")"
    printf '%s' "$index_json" | jq -e --arg d "$platform_digest" --arg a "$platform_arch" \
      '[.manifest.manifests[] | select(.digest==$d and .platform.os=="linux" and .platform.architecture==$a)] | length == 1' \
      >/dev/null || fail "live OCI $arch platform digest mismatch"

    child_json="$(docker buildx imagetools inspect "$image_repo@$platform_digest" --format '{{json .}}')" \
      || fail "could not inspect live OCI $arch platform manifest"
    printf '%s' "$child_json" | jq -e --arg d "$platform_digest" '.manifest.digest == $d' >/dev/null \
      || fail "live OCI $arch child digest mismatch"
    live_ver="$(printf '%s' "$child_json" | jq -r '.image.config.Labels["org.opencontainers.image.version"] // empty')"
    live_rev="$(printf '%s' "$child_json" | jq -r '.image.config.Labels["org.opencontainers.image.revision"] // empty')"
    live_source="$(printf '%s' "$child_json" | jq -r '.image.config.Labels["org.opencontainers.image.source"] // empty')"
    live_mhash="$(printf '%s' "$child_json" | jq -r '.image.config.Labels["org.velnor.manifest-sha256"] // empty')"
    [ "$live_ver" = "$ver" ] || fail "live OCI $arch version label mismatch"
    [ "$live_rev" = "$commit" ] || fail "live OCI $arch revision label mismatch"
    [ "$live_source" = "$source" ] || fail "live OCI $arch source label mismatch"
    [ "$live_mhash" = "$mhash" ] || fail "live OCI $arch manifest-sha256 label mismatch"
  done
  log "live OCI index, platform digests, and labels match the record"
}

# The live signing key must be the pinned publisher identity; a rotated or
# unexpected signer stops publication rather than silently re-signing.
check_signer_fingerprint() {
  local live_fpr pinned_fpr fpr
  live_fpr="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  pinned_fpr="$(printf '%s' "$2" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  for fpr in "$live_fpr" "$pinned_fpr"; do
    case "$fpr" in
      *[!0-9A-F]* | "") fail "APT signer fingerprint must be full 40 or 64 hexadecimal digits" ;;
    esac
    case "${#fpr}" in
      40|64) ;;
      *) fail "APT signer fingerprint must be full 40 or 64 hexadecimal digits" ;;
    esac
  done
  [ "$live_fpr" = "$pinned_fpr" ] \
    || fail "APT signer fingerprint does not match the pinned publisher key"
}

prime_signer_agent() {
  local signer="$1"
  [ -n "${APT_GPG_PASSPHRASE:-}" ] \
    || fail "publish: APT_GPG_PASSPHRASE is unset"
  # reprepro signs through GPGME, which cannot receive our CI passphrase
  # directly. Unlock and cache the exact key in gpg-agent with one discarded
  # signature before reprepro mutates the staging repository.
  printf '%s' "$APT_GPG_PASSPHRASE" | \
    gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
      --local-user "$signer" --output /dev/null --detach-sign /dev/null \
    || fail "publish: could not unlock the pinned APT signer"
  trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true' EXIT
}

cmd_publish() {
  # Real publication path (needs apt-ftparchive + gpg). Builds a FRESH staging
  # tree containing the candidate + the exact prior
  # published pair, signs indexes, then emits + detached-signs
  # publication-record.json. It writes only into ./public — the live Pages
  # deployment is untouched until the deploy job uploads this artifact, so a
  # failure here leaves the old Pages state active and publishable.
  #
  # --suite preview flips this to the preview channel: the tree is NOT wiped
  # (the caller already assembled it for both suites), only dists/preview,
  # pool/preview and the preview metadata are written, and the previous pointer
  # is the JSON string "preview".
  #
  # --bootstrap initializes a preview suite that has never been published: it is
  # exclusive to --suite preview and to --prev-dir, stages exactly the candidate
  # pair, and takes the JSON null previous pointer.
  local version="" incoming="" prev_dir="" previous_pointer="" signer="" suite
  local bootstrap=0
  suite=stable
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --incoming) incoming="$2"; shift 2 ;;
      --prev-dir) prev_dir="$2"; shift 2 ;;
      --previous-pointer) previous_pointer="$2"; shift 2 ;;
      --signer) signer="$2"; shift 2 ;;
      --suite) suite="$(parse_suite "${2:-}" publish)"; shift 2 ;;
      --bootstrap) bootstrap=1; shift ;;
      *) fail "publish: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "publish: --version required"
  [ -n "$incoming" ] || fail "publish: --incoming required"
  [ -f "$previous_pointer" ] || fail "publish: --previous-pointer required"
  [ -n "$signer" ] || fail "publish: --signer required"
  if [ "$bootstrap" = 1 ]; then
    [ "$suite" = preview ] || fail "publish: --bootstrap applies only to --suite preview"
    [ -z "$prev_dir" ] || fail "publish: --bootstrap is mutually exclusive with --prev-dir"
  fi
  [ -f "$incoming/.reprepro-ok" ] || fail "publish: refusing — verify has not armed the reprepro sentinel"
  command -v apt-ftparchive >/dev/null 2>&1 || fail "publish: apt-ftparchive not installed"
  command -v dpkg-deb >/dev/null 2>&1 || fail "publish: dpkg-deb not installed"
  command -v gpg >/dev/null 2>&1 || fail "publish: gpg not installed"
  if [ "$suite" = preview ]; then
    publish_preview "$version" "$incoming" "$prev_dir" "$previous_pointer" "$signer" "$bootstrap"
    return
  fi

  prime_signer_agent "$signer"

  rm -rf public
  mkdir -p public/conf public/pool/main/v/velnor-runner
  cat > public/conf/distributions <<DIST
Origin: Velnor
Label: Velnor
Codename: stable
Architectures: amd64 arm64
Components: main
Description: apt repository for the Velnor self-hosted GitHub Actions runner
SignWith: ${signer}
DIST
  [ -f velnor.gpg ] && cp velnor.gpg public/velnor.gpg || true

  local deb candidate destination package_version package_arch
  stage_package() {
    deb="$1"
    [ "$(dpkg-deb -f "$deb" Package)" = velnor-runner ] \
      || fail "publish: staged package has unexpected name"
    package_version="$(dpkg-deb -f "$deb" Version)"
    package_arch="$(dpkg-deb -f "$deb" Architecture)"
    case "$package_version" in
      ''|*[!0-9A-Za-z.+:~-]*) fail "publish: staged package version is unsafe" ;;
    esac
    case "$package_arch" in
      amd64|arm64) ;;
      *) fail "publish: staged package architecture is unsupported" ;;
    esac
    destination="public/pool/main/v/velnor-runner/velnor-runner_${package_version}_${package_arch}.deb"
    if [ -f "$destination" ]; then
      [ "$(sha256 "$destination")" = "$(sha256 "$deb")" ] \
        || fail "publish: canonical package identity collides with different bytes"
    else
      cp "$deb" "$destination"
    fi
  }
  # Materialize only the already-verified prior and candidate bytes. reprepro's
  # single-active-version database can retain extra pool entries as an
  # implementation side effect; a deterministic fresh pool removes that
  # failure class before apt-ftparchive builds the two-version indexes.
  if [ -n "$prev_dir" ]; then
    for deb in "$prev_dir"/velnor-runner*.deb; do
      [ -f "$deb" ] || continue
      candidate="$incoming/$(basename "$deb")"
      if [ -f "$candidate" ]; then
        [ "$(sha256 "$candidate")" = "$(sha256 "$deb")" ] \
          || fail "published package name collides with different candidate bytes: $(basename "$deb")"
        continue
      fi
      stage_package "$deb"
    done
  fi
  for deb in "$incoming"/velnor-runner-*.deb; do
    stage_package "$deb"
  done
  [ "$(find public/pool/main/v/velnor-runner -type f -name '*.deb' | awk 'END { print NR }')" = 4 ] \
    || fail "publish: deterministic pool must contain exactly four package files"

  local arch packages versions rollback_version="" arch_rollback
  for arch in $REQUIRED_ARCHES; do
    packages="public/dists/stable/main/binary-${arch}/Packages"
    mkdir -p "$(dirname "$packages")"
    (cd public && apt-ftparchive -a "$arch" packages pool) > "$packages"
    versions="$(awk '$1=="Package:"{p=$2} p=="velnor-runner" && $1=="Version:"{print $2}' \
      "$packages" | sort -u)"
    [ "$(printf '%s\n' "$versions" | awk 'NF{n++} END{print n+0}')" = 2 ] \
      || fail "publish: $arch index must retain exactly candidate plus rollback version (observed: $(printf '%s' "$versions" | tr '\n' ','))"
    printf '%s\n' "$versions" | grep -Fx "${version#v}" >/dev/null \
      || fail "publish: $arch index lacks candidate version ${version#v}"
    arch_rollback="$(printf '%s\n' "$versions" | grep -Fxv "${version#v}")"
    [ -n "$arch_rollback" ] || fail "publish: $arch rollback version is empty"
    if [ -z "$rollback_version" ]; then rollback_version="$arch_rollback"; fi
    [ "$arch_rollback" = "$rollback_version" ] \
      || fail "publish: architecture rollback versions differ"
    gzip -n -9 -c "$packages" > "$packages.gz"
  done

  rm -f public/dists/stable/Release public/dists/stable/Release.gpg \
    public/dists/stable/InRelease
  (cd public && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Velnor \
    -o APT::FTPArchive::Release::Label=Velnor \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures='amd64 arm64' \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description='apt repository for the Velnor self-hosted GitHub Actions runner' \
    release dists/stable) > public/dists/stable/Release
  printf '%s' "$APT_GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --local-user "$signer" --armor \
    --output public/dists/stable/Release.gpg --detach-sign public/dists/stable/Release
  printf '%s' "$APT_GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --local-user "$signer" \
    --output public/dists/stable/InRelease --clearsign public/dists/stable/Release

  local previous_tag
  previous_tag="$(jq -er 'if type == "string" then . elif type == "object" then .tag else error("invalid previous pointer") end' "$previous_pointer")" \
    || fail "publish: previous pointer is malformed"
  [ "$previous_tag" = "v$rollback_version" ] \
    || fail "publish: previous pointer disagrees with retained rollback version"
  if [ "$(jq -r type "$previous_pointer")" = object ]; then
    jq -e 'keys == ["source_record_sha256", "tag"] and
      (.tag | type == "string") and
      (.source_record_sha256 | type == "string" and test("^[0-9a-f]{64}$"))' \
      "$previous_pointer" >/dev/null \
      || fail "publish: coherent previous pointer is malformed"
  else
    [ "$previous_tag" = v0.1.121 ] \
      || fail "publish: only v0.1.121 may use the legacy previous pointer"
  fi

  emit_publication_record "$version" "$incoming" "$signer" "$previous_pointer"
  log "publication staged in ./public and publication-record.json signed; live Pages untouched"
}

# Preview publication. The caller assembles ONE shared tree for both suites, so
# this never wipes ./public: it only creates dists/preview + pool/preview and
# signs the preview metadata. Stable's conf stanza, stable pool path,
# publication-record.json, and last-publish are left untouched. Unlike stable,
# the retained rollback pair is mandatory and the candidate must be strictly
# newer than it (dpkg version order), because a preview channel that can move
# backwards is worse than one that fails closed.
#
# --bootstrap is the one initialization path for a preview suite that has never
# been published (no live dists/preview exists to recover a rollback pair from):
# it stages exactly the candidate pair, keeps exactly the candidate version in
# each index, and takes the JSON null previous pointer. It fails when the pool
# already holds anything beyond the candidate pair, so a retained rollback can
# never be discarded; the caller must use the strict path whenever a prior
# preview publication exists.
publish_preview() {
  local version="$1" incoming="$2" prev_dir="$3" previous_pointer="$4" signer="$5" bootstrap="$6"
  local ver="$version"
  command -v dpkg >/dev/null 2>&1 || fail "publish: dpkg not installed (needed for preview version ordering)"

  parse_preview_version "$ver"
  if [ "$bootstrap" = 1 ]; then
    :
  else
    [ -n "$prev_dir" ] \
      || fail "publish: --prev-dir is required for the preview suite (the retained preview rollback pair; use --bootstrap to initialize the suite)"
  fi

  mkdir -p public/conf public/pool/preview/main/v/velnor-runner
  # Second stanza for the preview suite; idempotent so a re-run never duplicates.
  if ! grep -q '^Codename: preview$' public/conf/distributions 2>/dev/null; then
    cat >> public/conf/distributions <<DIST

Origin: Velnor
Label: Velnor
Suite: preview
Codename: preview
Architectures: amd64 arm64
Components: main
Description: apt repository for the Velnor self-hosted GitHub Actions runner (preview suite)
SignWith: ${signer}
DIST
  fi
  [ -f velnor.gpg ] && cp velnor.gpg public/velnor.gpg || true

  local deb candidate destination package_version package_arch
  stage_preview_package() {
    deb="$1"
    [ "$(deb_field "$deb" Package)" = velnor-runner ] \
      || fail "publish: staged package has unexpected name"
    package_version="$(deb_field "$deb" Version)"
    package_arch="$(deb_field "$deb" Architecture)"
    case "$package_version" in
      ''|*[!0-9A-Za-z.+:~-]*) fail "publish: staged package version is unsafe" ;;
    esac
    case "$package_arch" in
      amd64|arm64) ;;
      *) fail "publish: staged package architecture is unsupported" ;;
    esac
    destination="public/pool/preview/main/v/velnor-runner/velnor-runner_${package_version}_${package_arch}.deb"
    if [ -f "$destination" ]; then
      [ "$(sha256 "$destination")" = "$(sha256 "$deb")" ] \
        || fail "publish: canonical package identity collides with different bytes"
    else
      cp "$deb" "$destination"
    fi
  }
  # Same deterministic-pool rule as stable: materialize only the already-verified
  # prior and candidate bytes, canonically named with dpkg underscores.
  if [ "$bootstrap" = 1 ]; then
    # Initialization: nothing is recovered, so anything already in the pool
    # beyond the candidate pair means a preview suite already exists.
    local expected_deb
    for deb in "$incoming"/velnor-runner-preview-*.deb; do
      [ -f "$deb" ] || continue
      [ "$(deb_field "$deb" Version)" = "$ver" ] \
        || fail "publish: candidate deb Version != preview candidate version $ver"
      stage_preview_package "$deb"
    done
    for expected_deb in \
      "public/pool/preview/main/v/velnor-runner/velnor-runner_${ver}_amd64.deb" \
      "public/pool/preview/main/v/velnor-runner/velnor-runner_${ver}_arm64.deb"; do
      [ -f "$expected_deb" ] \
        || fail "publish: bootstrap must stage the complete candidate pair (missing $(basename "$expected_deb"))"
    done
    [ "$(find public/pool/preview/main/v/velnor-runner -type f -name '*.deb' | awk 'END { print NR }')" = 2 ] \
      || fail "publish: bootstrap refuses to run over an existing preview pool (found $(find public/pool/preview/main/v/velnor-runner -type f -name '*.deb' | awk 'END { print NR }') package files; recover the rollback pair and publish the strict path)"
  else
    # The retained rollback pair carries the canonical dpkg pool naming
    # (velnor-runner_<version>_<arch>.deb, written by the workflow's recovery
    # step from the live signed index); older recoveries may still carry the
    # GitHub asset naming, so match both spellings.
    for deb in "$prev_dir"/velnor-runner-preview-*.deb "$prev_dir"/velnor-runner_*preview*_*.deb; do
      [ -f "$deb" ] || continue
      candidate="$incoming/$(basename "$deb")"
      if [ -f "$candidate" ]; then
        [ "$(sha256 "$candidate")" = "$(sha256 "$deb")" ] \
          || fail "published package name collides with different candidate bytes: $(basename "$deb")"
        continue
      fi
      stage_preview_package "$deb"
    done
    for deb in "$incoming"/velnor-runner-preview-*.deb; do
      [ -f "$deb" ] || continue
      [ "$(deb_field "$deb" Version)" = "$ver" ] \
        || fail "publish: candidate deb Version != preview candidate version $ver"
      stage_preview_package "$deb"
    done
    [ "$(find public/pool/preview/main/v/velnor-runner -type f -name '*.deb' | awk 'END { print NR }')" = 4 ] \
      || fail "publish: deterministic preview pool must contain exactly four package files"
  fi

  local arch packages versions rollback_version="" arch_rollback
  for arch in $REQUIRED_ARCHES; do
    packages="public/dists/preview/main/binary-${arch}/Packages"
    mkdir -p "$(dirname "$packages")"
    (cd public && apt-ftparchive -a "$arch" packages pool/preview) > "$packages"
    versions="$(awk '$1=="Package:"{p=$2} p=="velnor-runner" && $1=="Version:"{print $2}' \
      "$packages" | sort -u)"
    if [ "$bootstrap" = 1 ]; then
      [ "$(printf '%s\n' "$versions" | awk 'NF{n++} END{print n+0}')" = 1 ] \
        || fail "publish: $arch bootstrap index must retain exactly the candidate version (observed: $(printf '%s' "$versions" | tr '\n' ','))"
      printf '%s\n' "$versions" | grep -Fx "$ver" >/dev/null \
        || fail "publish: $arch bootstrap index lacks candidate version $ver"
    else
      [ "$(printf '%s\n' "$versions" | awk 'NF{n++} END{print n+0}')" = 2 ] \
        || fail "publish: $arch preview index must retain exactly candidate plus rollback version (observed: $(printf '%s' "$versions" | tr '\n' ','))"
      printf '%s\n' "$versions" | grep -Fx "$ver" >/dev/null \
        || fail "publish: $arch preview index lacks candidate version $ver"
      arch_rollback="$(printf '%s\n' "$versions" | grep -Fxv "$ver")"
      [ -n "$arch_rollback" ] || fail "publish: $arch preview rollback version is empty"
      if [ -z "$rollback_version" ]; then rollback_version="$arch_rollback"; fi
      [ "$arch_rollback" = "$rollback_version" ] \
        || fail "publish: architecture preview rollback versions differ"
      # Strict monotonicity: a preview may never replace an equal or newer one.
      if ! dpkg --compare-versions "$ver" gt "$arch_rollback"; then
        fail "publish: preview candidate $ver is not newer than the retained rollback $arch_rollback"
      fi
    fi
    gzip -n -9 -c "$packages" > "$packages.gz"
  done

  rm -f public/dists/preview/Release public/dists/preview/Release.gpg \
    public/dists/preview/InRelease
  (cd public && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Velnor \
    -o APT::FTPArchive::Release::Label=Velnor \
    -o APT::FTPArchive::Release::Suite=preview \
    -o APT::FTPArchive::Release::Codename=preview \
    -o APT::FTPArchive::Release::Architectures='amd64 arm64' \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description='apt repository for the Velnor self-hosted GitHub Actions runner (preview suite)' \
    release dists/preview) > public/dists/preview/Release
  printf '%s' "$APT_GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --local-user "$signer" --armor \
    --output public/dists/preview/Release.gpg --detach-sign public/dists/preview/Release
  printf '%s' "$APT_GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --local-user "$signer" \
    --output public/dists/preview/InRelease --clearsign public/dists/preview/Release

  # A preview has no release record to roll back to, so its previous pointer is
  # the JSON string "preview" (stable's tag/record-digest and legacy-string
  # rules do not apply here). An initialized suite has none at all: bootstrap
  # requires the JSON null pointer.
  if [ "$bootstrap" = 1 ]; then
    jq -e 'type == "null"' "$previous_pointer" >/dev/null \
      || fail "publish: bootstrap previous pointer must be JSON null"
  else
    jq -e 'type == "string" and . == "preview"' "$previous_pointer" >/dev/null \
      || fail "publish: preview previous pointer must be the JSON string \"preview\""
  fi

  emit_publication_record_preview "$version" "$incoming" "$signer" "$previous_pointer"
  log "preview publication staged in ./public and publication-record-preview.json signed; live Pages untouched"
}

# Same velnor.publication-record/v1 shape as stable, with the suite identity the
# preview channel needs. Deliberate asymmetry: stable keeps its exact historical
# record (no `suite` field), preview declares suite:"preview". `tag` is the
# literal rolling release tag, and `source_record_sha256` pins the preview
# release-manifest.json — the source-owned coherence record this channel has.
# `previous` is the JSON string "preview" once a rollback pair is retained, and
# JSON null for a bootstrapped suite that has never published before.
emit_publication_record_preview() {
  local version="$1" incoming="$2" signer="$3" previous_pointer="$4"
  local ver="${version#v}"
  local source_manifest_sha inrelease_sha
  source_manifest_sha="$(sha256 "$incoming/release-manifest.json")"
  inrelease_sha="$(sha256 public/dists/preview/InRelease)"
  local packages_json
  packages_json="$(
    for arch in $REQUIRED_ARCHES; do
      local pkgs="public/dists/preview/main/binary-${arch}/Packages"
      [ -f "$pkgs" ] && jq -n --arg a "$arch" --arg s "$(sha256 "$pkgs")" '{arch:$a, sha256:$s}'
    done | jq -s '.'
  )"
  jq -n \
    --arg schema "$PUBLICATION_SCHEMA" \
    --arg srs "$source_manifest_sha" \
    --arg tag "$PREVIEW_TAG" \
    --arg version "$ver" \
    --arg suite preview \
    --arg inrelease "$inrelease_sha" \
    --argjson packages "$packages_json" \
    --arg signer "$signer" \
    --argjson previous "$(cat "$previous_pointer")" \
    '{schema:$schema, source_record_sha256:$srs, tag:$tag, crate_version:$version,
      suite:$suite, inrelease_sha256:$inrelease, packages:$packages,
      signer_fingerprint:$signer, previous:$previous}' \
    > public/publication-record-preview.json
  printf '%s' "${APT_GPG_PASSPHRASE:-}" | \
    gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
      --local-user "$signer" --output public/publication-record-preview.json.sig \
      --detach-sign public/publication-record-preview.json
  printf '%s\n' "$ver" > public/last-publish-preview
}

emit_publication_record() {
  local version="$1" incoming="$2" signer="$3" previous_pointer="$4"
  local ver="${version#v}"
  local source_record_sha inrelease_sha
  source_record_sha="$(awk '{print $1}' "$incoming/release-record.json.sha256")"
  inrelease_sha="$(sha256 public/dists/stable/InRelease)"
  local packages_json
  packages_json="$(
    for arch in $REQUIRED_ARCHES; do
      local pkgs="public/dists/stable/main/binary-${arch}/Packages"
      [ -f "$pkgs" ] && jq -n --arg a "$arch" --arg s "$(sha256 "$pkgs")" '{arch:$a, sha256:$s}'
    done | jq -s '.'
  )"
  jq -n \
    --arg schema "$PUBLICATION_SCHEMA" \
    --arg srs "$source_record_sha" \
    --arg tag "$version" \
    --arg version "$ver" \
    --arg inrelease "$inrelease_sha" \
    --argjson packages "$packages_json" \
    --arg signer "$signer" \
    --argjson previous "$(cat "$previous_pointer")" \
    '{schema:$schema, source_record_sha256:$srs, tag:$tag, crate_version:$version,
      inrelease_sha256:$inrelease, packages:$packages, signer_fingerprint:$signer,
      previous:$previous}' > public/publication-record.json
  printf '%s' "${APT_GPG_PASSPHRASE:-}" | \
    gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
      --local-user "$signer" --output public/publication-record.json.sig \
      --detach-sign public/publication-record.json
  printf '%s\n' "$version" > public/last-publish
}

main() {
  [ $# -ge 1 ] || fail "usage: verify-release.sh <resolve-commit|download|verify|publish> ..."
  local cmd="$1"; shift
  case "$cmd" in
    resolve-commit) cmd_resolve_commit "$@" ;;
    download) cmd_download "$@" ;;
    verify) cmd_verify "$@" ;;
    publish) cmd_publish "$@" ;;
    *) fail "unknown subcommand: $cmd" ;;
  esac
}

main "$@"
