#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
script="$root/scripts/preview-feed-inputs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

endpoint=""
for arg in "$@"; do
  case "$arg" in
    repos/tailrocks/velnor/*) endpoint="$arg" ;;
  esac
done

case "$endpoint" in
  repos/tailrocks/velnor/releases/tags/preview)
    cat "$FAKE_RELEASE"
    ;;
  repos/tailrocks/velnor/releases/assets/456)
    cat "$FAKE_MANIFEST"
    ;;
  *)
    printf 'unexpected fake gh endpoint: %s\n' "$endpoint" >&2
    exit 1
    ;;
esac
FAKE_GH
chmod +x "$fake_bin/gh"

commit="0123456789abcdef0123456789abcdef01234567"
version="1.2.3~preview.7+0123456"
asset_version="${version//~/.}"
manifest="$tmp/release-manifest.json"
release="$tmp/release.json"

write_manifest() {
  jq -S -n \
    --arg commit "$commit" \
    --arg version "$version" \
    --arg amd64 "velnor-runner-preview-$asset_version-amd64.deb" \
    --arg arm64 "velnor-runner-preview-$asset_version-arm64.deb" \
    '{
      schema: "velnor.package-release.v1",
      source_repository: "tailrocks/velnor",
      source_ref: "refs/heads/main",
      source_commit: $commit,
      version: $version,
      assets: [
        {name: $amd64, sha256: ("a" * 64)},
        {name: $arm64, sha256: ("b" * 64)}
      ]
    }' > "$manifest"
}

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

write_release() {
  local size sha
  size="$(wc -c < "$manifest")"
  sha="$(digest "$manifest")"
  jq -S -n \
    --arg commit "$commit" \
    --arg digest "sha256:$sha" \
    --argjson size "$size" \
    '{
      id: 123,
      tag_name: "preview",
      draft: false,
      prerelease: true,
      target_commitish: $commit,
      assets: [{
        id: 456,
        name: "release-manifest.json",
        state: "uploaded",
        size: $size,
        digest: $digest
      }]
    }' > "$release"
}

run_preview() {
  PATH="$fake_bin:$PATH" \
    FAKE_RELEASE="$release" \
    FAKE_MANIFEST="$manifest" \
    "$script" "$@"
}

die() {
  printf 'test-preview-feed-inputs: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" > "$tmp/stdout" 2> "$tmp/stderr"; then
    die "expected rejection: $label"
  fi
  [ ! -s "$tmp/stdout" ] || die "rejection emitted output: $label"
}

write_manifest
write_release

output="$(run_preview)"
jq -e \
  --arg commit "$commit" \
  --arg version "$version" \
  '.channel == "preview" and
   .release_tag == "preview" and
   .source_ref == "refs/heads/main" and
   .source_commit == $commit and
   .version == $version and
   .manifest_asset_id == 456 and
   (.manifest_sha256 | test("^[0-9a-f]{64}$"))' <<<"$output" >/dev/null \
  || die "accepted preview did not emit the exact manifest binding"

run_preview --version "$version" --commit "$commit" >/dev/null
expect_failure "requested version mismatch" run_preview --version 1.2.3~preview.8+0123456
expect_failure "requested commit mismatch" run_preview --commit 1111111111111111111111111111111111111111

jq '.target_commitish = "1111111111111111111111111111111111111111"' \
  "$release" > "$tmp/release.next"
mv "$tmp/release.next" "$release"
expect_failure "release metadata source mismatch" run_preview
write_release

jq '.source_ref = "refs/tags/v1.2.3"' "$manifest" > "$tmp/manifest.next"
mv "$tmp/manifest.next" "$manifest"
write_release
expect_failure "manifest source ref mismatch" run_preview
write_manifest
write_release

jq '.assets[0].digest = "sha256:" + ("0" * 64)' "$release" > "$tmp/release.next"
mv "$tmp/release.next" "$release"
expect_failure "manifest byte digest mismatch" run_preview

printf 'test-preview-feed-inputs: ok\n'
