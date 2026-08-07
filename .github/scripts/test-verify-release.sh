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
WORKFLOW="$HERE/../workflows/publish.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VERSION="v0.1.121"
VER="0.1.121"
COMMIT="1111111111111111111111111111111111111111"
SIGNER="261EDAC957DEB801"
REQUIRED_ARCHES="amd64 arm64"

pass=0
ok() { echo "ok - $1"; pass=$((pass + 1)); }
die() { echo "FAIL - $1" >&2; exit 1; }

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
  local out="$1" arch="$2" binary_bytes="${3:-runner-$2}"
  local stage; stage="$(mktemp -d)"
  mkdir -p "$stage/root/usr/share/velnor" "$stage/root/usr/bin"
  cp "$WORK/build-identity.json" "$stage/root/usr/share/velnor/build-identity.json"
  cp "$BASE/manifest.json" "$stage/root/usr/share/velnor/manifest.json"
  printf '%s' "$binary_bytes" > "$stage/root/usr/bin/velnor-runner"
  ( cd "$stage/root" && tar -czf "$stage/data.tar.gz" . )
  mkdir -p "$stage/ctl"
  printf 'Package: velnor-runner\nVersion: %s\nArchitecture: %s\n' "$VER" "$arch" > "$stage/ctl/control"
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

# 1. record checksum mismatch (tamper record, keep old sidecar)
D="$(fresh_copy neg_record)"; printf ' ' >> "$D/release-record.json"
expect_reject "tampered record fails checksum" "$D"

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
     --signer "$SIGNER" --expect-signer "DEADBEEFDEADBEEF" >/dev/null 2>&1; then
  die "expected rejection on signer mismatch"
fi
[ ! -f "$D/.reprepro-ok" ] || die "sentinel armed on signer mismatch"
ok "rejected: APT signer fingerprint mismatch"

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
( cd "$BAD_STAGE/root" && tar -czf "$BAD_STAGE/data.tar.gz" . )
mkdir -p "$BAD_STAGE/ctl"; printf 'Package: velnor-runner\n' > "$BAD_STAGE/ctl/control"
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

# 10. extracted binary bytes disagree with the independently recorded digest.
D="$(fresh_copy neg_binary)"
make_fake_deb "$D/velnor-runner-${VER}-amd64.deb" amd64 tampered-runner
NEWHASH="$(sha256_file "$D/velnor-runner-${VER}-amd64.deb")"
printf '%s\n' "$NEWHASH" > "$D/velnor-runner-${VER}-amd64.deb.sha256"
jq --arg h "$NEWHASH" '(.architectures[] | select(.arch=="amd64") | .deb_sha256) |= $h' \
  "$D/release-record.json" > "$D/release-record.json.tmp"
mv "$D/release-record.json.tmp" "$D/release-record.json"
sha256_file "$D/release-record.json" > "$D/release-record.json.sha256"
expect_reject "extracted runner binary disagrees with record" "$D"

# 11. publication writes the signed record and rollback pointer into the Pages
# artifact, not the checkout. Fake only the external signer/reprepro boundary;
# candidate bytes and release record remain the independently-built fixture.
PUB="$WORK/publish"
mkdir -p "$PUB/bin" "$PUB/run" "$PUB/previous"
cp -R "$POS/." "$PUB/run/"
cp "$POS"/*.deb "$PUB/previous/"
cat > "$PUB/bin/reprepro" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
deb="${*: -1}"
printf '%s\n' "$deb" >> reprepro.calls
case "$deb" in *-amd64.deb) arch=amd64 ;; *-arm64.deb) arch=arm64 ;; *) exit 1 ;; esac
dir="public/dists/stable/main/binary-$arch"
mkdir -p "$dir" public/dists/stable
printf 'Package: velnor-runner\nFilename: pool/%s\nSHA256: fixture\n\n' "$(basename "$deb")" >> "$dir/Packages"
printf 'signed-index\n' > public/dists/stable/InRelease
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
chmod +x "$PUB/bin/reprepro" "$PUB/bin/gpg"
(
  cd "$PUB/run"
  PATH="$PUB/bin:$PATH" APT_GPG_PASSPHRASE='fixture-passphrase' \
    bash "$SCRIPT" publish --version "$VERSION" --incoming . \
      --prev-dir "$PUB/previous" --signer "$SIGNER" >/dev/null 2>&1
)
[ -f "$PUB/run/public/publication-record.json" ] || die "publication record missing from Pages tree"
[ -f "$PUB/run/public/publication-record.json.sig" ] || die "publication signature missing from Pages tree"
[ "$(cat "$PUB/run/public/.last-publish")" = "$VERSION" ] || die "published rollback pointer mismatch"
[ "$(jq -r .schema "$PUB/run/public/publication-record.json")" = "velnor.publication-record/v1" ] \
  || die "publication record schema mismatch"
[ "$(wc -l < "$PUB/run/reprepro.calls" | tr -d ' ')" = "2" ] \
  || die "identical prior package pair was included twice"
ok "publication stays in Pages artifact and deduplicates identical rollback pair"

# The source image is private. Its verifier must receive only package-read
# authority and authenticate before asking Buildx to inspect the pinned digest.
grep -q '^  packages: read$' "$WORKFLOW" \
  || die "publisher lacks package-read authority"
! grep -q '^  packages: write$' "$WORKFLOW" \
  || die "publisher grants package-write authority"
grep -q 'docker/login-action@af1e73f918a031802d376d3c8bbc3fe56130a9b0' "$WORKFLOW" \
  || die "publisher lacks pinned GHCR authentication"
grep -q '^          registry: ghcr.io$' "$WORKFLOW" \
  || die "publisher authenticates the wrong registry"
grep -Fq "          password: \${{ secrets.GITHUB_TOKEN }}" "$WORKFLOW" \
  || die "publisher does not use the ephemeral workflow token"
login_line="$(grep -n 'name: Authenticate source image registry' "$WORKFLOW" | cut -d: -f1)"
verify_line="$(grep -n 'name: Verify source, package, manifest, image, and signer coherence' "$WORKFLOW" | cut -d: -f1)"
[ "$login_line" -lt "$verify_line" ] \
  || die "publisher authenticates after OCI verification"
ok "private GHCR verification is authenticated with read-only authority"

echo "----"
echo "all $pass verify-release checks passed"
