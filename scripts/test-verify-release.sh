#!/usr/bin/env bash
# Plan 010 — offline fixture tests for verify-release.sh.
#
# Every fixture here is built from independent fixed bytes (NOT the production
# release generator): a hand-written record, manifest, identity files, and
# hand-assembled .debs. This proves the verifier's coherence gate, not the
# producer. A positive case must arm the reprepro sentinel; every negative case
# must exit non-zero AND leave no sentinel (so publication never reaches reprepro
# and live Pages is never touched).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/verify-release.sh"
WORKFLOW="$HERE/../.github/workflows/release.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VERSION="v0.1.121"
VER="0.1.121"
COMMIT="1111111111111111111111111111111111111111"
SIGNER="261EDAC957DEB801000000000000000000000000"
REQUIRED_ARCHES="amd64 arm64"

pass=0
ok() { echo "ok - $1"; pass=$((pass + 1)); }
die() { echo "FAIL - $1" >&2; exit 1; }

grep -F -- 'velnor-workflow-runtime-' "$WORKFLOW" >/dev/null \
  || die "release discovery does not name the excluded runtime release family"
grep -F -- 'test("^v[0-9]+' "$WORKFLOW" >/dev/null \
  || die "release discovery does not restrict stable targets to application tags"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha256_str() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi
}

INDEX="sha256:$(sha256_str index-fixture)"
IMAGE_REF="ghcr.io/tailrocks/velnor-job-ubuntu@${INDEX}"
PLAT_AMD="sha256:$(sha256_str plat-amd64-fixture)"
PLAT_ARM="sha256:$(sha256_str plat-arm64-fixture)"
BIN_AMD="$(sha256_str runner-amd64)"
BIN_ARM="$(sha256_str runner-arm64)"

BASE="$WORK/base"
mkdir -p "$BASE"

POSTINST="$WORK/postinst"
cat > "$POSTINST" <<'SH'
#!/bin/sh
systemctl show \
  --property=CPUQuotaPerSecUSec --property=MemoryMax --property=MemoryHigh \
  --property=MemorySwapMax --property=TasksMax --value velnor-jobs.slice
SH
chmod 0755 "$POSTINST"

# --- shared identity fixtures (arch-independent, as the real deb ships) --------
cat > "$BASE/manifest.json" <<JSON
{"version":7,"source_sha":"$COMMIT","crate_version":"$VER","actions":[],"reusable_workflows":[]}
JSON
sha256_file "$BASE/manifest.json" > "$BASE/manifest.json.sha256"
MHASH="$(awk '{print $1}' "$BASE/manifest.json.sha256")"

cat > "$WORK/build-identity.json" <<JSON
{"source_sha":"$COMMIT","tag":"$VERSION","kind":"release","crate_version":"$VER"}
JSON

# Hand-assemble a .deb (ar archive with data.tar.gz) shipping the identity files.
make_fake_deb() {
  local out="$1" arch="$2" binary_bytes="${3:-runner-$2}" version="${4:-$VER}"
  local identity="${5:-$WORK/build-identity.json}" postinst="${6:-$POSTINST}"
  local control_package="${7:-velnor-runner}" control_version="${8:-$version}"
  local control_arch="${9:-$arch}"
  local stage; stage="$(mktemp -d)"
  mkdir -p "$stage/root/usr/share/velnor" "$stage/root/usr/bin"
  cp "$identity" "$stage/root/usr/share/velnor/build-identity.json"
  cp "$BASE/manifest.json" "$stage/root/usr/share/velnor/manifest.json"
  printf '%s' "$binary_bytes" > "$stage/root/usr/bin/velnor-runner"
  printf 'control-panel-%s' "$arch" > "$stage/root/usr/bin/velnorctl"
  ( cd "$stage/root" && tar -czf "$stage/data.tar.gz" . )
  mkdir -p "$stage/ctl"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' \
    "$control_package" "$control_version" "$control_arch" > "$stage/ctl/control"
  cp "$postinst" "$stage/ctl/postinst"
  chmod 0755 "$stage/ctl/postinst"
  ( cd "$stage/ctl" && tar -czf "$stage/control.tar.gz" . )
  printf '2.0\n' > "$stage/debian-binary"
  ( cd "$stage" && rm -f "$out" && ar rcS "$out" debian-binary control.tar.gz data.tar.gz )
  rm -rf "$stage"
}

for arch in $REQUIRED_ARCHES; do
  deb="$BASE/velnor-runner-${VER}-${arch}.deb"
  make_fake_deb "$deb" "$arch"
  sha256_file "$deb" > "$deb.sha256"
done
DEB_HASH_amd64="$(awk '{print $1}' "$BASE/velnor-runner-${VER}-amd64.deb.sha256")"
DEB_HASH_arm64="$(awk '{print $1}' "$BASE/velnor-runner-${VER}-arm64.deb.sha256")"

# --- the release record binding it all together --------------------------------
jq -n \
  --arg schema "velnor.release-record/v1" \
  --arg repo "tailrocks/velnor" \
  --arg tag "$VERSION" --arg commit "$COMMIT" --arg version "$VER" \
  --argjson mv 7 --arg mhash "$MHASH" \
  --arg bin_amd64 "$BIN_AMD" --arg deb_amd64 "$DEB_HASH_amd64" --arg plat_amd64 "$PLAT_AMD" \
  --arg bin_arm64 "$BIN_ARM" --arg deb_arm64 "$DEB_HASH_arm64" --arg plat_arm64 "$PLAT_ARM" \
  --arg index "$INDEX" --arg ref "$IMAGE_REF" --arg source "https://github.com/tailrocks/velnor" \
  '{
    schema:$schema,
    build:{repository:$repo,tag:$tag,commit:$commit,crate_version:$version,
           debian_version:$version,manifest_version:$mv,manifest_sha256:$mhash},
    architectures:[
      {arch:"amd64",target:"x86_64-unknown-linux-gnu",binary_sha256:$bin_amd64,deb_sha256:$deb_amd64,oci_platform_digest:$plat_amd64},
      {arch:"arm64",target:"aarch64-unknown-linux-gnu",binary_sha256:$bin_arm64,deb_sha256:$deb_arm64,oci_platform_digest:$plat_arm64}
    ],
    oci_index_digest:$index, oci_image_ref:$ref,
    oci_labels:{version:$version,revision:$commit,source:$source,manifest_sha256:$mhash},
    apt:{origin:"Velnor",suite:"stable",component:"main"}
  }' > "$BASE/release-record.json"
sha256_file "$BASE/release-record.json" > "$BASE/release-record.json.sha256"

fresh_copy() {
  local dir="$WORK/$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp -R "$BASE/." "$dir/"
  printf '%s' "$dir"
}

refresh_stable_amd64_deb() {
  local dir="$1" postinst="$2" package="$3" control_version="$4"
  local control_arch="$5" binary_bytes="${6:-runner-amd64}"
  make_fake_deb "$dir/velnor-runner-${VER}-amd64.deb" amd64 "$binary_bytes" "$VER" \
    "$WORK/build-identity.json" "$postinst" "$package" "$control_version" "$control_arch"
  local hash
  hash="$(sha256_file "$dir/velnor-runner-${VER}-amd64.deb")"
  printf '%s\n' "$hash" > "$dir/velnor-runner-${VER}-amd64.deb.sha256"
  jq --arg h "$hash" '(.architectures[] | select(.arch=="amd64") | .deb_sha256) |= $h' \
    "$dir/release-record.json" > "$dir/release-record.json.tmp"
  mv "$dir/release-record.json.tmp" "$dir/release-record.json"
  sha256_file "$dir/release-record.json" > "$dir/release-record.json.sha256"
}

run_verify() { # dir + extra args -> exit code
  local dir="$1"; shift
  bash "$SCRIPT" verify --version "$VERSION" --incoming "$dir" --commit "$COMMIT" \
    --signer "$SIGNER" --expect-signer "$SIGNER" "$@" >/dev/null 2>&1
}

OCI_BIN="$WORK/oci-bin"
mkdir -p "$OCI_BIN"
cat > "$OCI_BIN/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2 $3" = "buildx imagetools inspect" ]
ref="$4"
if [ "$ref" = "$MOCK_IMAGE_REF" ]; then
  jq -n \
    --arg index "$MOCK_INDEX" --arg amd "$MOCK_AMD" --arg arm "$MOCK_ARM" \
    '{manifest:{digest:$index,manifests:[
      {digest:$amd,platform:{os:"linux",architecture:"amd64"}},
      {digest:$arm,platform:{os:"linux",architecture:"arm64"}}
    ]}}'
  exit
fi
digest="${ref##*@}"
case "$digest" in
  "$MOCK_AMD") arch=amd64 ;;
  "$MOCK_ARM") arch=arm64 ;;
  *) exit 1 ;;
esac
version="$MOCK_VERSION"
[ "${MOCK_BAD_ARCH:-}" != "$arch" ] || version=wrong
jq -n \
  --arg digest "$digest" --arg version "$version" --arg revision "$MOCK_COMMIT" \
  --arg source "$MOCK_SOURCE" --arg mhash "$MOCK_MHASH" \
  '{manifest:{digest:$digest},image:{config:{Labels:{
    "org.opencontainers.image.version":$version,
    "org.opencontainers.image.revision":$revision,
    "org.opencontainers.image.source":$source,
    "org.velnor.manifest-sha256":$mhash
  }}}}'
SH
chmod +x "$OCI_BIN/docker"

run_verify_live() {
  local dir="$1" bad_arch="${2:-}"
  PATH="$OCI_BIN:$PATH" \
    MOCK_IMAGE_REF="$IMAGE_REF" MOCK_INDEX="$INDEX" MOCK_AMD="$PLAT_AMD" \
    MOCK_ARM="$PLAT_ARM" MOCK_VERSION="$VER" MOCK_COMMIT="$COMMIT" \
    MOCK_SOURCE="https://github.com/tailrocks/velnor" MOCK_MHASH="$MHASH" \
    MOCK_BAD_ARCH="$bad_arch" \
    bash "$SCRIPT" verify --version "$VERSION" --incoming "$dir" --commit "$COMMIT" \
      --signer "$SIGNER" --expect-signer "$SIGNER" --verify-oci >/dev/null 2>&1
}

expect_reject() { # desc dir [extra args...]
  local desc="$1" dir="$2"; shift 2
  if run_verify "$dir" "$@"; then die "expected rejection but verify passed: $desc"; fi
  [ ! -f "$dir/.reprepro-ok" ] || die "sentinel armed despite rejection: $desc"
  ok "rejected: $desc"
}

# ============================ positive ========================================
POS="$(fresh_copy positive)"
run_verify "$POS" || die "positive fixture should verify"
[ -f "$POS/.reprepro-ok" ] || die "positive fixture did not arm the reprepro sentinel"
ok "coherent release verifies and arms the sentinel"

POS_NORMALIZED="$(fresh_copy positive_normalized_signer)"
if ! bash "$SCRIPT" verify --version "$VERSION" --incoming "$POS_NORMALIZED" --commit "$COMMIT" \
     --signer "261e dac9 57de b801 0000 0000 0000 0000 0000 0000" \
     --expect-signer "$SIGNER" >/dev/null 2>&1; then
  die "case and spaces in a full signer fingerprint should be accepted"
fi
ok "full signer fingerprint accepts normalized case and spaces"

POS_OCI="$(fresh_copy positive_oci)"
run_verify_live "$POS_OCI" || die "multi-platform live OCI fixture should verify"
[ -f "$POS_OCI/.reprepro-ok" ] || die "live OCI fixture did not arm the sentinel"
ok "live OCI index binds and verifies both platform configs"

D="$(fresh_copy neg_oci_platform_label)"
if run_verify_live "$D" arm64; then
  die "expected rejection on one platform's OCI label drift"
fi
[ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on OCI platform label drift"
ok "rejected: one OCI platform label differs from the release record"

# ============================ negatives =======================================

# Stable packages must carry the expected control metadata, independent of
# their filenames and checksums.
for control_case in package version architecture; do
  D="$(fresh_copy "neg_stable_control_$control_case")"
  control_package=velnor-runner
  control_version="$VER"
  control_arch=amd64
  case "$control_case" in
    package) control_package=other-package ;;
    version) control_version=0.1.120 ;;
    architecture) control_arch=arm64 ;;
  esac
  refresh_stable_amd64_deb "$D" "$POSTINST" "$control_package" "$control_version" "$control_arch"
  expect_reject "stable deb control $control_case mismatch" "$D"
done

# Each stable architecture must bind to its exact Linux compilation target.
for target_arch in $REQUIRED_ARCHES; do
  D="$(fresh_copy "neg_target_$target_arch")"
  case "$target_arch" in
    amd64) bad_target=aarch64-unknown-linux-gnu ;;
    arm64) bad_target=x86_64-unknown-linux-gnu ;;
  esac
  jq --arg arch "$target_arch" --arg target "$bad_target" \
    '.architectures |= map(if .arch == $arch then .target = $target else . end)' \
    "$D/release-record.json" > "$D/release-record.json.tmp"
  mv "$D/release-record.json.tmp" "$D/release-record.json"
  sha256_file "$D/release-record.json" > "$D/release-record.json.sha256"
  expect_reject "stable $target_arch target is not the expected Linux target" "$D"
done

# Stable record APT identity is fixed to the Velnor stable/main publication.
for apt_field in origin suite component; do
  D="$(fresh_copy "neg_apt_$apt_field")"
  case "$apt_field" in
    origin) bad_apt=Other ;;
    suite) bad_apt=preview ;;
    component) bad_apt=contrib ;;
  esac
  jq --arg field "$apt_field" --arg value "$bad_apt" \
    '.apt[$field] = $value' "$D/release-record.json" > "$D/release-record.json.tmp"
  mv "$D/release-record.json.tmp" "$D/release-record.json"
  sha256_file "$D/release-record.json" > "$D/release-record.json.sha256"
  expect_reject "stable record apt.$apt_field is not the expected identity" "$D"
done

# 1. record checksum mismatch (tamper record, keep old sidecar)
D="$(fresh_copy neg_record)"; printf ' ' >> "$D/release-record.json"
expect_reject "tampered record fails checksum" "$D"

# A failed revalidation must clear a sentinel left by an earlier attempt.
D="$(fresh_copy neg_stale_sentinel)"
: > "$D/.reprepro-ok"
printf ' ' >> "$D/release-record.json"
expect_reject "failed revalidation clears a stale sentinel" "$D"

# 2. deb hash mismatch (tamper a deb, keep sidecar + record)
D="$(fresh_copy neg_deb)"; printf 'x' >> "$D/velnor-runner-${VER}-amd64.deb"
expect_reject "tampered deb fails hash" "$D"

# 3. independently-resolved commit disagrees with the record
D="$(fresh_copy neg_commit)"
if bash "$SCRIPT" verify --version "$VERSION" --incoming "$D" \
     --commit 2222222222222222222222222222222222222222 \
     --signer "$SIGNER" --expect-signer "$SIGNER" >/dev/null 2>&1; then
  die "expected rejection on commit drift"
fi
[ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on commit drift"
ok "rejected: resolved commit disagrees with record"

# 4. missing record entirely
D="$(fresh_copy neg_missing)"; rm -f "$D/release-record.json"
expect_reject "missing record fails closed" "$D"

# 5. an extra (third) deb present
D="$(fresh_copy neg_extra)"; cp "$D/velnor-runner-${VER}-amd64.deb" "$D/velnor-runner-${VER}-armhf.deb"
expect_reject "extra deb is rejected" "$D"

# 6. manifest hash disagrees with the record (valid sidecar, wrong content)
D="$(fresh_copy neg_manifest)"
printf '{"version":7,"source_sha":"%s","crate_version":"%s","actions":[1],"reusable_workflows":[]}' "$COMMIT" "$VER" > "$D/manifest.json"
sha256_file "$D/manifest.json" > "$D/manifest.json.sha256"
expect_reject "manifest hash != record manifest hash" "$D"

# 7. signer fingerprint mismatch
D="$(fresh_copy neg_signer)"
if bash "$SCRIPT" verify --version "$VERSION" --incoming "$D" --commit "$COMMIT" \
     --signer "$SIGNER" --expect-signer "DEADBEEFDEADBEEF000000000000000000000000" >/dev/null 2>&1; then
  die "expected rejection on signer mismatch"
fi
[ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on signer mismatch"
ok "rejected: APT signer fingerprint mismatch"

for bad_signer in "DEADBEEFDEADBEEF" "not-a-fingerprint"; do
  D="$(fresh_copy "neg_signer_format_${bad_signer//[^[:alnum:]]/_}")"
  if bash "$SCRIPT" verify --version "$VERSION" --incoming "$D" --commit "$COMMIT" \
       --signer "$bad_signer" --expect-signer "$bad_signer" >/dev/null 2>&1; then
    die "expected rejection on short or malformed signer fingerprint: $bad_signer"
  fi
  [ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on invalid signer fingerprint: $bad_signer"
  ok "rejected: invalid signer fingerprint ($bad_signer)"
done

# 8. OCI image ref does not pin the index digest
D="$(fresh_copy neg_oci)"
jq '.oci_image_ref="ghcr.io/tailrocks/velnor-job-ubuntu@sha256:0000000000000000000000000000000000000000000000000000000000000000"' \
  "$D/release-record.json" > "$D/release-record.json.tmp"
mv "$D/release-record.json.tmp" "$D/release-record.json"
sha256_file "$D/release-record.json" > "$D/release-record.json.sha256"
expect_reject "OCI ref not pinning the index digest" "$D"

# 9. extracted/packaged identity inside the deb disagrees with the commit
D="$(fresh_copy neg_identity)"
# Rebuild the amd64 deb with a build-identity whose source_sha is wrong, then
# refresh its sidecar + the record's deb hash so only the EXTRACTED identity is
# inconsistent (isolating the packaged-identity check).
BAD_STAGE="$(mktemp -d)"
mkdir -p "$BAD_STAGE/root/usr/share/velnor" "$BAD_STAGE/root/usr/bin"
printf '{"source_sha":"%s","tag":"%s","kind":"release","crate_version":"%s"}' \
  "3333333333333333333333333333333333333333" "$VERSION" "$VER" \
  > "$BAD_STAGE/root/usr/share/velnor/build-identity.json"
cp "$BASE/manifest.json" "$BAD_STAGE/root/usr/share/velnor/manifest.json"
printf 'runner-amd64' > "$BAD_STAGE/root/usr/bin/velnor-runner"
printf 'control-panel-amd64' > "$BAD_STAGE/root/usr/bin/velnorctl"
( cd "$BAD_STAGE/root" && tar -czf "$BAD_STAGE/data.tar.gz" . )
mkdir -p "$BAD_STAGE/ctl"
printf 'Package: velnor-runner\nVersion: %s\nArchitecture: amd64\n' "$VER" > "$BAD_STAGE/ctl/control"
cp "$POSTINST" "$BAD_STAGE/ctl/postinst"
( cd "$BAD_STAGE/ctl" && tar -czf "$BAD_STAGE/control.tar.gz" . )
printf '2.0\n' > "$BAD_STAGE/debian-binary"
( cd "$BAD_STAGE" && rm -f "$D/velnor-runner-${VER}-amd64.deb" && ar rcS "$D/velnor-runner-${VER}-amd64.deb" debian-binary control.tar.gz data.tar.gz )
NEWHASH="$(sha256_file "$D/velnor-runner-${VER}-amd64.deb")"
printf '%s\n' "$NEWHASH" > "$D/velnor-runner-${VER}-amd64.deb.sha256"
jq --arg h "$NEWHASH" '(.architectures[] | select(.arch=="amd64") | .deb_sha256) |= $h' \
  "$D/release-record.json" > "$D/release-record.json.tmp"
mv "$D/release-record.json.tmp" "$D/release-record.json"
sha256_file "$D/release-record.json" > "$D/release-record.json.sha256"
rm -rf "$BAD_STAGE"
expect_reject "packaged identity inside the deb disagrees with the commit" "$D"

# 10. postinst must declare all five workload-slice quota properties. This is a
# static package-contract check; it does not prove the installed limits are
# effective at runtime.
for missing_quota in CPUQuotaPerSecUSec MemoryMax MemoryHigh MemorySwapMax TasksMax; do
  D="$(fresh_copy "neg_postinst_$missing_quota")"
  BAD_POSTINST="$WORK/postinst-missing-$missing_quota"
  grep -F -v -- "--property=$missing_quota" "$POSTINST" > "$BAD_POSTINST"
  chmod 0755 "$BAD_POSTINST"
  refresh_stable_amd64_deb "$D" "$BAD_POSTINST" velnor-runner "$VER" amd64
  expect_reject "postinst missing $missing_quota declaration" "$D"
done

# 11. extracted binary bytes disagree with the independently recorded digest.
D="$(fresh_copy neg_binary)"
make_fake_deb "$D/velnor-runner-${VER}-amd64.deb" amd64 tampered-runner
NEWHASH="$(sha256_file "$D/velnor-runner-${VER}-amd64.deb")"
printf '%s\n' "$NEWHASH" > "$D/velnor-runner-${VER}-amd64.deb.sha256"
jq --arg h "$NEWHASH" '(.architectures[] | select(.arch=="amd64") | .deb_sha256) |= $h' \
  "$D/release-record.json" > "$D/release-record.json.tmp"
mv "$D/release-record.json.tmp" "$D/release-record.json"
sha256_file "$D/release-record.json" > "$D/release-record.json.sha256"
expect_reject "extracted runner binary disagrees with record" "$D"

# 12. publication writes the signed record and rollback pointer into the Pages
# artifact, not the checkout. Fake only the external signer/reprepro boundary;
# candidate bytes and release record remain the independently-built fixture.
PUB="$WORK/publish"
mkdir -p "$PUB/bin" "$PUB/run" "$PUB/previous"
cp -R "$POS/." "$PUB/run/"
PREVIOUS_RECORD_SHA="$(sha256_str previous-record)"
jq -n --arg tag v0.1.120 --arg sha "$PREVIOUS_RECORD_SHA" \
  '{tag:$tag, source_record_sha256:$sha}' > "$PUB/previous-pointer.json"
for arch in $REQUIRED_ARCHES; do
  make_fake_deb "$PUB/previous/velnor-runner_0.1.120_$arch.deb" "$arch" \
    "runner-$arch-previous" "0.1.120"
done
cat > "$PUB/bin/apt-ftparchive" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "-a" ]; then
  arch="$2"
  for deb in pool/main/v/velnor-runner/*[-_]"$arch".deb; do
    version="$(basename "$deb" | sed -E 's/^velnor-runner[-_]([0-9.]+)[-_].*$/\1/')"
    printf 'Package: velnor-runner\nVersion: %s\nArchitecture: %s\nFilename: %s\nSHA256: fixture\n\n' \
      "$version" "$arch" "$deb"
  done
else
  printf 'Origin: Velnor\nSuite: stable\nCodename: stable\n'
fi
SH
cat > "$PUB/bin/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -f ]
name="$(basename "$2")"
field="$3"
version="$(printf '%s' "$name" | sed -E 's/^velnor-runner[-_]([0-9.]+)[-_].*$/\1/')"
arch="$(printf '%s' "$name" | sed -E 's/^.*[-_](amd64|arm64)\.deb$/\1/')"
case "$field" in
  Package) printf '%s\n' velnor-runner ;;
  Version) printf '%s\n' "$version" ;;
  Architecture) printf '%s\n' "$arch" ;;
  *) exit 1 ;;
esac
SH
cat > "$PUB/bin/gpg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ]
printf 'detached-signature\n' > "$out"
SH
cat > "$PUB/bin/gpgconf" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2" = "--kill gpg-agent" ]
SH
chmod +x "$PUB/bin/apt-ftparchive" "$PUB/bin/dpkg-deb" "$PUB/bin/gpg" "$PUB/bin/gpgconf"
(
  cd "$PUB/run"
  PATH="$PUB/bin:$PATH" APT_GPG_PASSPHRASE='fixture-passphrase' \
    bash "$SCRIPT" publish --version "$VERSION" --incoming . \
      --prev-dir "$PUB/previous" --previous-pointer "$PUB/previous-pointer.json" \
      --signer "$SIGNER"
)
[ -f "$PUB/run/public/publication-record.json" ] || die "publication record missing from Pages tree"
[ -f "$PUB/run/public/publication-record.json.sig" ] || die "publication signature missing from Pages tree"
[ "$(cat "$PUB/run/public/last-publish")" = "$VERSION" ] || die "published current-version pointer mismatch"
[ "$(jq -r .previous.tag "$PUB/run/public/publication-record.json")" = "v0.1.120" ] \
  || die "publication record rollback pointer mismatch"
[ "$(jq -r .previous.source_record_sha256 "$PUB/run/public/publication-record.json")" = "$PREVIOUS_RECORD_SHA" ] \
  || die "publication record rollback digest mismatch"
[ "$(jq -r .schema "$PUB/run/public/publication-record.json")" = "velnor.publication-record/v1" ] \
  || die "publication record schema mismatch"
[ "$(find "$PUB/run/public/pool" -type f -name '*.deb' | wc -l | tr -d ' ')" = "4" ] \
  || die "candidate and rollback package pairs were not both staged"
for arch in $REQUIRED_ARCHES; do
  [ "$(awk '$1=="Version:"{print $2}' "$PUB/run/public/dists/stable/main/binary-$arch/Packages" | sort -u | wc -l | tr -d ' ')" = 2 ] \
    || die "$arch signed index does not retain two versions"
done
ok "publication signs candidate and exact rollback pair into both indexes"

PUB_NO_PASS="$WORK/publish-no-passphrase"
mkdir -p "$PUB_NO_PASS"
cp -R "$POS/." "$PUB_NO_PASS/"
if (
  cd "$PUB_NO_PASS"
  PATH="$PUB/bin:$PATH" APT_GPG_PASSPHRASE='' \
    bash "$SCRIPT" publish --version "$VERSION" --incoming . \
      --prev-dir "$PUB/previous" --previous-pointer "$PUB/previous-pointer.json" \
      --signer "$SIGNER" >/dev/null 2>&1
); then
  die "publication accepted an empty signer passphrase"
fi
[ ! -e "$PUB_NO_PASS/public" ] \
  || die "publication mutated staging before signer unlock"
ok "publication fails before staging mutation without a signer passphrase"

# ============================ preview suite ===================================
# The rolling `preview` release has no tag and no release record: its coherence
# chain is release-manifest.json + the per-deb sidecars + SHA256SUMS + the
# build-identity shipped inside each deb, all bound to the caller-supplied main
# commit. Same sentinel contract as stable: positive arms it, negatives exit
# non-zero without it.
PVERSION="0.1.274~preview.42+abc1234"
PBASE="0.1.274"
PCOMMIT="abc1234000000000000000000000000000000000"

# GitHub rewrites release asset names on upload (`~` becomes `.`), so the
# fixture files must carry the dotted names the platform actually serves while
# every version argument stays the tilde contract.
preview_asset() { # <version> <arch> -> dotted preview asset name
  printf 'velnor-runner-preview-%s-%s.deb\n' "${1//'~'/.}" "$2"
}

refresh_preview_metadata() { # <dir> <version> <commit> — rebuild sidecars,
  local dir="$1" ver="$2" commit="$3" arch name rname deb hash assets  # SHA256SUMS and
  assets="$WORK/preview-assets.$$"                                     # release-manifest
  : > "$assets"
  : > "$dir/SHA256SUMS"
  for arch in $REQUIRED_ARCHES; do
    name="$(preview_asset "$ver" "$arch")"
    # The source release binds the tilde asset name in SHA256SUMS and the
    # release manifest (GitHub normalizes only uploaded filenames) and writes
    # digest-only sidecars; mirror that exactly.
    rname="velnor-runner-preview-${ver}-${arch}.deb"
    deb="$dir/$name"
    hash="$(sha256_file "$deb")"
    printf '%s\n' "$hash" > "$deb.sha256"
    printf '%s  %s\n' "$hash" "$rname" >> "$dir/SHA256SUMS"
    jq -cn --arg name "$rname" --arg sha256 "$hash" '{name:$name,sha256:$sha256}' >> "$assets"
  done
  jq -Sn --arg source_repository "tailrocks/velnor" --arg source_ref "refs/heads/main" \
    --arg source_commit "$commit" --arg version "$ver" --slurpfile assets "$assets" \
    '{schema:"velnor.package-release.v1", source_repository:$source_repository,
      source_ref:$source_ref, source_commit:$source_commit, version:$version,
      assets:$assets}' > "$dir/release-manifest.json"
  rm -f "$assets"
}

build_preview_fixture() { # <dir> <version> <commit> [identity_source_sha]
  local dir="$1" ver="$2" commit="$3" arch
  local identity_sha="${4:-$commit}"
  local base="${ver%%~*}"
  local stage="$WORK/preview-stage.$$"
  rm -rf "$stage"; mkdir -p "$stage"
  printf '{"source_sha":"%s","source_ref":"refs/heads/main","kind":"preview","crate_version":"%s"}\n' \
    "$identity_sha" "$base" > "$stage/build-identity.json"
  rm -rf "$dir"; mkdir -p "$dir"
  for arch in $REQUIRED_ARCHES; do
    make_fake_deb "$dir/$(preview_asset "$ver" "$arch")" "$arch" \
      "preview-runner-$arch" "$ver" "$stage/build-identity.json"
  done
  refresh_preview_metadata "$dir" "$ver" "$commit"
  rm -rf "$stage"
}

preview_copy() {
  local dir="$WORK/$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp -R "$PBASE/." "$dir/"
  printf '%s\n' "$dir"
}

run_verify_preview() { # dir + extra args -> exit code
  local dir="$1"; shift
  bash "$SCRIPT" verify --suite preview --version "$PVERSION" --incoming "$dir" \
    --commit "$PCOMMIT" --signer "$SIGNER" --expect-signer "$SIGNER" "$@" >/dev/null 2>&1
}

expect_reject_preview() { # desc dir [extra args...]
  local desc="$1" dir="$2"; shift 2
  if run_verify_preview "$dir" "$@"; then
    die "expected rejection but preview verify passed: $desc"
  fi
  [ ! -f "$dir/.reprepro-ok" ] || die "sentinel armed despite preview rejection: $desc"
  ok "preview rejected: $desc"
}

PBASE="$WORK/preview-base"
build_preview_fixture "$PBASE" "$PVERSION" "$PCOMMIT"

PP="$(preview_copy preview_positive)"
run_verify_preview "$PP" || die "coherent preview fixture should verify"
[ -f "$PP/.reprepro-ok" ] || die "positive preview fixture did not arm the reprepro sentinel"
ok "coherent preview release verifies and arms the sentinel"

# Preview verify is commit-driven: there is no tag to resolve, so a missing or
# malformed commit must stop before any publication path.
D="$(preview_copy neg_preview_no_commit)"
if bash "$SCRIPT" verify --suite preview --version "$PVERSION" --incoming "$D" \
     --signer "$SIGNER" --expect-signer "$SIGNER" >/dev/null 2>&1; then
  die "expected rejection when the preview commit is missing"
fi
[ ! -f "$D/.reprepro-ok" ] || die "sentinel armed without a preview commit"
ok "preview rejected: no commit supplied (there is no tag to resolve)"

D="$(preview_copy neg_preview_suffix)"
if bash "$SCRIPT" verify --suite preview --version "$PVERSION" --incoming "$D" \
     --commit "ffffffffffffffffffffffffffffffffffffffff" \
     --signer "$SIGNER" --expect-signer "$SIGNER" >/dev/null 2>&1; then
  die "expected rejection when the version suffix does not match the commit"
fi
[ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on preview version/commit drift"
ok "preview rejected: version suffix does not abbreviate the supplied commit"

for bad_version in "0.1.274-preview.42+abc1234" "v0.1.274~preview.42+abc1234" \
                   "0.1.274~preview.42+abc123" "0.1.274~preview.42"; do
  D="$(preview_copy neg_preview_grammar)"
  if bash "$SCRIPT" verify --suite preview --version "$bad_version" --incoming "$D" \
       --commit "$PCOMMIT" --signer "$SIGNER" --expect-signer "$SIGNER" >/dev/null 2>&1; then
    die "expected rejection of off-grammar preview version: $bad_version"
  fi
  [ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on off-grammar preview version: $bad_version"
done
ok "preview rejected: version grammar (separator, v-prefix, short/absent commit)"

D="$(preview_copy neg_preview_manifest_version)"
jq --arg v "0.1.274~preview.43+abc1234" '.version = $v' "$D/release-manifest.json" \
  > "$D/release-manifest.json.tmp"
mv "$D/release-manifest.json.tmp" "$D/release-manifest.json"
expect_reject_preview "release-manifest version != requested preview version" "$D"

D="$(preview_copy neg_preview_sidecar)"
printf 'x' >> "$D/$(preview_asset "$PVERSION" amd64)"
expect_reject_preview "tampered preview deb fails its sidecar checksum" "$D"

# A sidecar that DOES carry a name field must name the right deb (velnor ships
# digest-only sidecars; a named sidecar is still valid input).
D="$(preview_copy neg_preview_sidecar_name)"
printf '%s  %s\n' "$(sha256_file "$D/$(preview_asset "$PVERSION" amd64)")" \
  "velnor-runner-preview-${PBASE}-amd64.deb" > "$D/$(preview_asset "$PVERSION" amd64).sha256"
expect_reject_preview "preview sidecar names a different deb than its own" "$D"

# The digest-only sidecar form velnor actually publishes must verify (the
# positive fixture above already uses it; assert the named variant too).
D="$(preview_copy pos_preview_named_sidecar)"
printf '%s  %s\n' "$(sha256_file "$D/$(preview_asset "$PVERSION" amd64)")" \
  "$(preview_asset "$PVERSION" amd64)" > "$D/$(preview_asset "$PVERSION" amd64).sha256"
run_verify_preview "$D" || die "named sidecar preview fixture should verify"
ok "preview accepted: named sidecar variant"

D="$(preview_copy neg_preview_extra)"
cp "$D/$(preview_asset "$PVERSION" amd64)" \
  "$D/$(preview_asset "$PVERSION" armhf)"
expect_reject_preview "extra preview deb is rejected" "$D"

D="$(preview_copy neg_preview_ref)"
jq '.source_ref = "refs/tags/v0.1.274"' "$D/release-manifest.json" \
  > "$D/release-manifest.json.tmp"
mv "$D/release-manifest.json.tmp" "$D/release-manifest.json"
expect_reject_preview "preview release-manifest source_ref is not refs/heads/main" "$D"

D="$(preview_copy neg_preview_repo)"
jq '.source_repository = "tailrocks/other"' "$D/release-manifest.json" \
  > "$D/release-manifest.json.tmp"
mv "$D/release-manifest.json.tmp" "$D/release-manifest.json"
expect_reject_preview "preview release-manifest source_repository mismatch" "$D"

D="$(preview_copy neg_preview_commit)"
jq --arg c "bbbbbbb000000000000000000000000000000000" '.source_commit = $c' \
  "$D/release-manifest.json" > "$D/release-manifest.json.tmp"
mv "$D/release-manifest.json.tmp" "$D/release-manifest.json"
expect_reject_preview "preview release-manifest commit != supplied commit" "$D"

# Only the EXTRACTED identity may disagree: rebuild a deb whose packaged
# build-identity carries a foreign commit, then re-pin its bytes in the sidecar,
# SHA256SUMS, and the manifest asset hash.
D="$(preview_copy neg_preview_identity)"
BAD_STAGE="$WORK/preview-bad-stage"
rm -rf "$BAD_STAGE"; mkdir -p "$BAD_STAGE"
printf '{"source_sha":"%s","source_ref":"refs/heads/main","kind":"preview","crate_version":"%s"}\n' \
  "ccccccc000000000000000000000000000000000" "$PBASE" \
  > "$BAD_STAGE/build-identity.json"
make_fake_deb "$D/$(preview_asset "$PVERSION" amd64)" amd64 \
  "preview-runner-amd64" "$PVERSION" "$BAD_STAGE/build-identity.json"
refresh_preview_metadata "$D" "$PVERSION" "$PCOMMIT"
rm -rf "$BAD_STAGE"
expect_reject_preview "preview deb build-identity source_sha disagrees with the commit" "$D"

D="$(preview_copy neg_preview_identity_version)"
BAD_STAGE="$WORK/preview-bad-stage-version"
rm -rf "$BAD_STAGE"; mkdir -p "$BAD_STAGE"
printf '{"source_sha":"%s","source_ref":"refs/heads/main","kind":"preview","crate_version":"%s"}\n' \
  "$PCOMMIT" "0.1.273" > "$BAD_STAGE/build-identity.json"
make_fake_deb "$D/$(preview_asset "$PVERSION" amd64)" amd64 \
  "preview-runner-amd64" "$PVERSION" "$BAD_STAGE/build-identity.json"
refresh_preview_metadata "$D" "$PVERSION" "$PCOMMIT"
rm -rf "$BAD_STAGE"
expect_reject_preview "preview deb build-identity crate_version != preview base version" "$D"

for control_case in package version architecture; do
  D="$(preview_copy "neg_preview_control_$control_case")"
  control_package=velnor-runner
  control_version="$PVERSION"
  control_arch=amd64
  case "$control_case" in
    package) control_package=other-package ;;
    version) control_version=0.1.274~preview.41+abc1234 ;;
    architecture) control_arch=arm64 ;;
  esac
  make_fake_deb "$D/$(preview_asset "$PVERSION" amd64)" amd64 \
    "preview-runner-amd64" "$PVERSION" "$WORK/build-identity.json" "$POSTINST" \
    "$control_package" "$control_version" "$control_arch"
  refresh_preview_metadata "$D" "$PVERSION" "$PCOMMIT"
  expect_reject_preview "preview deb control $control_case mismatch" "$D"
done

D="$(preview_copy neg_preview_sums)"
printf '%s  %s\n' "$(sha256_str stray)" \
  "$(preview_asset "$PVERSION" amd64)" >> "$D/SHA256SUMS"
expect_reject_preview "SHA256SUMS carries more than the two preview deb lines" "$D"

# --- preview publication: one shared tree, per-suite subcommand ---------------
# The caller assembles ./public by running publish once per suite, so preview
# must stage into the tree stable already built and leave every stable artifact
# byte-identical.
PUBP="$WORK/publish-preview"
mkdir -p "$PUBP/bin" "$PUBP/run" "$PUBP/preview-previous" "$PUBP/preview-incoming"
cp -R "$POS/." "$PUBP/run/"
cp -R "$PBASE/." "$PUBP/preview-incoming/"
printf '%s\n' '"preview"' > "$PUBP/preview-pointer.json"
PREVIEW_ROLLBACK="0.1.274~preview.41+abc1234"
build_preview_fixture "$PUBP/preview-previous" "$PREVIEW_ROLLBACK" "$PCOMMIT"

cat > "$PUBP/bin/apt-ftparchive" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "-a" ]; then
  arch="$2"
  for deb in "$4"/main/v/velnor-runner/*.deb; do
    [ -f "$deb" ] || continue
    name="$(basename "$deb" .deb)"
    parch="$(printf '%s' "$name" | sed -E 's/^.*[-_]([^-_]+)$/\1/')"
    [ "$parch" = "$arch" ] || continue
    version="$(printf '%s' "${name%_"$parch"}" | sed -E 's/^velnor-runner(-preview)?[-_]//')"
    printf 'Package: velnor-runner\nVersion: %s\nArchitecture: %s\nFilename: %s\nSHA256: fixture\n\n' \
      "$version" "$parch" "$deb"
  done
else
  suite=stable
  case "${2:-}" in dists/preview) suite=preview ;; esac
  printf 'Origin: Velnor\nSuite: %s\nCodename: %s\n' "$suite" "$suite"
fi
SH
cat > "$PUBP/bin/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -f ] || exit 1
name="$(basename "$2" .deb)"
field="$3"
arch="$(printf '%s' "$name" | sed -E 's/^.*[-_]([^-_]+)$/\1/')"
version="$(printf '%s' "${name%[-_]"$arch"}" | sed -E 's/^velnor-runner(-preview)?[-_]//')"
# GitHub rewrites release asset names on upload (`~` -> `.`); the control
# Version still carries the tilde contract, so decode the preview asset form
# back before reporting it. Only the `~preview.` dot maps, so stable versions
# (all dots) are untouched.
version="${version/\.preview\./~preview.}"
case "$field" in
  Package) printf '%s\n' velnor-runner ;;
  Version) printf '%s\n' "$version" ;;
  Architecture) printf '%s\n' "$arch" ;;
  *) exit 1 ;;
esac
SH
cat > "$PUBP/bin/dpkg" <<'SH'
#!/usr/bin/env bash
# Stand-in for `dpkg --compare-versions`: implements dpkg's verrevcmp ordering
# (~ sorts before end-of-string, numeric runs compare numerically, non-digits by
# the dpkg order table) so the preview monotonicity gate is exercised for real.
set -euo pipefail
[ "${1:-}" = "--compare-versions" ] || { echo "fake dpkg: unsupported call" >&2; exit 1; }
left="$2" op="$3" right="$4"
export FAKE_LEFT="$left" FAKE_OP="$op" FAKE_RIGHT="$right"
awk '
function dpkg_order(c) {
  if (c == "~") return -1
  if (c ~ /[A-Za-z]/) return index(ASCII, c) + 31
  return index(ASCII, c) + 31 + 256
}
function vercmp(x, y,   lx, ly, i, j, first_diff, xc, yc) {
  lx = length(x); ly = length(y); i = 1; j = 1
  while (i <= lx || j <= ly) {
    first_diff = 0
    while ((i <= lx && substr(x, i, 1) !~ /[0-9]/) || (j <= ly && substr(y, j, 1) !~ /[0-9]/)) {
      xc = (i <= lx) ? dpkg_order(substr(x, i, 1)) : 0
      yc = (j <= ly) ? dpkg_order(substr(y, j, 1)) : 0
      if (xc != yc) return (xc < yc) ? -1 : 1
      i++; j++
    }
    while (substr(x, i, 1) == "0") i++
    while (substr(y, j, 1) == "0") j++
    while (substr(x, i, 1) ~ /[0-9]/ && substr(y, j, 1) ~ /[0-9]/) {
      if (first_diff == 0 && substr(x, i, 1) != substr(y, j, 1))
        first_diff = (substr(x, i, 1) < substr(y, j, 1)) ? -1 : 1
      i++; j++
    }
    if (substr(x, i, 1) ~ /[0-9]/) return 1
    if (substr(y, j, 1) ~ /[0-9]/) return -1
    if (first_diff != 0) return first_diff
  }
  return 0
}
function decide(sign,  op) {
  op = ENVIRON["FAKE_OP"]
  if (op == "lt") return sign < 0
  if (op == "le") return sign <= 0
  if (op == "eq") return sign == 0
  if (op == "ge") return sign >= 0
  if (op == "gt") return sign > 0
  if (op == "ne") return sign != 0
  return 0
}
BEGIN {
  ASCII = ""
  for (i = 32; i < 127; i++) ASCII = ASCII sprintf("%c", i)
  exit (decide(vercmp(ENVIRON["FAKE_LEFT"], ENVIRON["FAKE_RIGHT"])) ? 0 : 1)
}
'
SH
cat > "$PUBP/bin/gpg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ]
printf 'detached-signature\n' > "$out"
SH
cat > "$PUBP/bin/gpgconf" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2" = "--kill gpg-agent" ]
SH
chmod +x "$PUBP/bin/apt-ftparchive" "$PUBP/bin/dpkg-deb" "$PUBP/bin/dpkg" \
  "$PUBP/bin/gpg" "$PUBP/bin/gpgconf"

run_publish() { # <cwd> <suite> <version> <incoming> <prev-dir> <pointer>
  local cwd="$1" suite="$2" version="$3" incoming="$4" prev_dir="$5" pointer="$6"
  (
    cd "$cwd"
    PATH="$PUBP/bin:$PATH" APT_GPG_PASSPHRASE='fixture-passphrase' \
      bash "$SCRIPT" publish --suite "$suite" --version "$version" --incoming "$incoming" \
        --prev-dir "$prev_dir" --previous-pointer "$pointer" --signer "$SIGNER"
  )
}

# Publication only ever consumes a directory the verifier armed.
run_verify_preview "$PUBP/preview-incoming" \
  || die "coherent preview fixture should verify before publication"

# Stable first, exactly as the shared-tree caller does.
run_publish "$PUBP/run" stable "$VERSION" . "$PUB/previous" "$PUB/previous-pointer.json" \
  || die "stable publication failed while assembling the shared tree"
(
  cd "$PUBP/run"
  shasum -a 256 public/publication-record.json public/last-publish \
    public/dists/stable/InRelease public/dists/stable/main/binary-amd64/Packages \
    public/dists/stable/main/binary-arm64/Packages public/pool/main/v/velnor-runner/*.deb \
    > "$PUBP/stable-before.sha"
)

run_publish "$PUBP/run" preview "$PVERSION" "$PUBP/preview-incoming" \
  "$PUBP/preview-previous" "$PUBP/preview-pointer.json" \
  || die "preview publication failed inside the shared tree"

[ -f "$PUBP/run/public/publication-record-preview.json" ] \
  || die "preview publication record missing from the Pages tree"
[ -f "$PUBP/run/public/publication-record-preview.json.sig" ] \
  || die "preview publication signature missing from the Pages tree"
[ -f "$PUBP/run/public/dists/preview/InRelease" ] || die "preview InRelease missing"
[ -f "$PUBP/run/public/dists/preview/Release.gpg" ] || die "preview Release.gpg missing"
[ "$(cat "$PUBP/run/public/last-publish-preview")" = "$PVERSION" ] \
  || die "preview last-publish pointer mismatch"
[ "$(find "$PUBP/run/public/pool/preview" -type f -name '*.deb' | wc -l | tr -d ' ')" = "4" ] \
  || die "preview pool does not retain exactly the candidate and rollback pairs"
for arch in $REQUIRED_ARCHES; do
  [ -f "$PUBP/run/public/pool/preview/main/v/velnor-runner/velnor-runner_${PVERSION}_${arch}.deb" ] \
    || die "preview candidate not staged under its canonical dpkg name ($arch)"
  [ "$(awk '$1=="Version:"{print $2}' \
      "$PUBP/run/public/dists/preview/main/binary-$arch/Packages" | sort -u | wc -l | tr -d ' ')" = 2 ] \
    || die "$arch preview index does not retain two versions"
done
grep -q '^Codename: stable$' "$PUBP/run/public/conf/distributions" \
  || die "preview publication dropped the stable distribution stanza"
grep -q '^Codename: preview$' "$PUBP/run/public/conf/distributions" \
  || die "preview publication did not add its distribution stanza"
[ "$(grep -c '^Codename: preview$' "$PUBP/run/public/conf/distributions")" = "1" ] \
  || die "preview publication duplicated its distribution stanza"
jq -e --arg version "$PVERSION" '
  .schema == "velnor.publication-record/v1" and .suite == "preview" and
  .tag == "preview" and .crate_version == $version and .previous == "preview" and
  (.source_record_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  ([.packages[].arch] | sort) == ["amd64","arm64"]
' "$PUBP/run/public/publication-record-preview.json" >/dev/null \
  || die "preview publication record does not identify the preview suite"
(
  cd "$PUBP/run"
  shasum -a 256 -c "$PUBP/stable-before.sha" >/dev/null
) || die "preview publication mutated the stable suite artifacts"
ok "preview publication stages into the shared tree without touching the stable suite"

# A preview may never replace an equal or newer retained version.
NEWER_PREVIEW="$WORK/publish-preview-newer"
mkdir -p "$NEWER_PREVIEW/previous" "$NEWER_PREVIEW/incoming"
cp -R "$PBASE/." "$NEWER_PREVIEW/incoming/"
build_preview_fixture "$NEWER_PREVIEW/previous" "0.1.274~preview.43+abc1234" "$PCOMMIT"
run_verify_preview "$NEWER_PREVIEW/incoming" \
  || die "coherent preview fixture should verify before the monotonicity check"
if run_publish "$NEWER_PREVIEW" preview "$PVERSION" "$NEWER_PREVIEW/incoming" \
     "$NEWER_PREVIEW/previous" "$PUBP/preview-pointer.json" >/dev/null 2>&1; then
  die "preview publication accepted a candidate older than the retained rollback"
fi
# The candidate regressed, so nothing may be signed for it: no index, no record.
[ ! -f "$NEWER_PREVIEW/public/dists/preview/InRelease" ] \
  || die "preview publication signed indexes for a regressing candidate"
[ ! -f "$NEWER_PREVIEW/public/publication-record-preview.json" ] \
  || die "preview publication recorded a regressing candidate"
ok "preview rejected: candidate is older than the retained rollback version"

SAME_PREVIEW="$WORK/publish-preview-same"
mkdir -p "$SAME_PREVIEW/previous" "$SAME_PREVIEW/incoming"
cp -R "$PBASE/." "$SAME_PREVIEW/incoming/"
build_preview_fixture "$SAME_PREVIEW/previous" "$PVERSION" "$PCOMMIT"
run_verify_preview "$SAME_PREVIEW/incoming" || die "preview fixture should verify"
if run_publish "$SAME_PREVIEW" preview "$PVERSION" "$SAME_PREVIEW/incoming" \
     "$SAME_PREVIEW/previous" "$PUBP/preview-pointer.json" >/dev/null 2>&1; then
  die "preview publication accepted an equal retained version"
fi
ok "preview rejected: candidate equals the retained rollback version"

SAME_POINTER="$WORK/publish-preview-pointer"
mkdir -p "$SAME_POINTER/previous" "$SAME_POINTER/incoming"
cp -R "$PBASE/." "$SAME_POINTER/incoming/"
build_preview_fixture "$SAME_POINTER/previous" "$PREVIEW_ROLLBACK" "$PCOMMIT"
run_verify_preview "$SAME_POINTER/incoming" || die "preview fixture should verify"
jq -n --arg tag "v$PBASE" '{tag:$tag}' > "$SAME_POINTER/pointer.json"
if run_publish "$SAME_POINTER" preview "$PVERSION" "$SAME_POINTER/incoming" \
     "$SAME_POINTER/previous" "$SAME_POINTER/pointer.json" >/dev/null 2>&1; then
  die "preview publication accepted a stable-style previous pointer"
fi
ok "preview rejected: previous pointer is not the JSON string \"preview\""

UNVERIFIED="$WORK/publish-preview-unverified"
mkdir -p "$UNVERIFIED"
build_preview_fixture "$UNVERIFIED" "$PVERSION" "$PCOMMIT"
if run_publish "$PUBP/run" preview "$PVERSION" "$UNVERIFIED" \
     "$PUBP/preview-previous" "$PUBP/preview-pointer.json" >/dev/null 2>&1; then
  die "preview publication accepted an unverified candidate directory"
fi
[ ! -e "$PUBP/run/public/publication-record-preview.json.tmp" ] \
  || die "preview publication wrote despite the missing sentinel"
ok "preview rejected: publication without the armed reprepro sentinel"

# --- preview bootstrap: the one initialization path ---------------------------
# The FIRST publication of a preview suite has no live dists/preview to recover
# a rollback pair from, so --bootstrap stages the candidate pair alone: exactly
# two pool debs, exactly one (candidate) version per index, JSON null previous.
# The caller chooses bootstrap only when no live preview suite exists.
BOOT="$WORK/publish-preview-bootstrap"
mkdir -p "$BOOT/run" "$BOOT/incoming"
cp -R "$PBASE/." "$BOOT/incoming/"
printf 'null\n' > "$BOOT/pointer.json"
run_verify_preview "$BOOT/incoming" \
  || die "coherent preview fixture should verify before bootstrap"

run_bootstrap() { # <cwd> <incoming> <pointer> [extra args...]
  local cwd="$1" incoming="$2" pointer="$3"; shift 3
  (
    cd "$cwd"
    PATH="$PUBP/bin:$PATH" APT_GPG_PASSPHRASE='fixture-passphrase' \
      bash "$SCRIPT" publish --suite preview --bootstrap --version "$PVERSION" \
        --incoming "$incoming" --previous-pointer "$pointer" --signer "$SIGNER" "$@"
  )
}

run_bootstrap "$BOOT/run" "$BOOT/incoming" "$BOOT/pointer.json" \
  || die "preview bootstrap publication failed"

[ -f "$BOOT/run/public/publication-record-preview.json" ] \
  || die "bootstrap publication record missing from the Pages tree"
[ -f "$BOOT/run/public/publication-record-preview.json.sig" ] \
  || die "bootstrap publication signature missing from the Pages tree"
[ -f "$BOOT/run/public/dists/preview/InRelease" ] || die "bootstrap InRelease missing"
[ "$(cat "$BOOT/run/public/last-publish-preview")" = "$PVERSION" ] \
  || die "bootstrap last-publish pointer mismatch"
[ "$(find "$BOOT/run/public/pool/preview" -type f -name '*.deb' | wc -l | tr -d ' ')" = "2" ] \
  || die "bootstrap pool must contain exactly the candidate pair"
for arch in $REQUIRED_ARCHES; do
  [ -f "$BOOT/run/public/pool/preview/main/v/velnor-runner/velnor-runner_${PVERSION}_${arch}.deb" ] \
    || die "bootstrap candidate not staged under its canonical dpkg name ($arch)"
  versions="$(awk '$1=="Version:"{print $2}' \
    "$BOOT/run/public/dists/preview/main/binary-$arch/Packages" | sort -u)"
  [ "$(printf '%s\n' "$versions" | awk 'NF{n++} END{print n+0}')" = 1 ] \
    || die "$arch bootstrap index must retain exactly the candidate version"
  printf '%s\n' "$versions" | grep -Fx "$PVERSION" >/dev/null \
    || die "$arch bootstrap index lost the candidate version"
done
grep -q '^Codename: preview$' "$BOOT/run/public/conf/distributions" \
  || die "bootstrap did not add its distribution stanza"
jq -e --arg version "$PVERSION" '
  .schema == "velnor.publication-record/v1" and .suite == "preview" and
  .tag == "preview" and .crate_version == $version and .previous == null and
  (.source_record_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  ([.packages[].arch] | sort) == ["amd64","arm64"]
' "$BOOT/run/public/publication-record-preview.json" >/dev/null \
  || die "bootstrap publication record must carry a null previous pointer"
[ ! -e "$BOOT/run/public/publication-record.json" ] \
  || die "bootstrap invented stable artifacts"
ok "preview bootstrap initializes the suite from the candidate pair alone (null previous)"

run_bootstrap "$BOOT/run" "$BOOT/incoming" "$BOOT/pointer.json" \
  || die "bootstrap re-run should stay idempotent on its own tree"
[ "$(find "$BOOT/run/public/pool/preview" -type f -name '*.deb' | wc -l | tr -d ' ')" = "2" ] \
  || die "bootstrap re-run grew the pool beyond the candidate pair"
ok "preview bootstrap re-run stays idempotent on its own tree"

# Bootstrap must never run where a preview suite already retains a rollback pair.
if run_bootstrap "$PUBP/run" "$PUBP/preview-incoming" "$BOOT/pointer.json" >/dev/null 2>&1; then
  die "bootstrap accepted a tree that already holds a retained preview rollback pair"
fi
[ "$(find "$PUBP/run/public/pool/preview" -type f -name '*.deb' | wc -l | tr -d ' ')" = "4" ] \
  || die "bootstrap mutated an existing preview pool"
ok "preview rejected: bootstrap over a tree that already retains a rollback pair"

if run_bootstrap "$BOOT/run" "$BOOT/incoming" "$BOOT/pointer.json" \
     --prev-dir "$PUBP/preview-previous" >/dev/null 2>&1; then
  die "bootstrap accepted --prev-dir alongside it"
fi
ok "preview rejected: --bootstrap is mutually exclusive with --prev-dir"

if (cd "$PUB_NO_PASS" && PATH="$PUBP/bin:$PATH" APT_GPG_PASSPHRASE='fixture-passphrase' \
      bash "$SCRIPT" publish --suite stable --bootstrap --version "$VERSION" \
        --incoming . --prev-dir "$PUB/previous" \
        --previous-pointer "$PUB/previous-pointer.json" --signer "$SIGNER" \
      >/dev/null 2>&1); then
  die "bootstrap accepted the stable suite"
fi
ok "preview rejected: --bootstrap does not apply to --suite stable"

printf '%s\n' '"preview"' > "$BOOT/string-pointer.json"
if run_bootstrap "$BOOT/run" "$BOOT/incoming" "$BOOT/string-pointer.json" >/dev/null 2>&1; then
  die "bootstrap accepted a rollback-style previous pointer"
fi
[ "$(jq -r '.previous' "$BOOT/run/public/publication-record-preview.json")" = "null" ] \
  || die "bootstrap rewrote the publication record despite a malformed previous pointer"
ok "preview rejected: bootstrap previous pointer is not JSON null"

# The source image is public: live OCI verification runs anonymous `docker
# buildx imagetools inspect`, so the generated feed publisher holds no
# registry authority at all. Least privilege is top-level `contents: read`
# only; if the image ever goes private again, the GENERATOR must grant the
# verify job `packages: read` (generated YAML is never hand-edited) and this
# case must assert it again.
grep -q '^permissions:$' "$WORKFLOW" \
  || die "publisher lacks a top-level permissions block"
grep -A1 '^permissions:$' "$WORKFLOW" | grep -q '^  contents: read$' \
  || die "publisher top-level authority is not contents-read-only"
! grep -q 'packages:' "$WORKFLOW" \
  || die "publisher grants unneeded registry authority for a public image"
ok "publisher holds least authority for a public source image"
# No registry authentication: the image is public, so anonymous inspection is
# the whole mechanism. A login step would be dead authority (and a canary:
# if one appears, the image-visibility assumption changed and the
# least-authority case above must be revisited too).
! grep -q 'docker/login-action' "$WORKFLOW" \
  || die "publisher authenticates a public registry"
! grep -q 'Authenticate source image registry' "$WORKFLOW" \
  || die "publisher carries a stale registry-auth step"
ok "public GHCR verification runs without registry authentication"

# Same-version retries must preserve the already-signed rollback identity.
# A normal new-version publish reads the root record; an idempotent retry reads
# its signed `previous` pointer and proves the candidate is byte-identical.
POINTER_FILTER="$HERE/publication-previous.jq"
CANDIDATE_SHA="$(sha256_str candidate-record)"
PRIOR_SHA="$(sha256_str prior-record)"
jq -n --arg tag v0.1.139 --arg sha "$PRIOR_SHA" \
  '{schema:"velnor.publication-record/v1", tag:$tag, source_record_sha256:$sha}' \
  | jq -e --arg candidate v0.1.140 --arg prior v0.1.139 \
      --arg candidate_sha "$CANDIDATE_SHA" -f "$POINTER_FILTER" \
  | jq -e --arg sha "$PRIOR_SHA" '.tag == "v0.1.139" and .source_record_sha256 == $sha' >/dev/null
jq -n --arg candidate_sha "$CANDIDATE_SHA" --arg prior_sha "$PRIOR_SHA" \
  '{schema:"velnor.publication-record/v1", tag:"v0.1.140", source_record_sha256:$candidate_sha,
    previous:{tag:"v0.1.139", source_record_sha256:$prior_sha}}' \
  | jq -e --arg candidate v0.1.140 --arg prior v0.1.139 \
      --arg candidate_sha "$CANDIDATE_SHA" -f "$POINTER_FILTER" \
  | jq -e --arg sha "$PRIOR_SHA" '.tag == "v0.1.139" and .source_record_sha256 == $sha' >/dev/null
if jq -n --arg prior_sha "$PRIOR_SHA" \
  '{schema:"velnor.publication-record/v1", tag:"v0.1.140", source_record_sha256:"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    previous:{tag:"v0.1.139", source_record_sha256:$prior_sha}}' \
  | jq -e --arg candidate v0.1.140 --arg prior v0.1.139 \
      --arg candidate_sha "$CANDIDATE_SHA" -f "$POINTER_FILTER" >/dev/null 2>&1; then
  die "same-version retry accepted different candidate bytes"
fi
if jq -n --arg candidate_sha "$CANDIDATE_SHA" --arg prior_sha "$PRIOR_SHA" \
  '{schema:"velnor.publication-record/v1", tag:"v0.1.140", source_record_sha256:$candidate_sha,
    previous:{tag:"v0.1.138", source_record_sha256:$prior_sha}}' \
  | jq -e --arg candidate v0.1.140 --arg prior v0.1.139 \
      --arg candidate_sha "$CANDIDATE_SHA" -f "$POINTER_FILTER" >/dev/null 2>&1; then
  die "same-version retry accepted a different rollback tag"
fi
ok "same-version publication retry preserves signed rollback identity"

echo "----"
echo "all $pass verify-release checks passed"
