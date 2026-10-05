#!/usr/bin/env bash
# Resolve the currently published Velnor rolling preview into immutable feed
# inputs. The release pointer is only an index; source identity comes from the
# release-manifest asset that belongs to that exact release.
set -euo pipefail

SOURCE_REPOSITORY="tailrocks/velnor"
REQUESTED_VERSION=""
REQUESTED_COMMIT=""
MANIFEST_ASSET="release-manifest.json"

usage() {
  cat >&2 <<'USAGE'
usage: preview-feed-inputs.sh [options]

Resolve the published rolling preview release and print its feed inputs as JSON.

Options:
  --source-repository OWNER/REPO source repository (default: tailrocks/velnor)
  --version VERSION              require this manifest version
  --commit SHA                   require this manifest source commit
USAGE
}

fail() {
  printf 'preview-feed-inputs: ERROR: %s\n' "$*" >&2
  exit 1
}

is_repository_slug() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

is_source_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-repository)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SOURCE_REPOSITORY="$2"
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REQUESTED_VERSION="$2"
      shift 2
      ;;
    --commit)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REQUESTED_COMMIT="$2"
      shift 2
      ;;
    --help|-h)
      usage >&1
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

is_repository_slug "$SOURCE_REPOSITORY" || fail "invalid source repository: $SOURCE_REPOSITORY"
[ -z "$REQUESTED_COMMIT" ] || is_source_commit "$REQUESTED_COMMIT" \
  || fail "--commit must be a lowercase 40-hex source SHA"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
trap 'rm -rf -- "$tmp_dir"; exit 1' TERM

release_file="$tmp_dir/release.json"
if ! gh api \
  --header 'Accept: application/vnd.github+json' \
  "repos/$SOURCE_REPOSITORY/releases/tags/preview" > "$release_file"; then
  fail "GitHub API failed while fetching the rolling preview release"
fi

jq -e '
  (.id | type == "number" and . > 0 and floor == .) and
  .tag_name == "preview" and
  .draft == false and
  .prerelease == true and
  (.target_commitish | type == "string" and length > 0) and
  (.assets | type == "array")
' "$release_file" >/dev/null \
  || fail "rolling preview release metadata is not a published prerelease"

release_id="$(jq -er '.id' "$release_file")" \
  || fail "rolling preview release has no provider ID"
target_commitish="$(jq -er '.target_commitish' "$release_file")" \
  || fail "rolling preview release has no target commit metadata"

manifest_count="$(jq -er --arg name "$MANIFEST_ASSET" \
  '[.assets[] | select(.name == $name and .state == "uploaded" and
    (.id | type == "number" and . > 0 and floor == .) and
    (.size | type == "number" and . > 0 and floor == .))] | length' \
  "$release_file")" \
  || fail "rolling preview release assets are malformed"
[ "$manifest_count" = 1 ] \
  || fail "rolling preview release must contain exactly one uploaded $MANIFEST_ASSET"

manifest_id="$(jq -er --arg name "$MANIFEST_ASSET" \
  '[.assets[] | select(.name == $name and .state == "uploaded")][0].id' \
  "$release_file")" \
  || fail "rolling preview manifest asset has no provider ID"
manifest_size="$(jq -er --arg name "$MANIFEST_ASSET" \
  '[.assets[] | select(.name == $name and .state == "uploaded")][0].size' \
  "$release_file")" \
  || fail "rolling preview manifest asset has no size"
manifest_digest="$(jq -er --arg name "$MANIFEST_ASSET" \
  '[.assets[] | select(.name == $name and .state == "uploaded")][0].digest // ""' \
  "$release_file")" \
  || fail "rolling preview manifest asset has malformed digest metadata"

manifest_file="$tmp_dir/$MANIFEST_ASSET"
if ! gh api \
  --header 'Accept: application/octet-stream' \
  "repos/$SOURCE_REPOSITORY/releases/assets/$manifest_id" > "$manifest_file"; then
  fail "GitHub API failed while fetching $MANIFEST_ASSET asset $manifest_id"
fi

actual_size="$(wc -c < "$manifest_file" | tr -d '[:space:]')"
[ "$actual_size" -gt 0 ] && [ "$actual_size" = "$manifest_size" ] \
  || fail "$MANIFEST_ASSET size does not match the release asset record"

manifest_sha256="$(sha256_file "$manifest_file")"
if [ -n "$manifest_digest" ]; then
  [[ "$manifest_digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "$MANIFEST_ASSET release digest is not sha256"
  [ "${manifest_digest#sha256:}" = "$manifest_sha256" ] \
    || fail "$MANIFEST_ASSET digest does not match downloaded bytes"
fi

jq -e --arg repository "$SOURCE_REPOSITORY" '
  .schema == "velnor.package-release.v1" and
  .source_repository == $repository and
  .source_ref == "refs/heads/main" and
  (.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.version | type == "string" and
    test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)~preview[.](0|[1-9][0-9]*)\\+[0-9a-f]{7}$")) and
  (.source_commit[0:7] == (.version | split("+")[1])) and
  (.assets | type == "array" and length == 2)
' "$manifest_file" >/dev/null \
  || fail "$MANIFEST_ASSET is not a coherent preview package manifest"

manifest_version="$(jq -er '.version' "$manifest_file")" \
  || fail "$MANIFEST_ASSET has no version"
source_commit="$(jq -er '.source_commit' "$manifest_file")" \
  || fail "$MANIFEST_ASSET has no source commit"
asset_version="${manifest_version//~/.}"

jq -e --arg asset_version "$asset_version" '
  (["amd64", "arm64"] |
    map("velnor-runner-preview-" + $asset_version + "-" + . + ".deb") |
    sort) == ([.assets[].name] | sort) and
  all(.assets[]; .sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' "$manifest_file" >/dev/null \
  || fail "$MANIFEST_ASSET assets are not the complete amd64/arm64 package pair"

[ "$target_commitish" = "$source_commit" ] \
  || fail "release target commit does not match manifest source commit"
[ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "$manifest_version" ] \
  || fail "requested preview version does not match manifest version"
[ -z "$REQUESTED_COMMIT" ] || [ "$REQUESTED_COMMIT" = "$source_commit" ] \
  || fail "requested preview commit does not match manifest source commit"

jq -S -n \
  --arg channel preview \
  --arg repository "$SOURCE_REPOSITORY" \
  --arg source_ref refs/heads/main \
  --arg source_commit "$source_commit" \
  --arg version "$manifest_version" \
  --arg release_tag preview \
  --arg manifest_asset "$MANIFEST_ASSET" \
  --arg manifest_sha256 "$manifest_sha256" \
  --argjson release_id "$release_id" \
  --argjson manifest_asset_id "$manifest_id" \
  '{
    channel: $channel,
    manifest_asset: $manifest_asset,
    manifest_asset_id: $manifest_asset_id,
    manifest_sha256: $manifest_sha256,
    release_id: $release_id,
    release_tag: $release_tag,
    source_commit: $source_commit,
    source_ref: $source_ref,
    source_repository: $repository,
    version: $version
  }'
