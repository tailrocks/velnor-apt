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
# Subcommands:
#   resolve-commit --version vX.Y.Z
#   download       --version vX.Y.Z --dir <incoming>
#   verify         --version vX.Y.Z --incoming <dir> --commit <sha> \
#                  --signer <live-fpr> --expect-signer <pinned-fpr> [--verify-oci]
#   publish        --version vX.Y.Z --incoming <dir> --prev-dir <dir> \
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
REQUIRED_ARCHES="amd64 arm64"

log()  { printf '%s\n' "verify-release: $*" >&2; }
fail() { printf '%s\n' "verify-release: ERROR: $*" >&2; exit 1; }

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
  local version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      *) fail "resolve-commit: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "resolve-commit: --version required"
  resolve_commit "$version"
}

cmd_download() {
  local version="" dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --dir) dir="$2"; shift 2 ;;
      *) fail "download: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "download: --version required"
  [ -n "$dir" ] || fail "download: --dir required"
  mkdir -p "$dir"
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
  local version="" incoming="" commit="" signer="" expect_signer="" verify_oci=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --incoming) incoming="$2"; shift 2 ;;
      --commit) commit="$2"; shift 2 ;;
      --signer) signer="$2"; shift 2 ;;
      --expect-signer) expect_signer="$2"; shift 2 ;;
      --verify-oci) verify_oci=1; shift ;;
      *) fail "verify: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "verify: --version required"
  [ -n "$incoming" ] || fail "verify: --incoming required"
  [ -n "$signer" ] || fail "verify: --signer required"
  [ -n "$expect_signer" ] || fail "verify: --expect-signer required"

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

    # Extracted + packaged identity: the identity files shipped INSIDE the deb
    # must agree with the resolved commit and the compiled manifest hash.
    local xdir
    xdir="$(mktemp -d)"
    extract_deb "$deb" "$xdir"
    local bi="$xdir/usr/share/velnor/build-identity.json"
    local pm="$xdir/usr/share/velnor/manifest.json"
    require_file "$bi"
    require_file "$pm"
    [ "$(jget "$bi" '.source_sha')" = "$commit" ] || fail "$arch deb build-identity source_sha != commit"
    [ "$(jget "$bi" '.crate_version')" = "$ver" ] || fail "$arch deb build-identity crate_version mismatch"
    [ "$(sha256 "$pm")" = "$record_manifest_hash" ] || fail "$arch deb packaged manifest hash != record manifest hash"
    record_bin="$(jq -er --arg a "$arch" '.architectures[] | select(.arch==$a) | .binary_sha256' "$record")"
    have_bin="$(sha256 "$xdir/usr/bin/velnor-runner")"
    [ "$have_bin" = "$record_bin" ] || fail "$arch extracted velnorctl binary hash != record binary_sha256"
    rm -rf "$xdir"
  done

  # --- current APT signer fingerprint ------------------------------------------
  # The live signing key must be the pinned publisher identity; a rotated or
  # unexpected signer stops publication rather than silently re-signing.
  local live_fpr pinned_fpr
  live_fpr="$(printf '%s' "$signer" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  pinned_fpr="$(printf '%s' "$expect_signer" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  [ "$live_fpr" = "$pinned_fpr" ] || fail "APT signer fingerprint does not match the pinned publisher key"

  # --- all checks passed: arm the reprepro sentinel ----------------------------
  : > "$incoming/.reprepro-ok"
  log "release $version is coherent — OK to reprepro (sentinel: $incoming/.reprepro-ok)"
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
  local version="" incoming="" prev_dir="" previous_pointer="" signer=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --incoming) incoming="$2"; shift 2 ;;
      --prev-dir) prev_dir="$2"; shift 2 ;;
      --previous-pointer) previous_pointer="$2"; shift 2 ;;
      --signer) signer="$2"; shift 2 ;;
      *) fail "publish: unknown arg $1" ;;
    esac
  done
  [ -n "$version" ] || fail "publish: --version required"
  [ -n "$incoming" ] || fail "publish: --incoming required"
  [ -f "$previous_pointer" ] || fail "publish: --previous-pointer required"
  [ -n "$signer" ] || fail "publish: --signer required"
  [ -f "$incoming/.reprepro-ok" ] || fail "publish: refusing — verify has not armed the reprepro sentinel"
  command -v apt-ftparchive >/dev/null 2>&1 || fail "publish: apt-ftparchive not installed"
  command -v dpkg-deb >/dev/null 2>&1 || fail "publish: dpkg-deb not installed"
  command -v gpg >/dev/null 2>&1 || fail "publish: gpg not installed"

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
