#!/usr/bin/env bash
# Discover one canonical Velnor application release from the paginated GitHub
# Releases API. The release list is only a candidate index: a candidate is
# eligible only after its typed product manifest, external manifest digest,
# provenance, subordinate records, and complete APT projection pass.
set -euo pipefail

SOURCE_REPOSITORY="tailrocks/velnor"
PACKAGE="velnor-runner"
PRODUCT_ID="velnor"
PRODUCT_MANIFEST_SCHEMA="velnor.product-manifest/v1"
PRODUCT_MANIFEST_ASSET="product-manifest.json"
RELEASE_RECORD_SCHEMA="velnor.release-record/v1"
PACKAGE_RELEASE_SCHEMA="velnor.package-release.v1"
APT_ARTIFACT_KIND="apt-package"
CHANNEL="stable"
REQUESTED_VERSION=""

usage() {
  cat >&2 <<'USAGE'
usage: release-discovery.sh [options]

Discover one immutable application release and print its provenance JSON.

Options:
  --channel stable|preview       release channel (default: stable)
  --version VERSION              exact stable tag or preview version
  --source-repository OWNER/REPO source repository (default: tailrocks/velnor)
  --package PACKAGE              APT package name (default: velnor-runner)
  --manifest-asset NAME          canonical product manifest asset
                                  (default: product-manifest.json)
USAGE
}

fail() {
  printf 'release-discovery: ERROR: %s\n' "$*" >&2
  exit 1
}

is_repository_slug() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

is_package_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

is_asset_name() {
  [[ "$1" =~ ^[A-Za-z0-9._+~-]+$ ]]
}

valid_source_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

valid_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

read_sidecar_digest() {
  local sidecar="$1" expected_name="${2:-}" token
  token="$(awk -v expected="$expected_name" '
    NF {
      lines++
      if (lines > 1 || NF > 2 || (expected != "" && NF == 2 && $2 != expected && $2 != "./" expected)) exit 1
      token = $1
    }
    END {
      if (lines != 1) exit 1
      print token
    }
  ' "$sidecar")" || return 1
  valid_sha256 "$token" || return 1
  printf '%s\n' "$token"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CHANNEL="$2"
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REQUESTED_VERSION="$2"
      shift 2
      ;;
    --source-repository)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SOURCE_REPOSITORY="$2"
      shift 2
      ;;
    --package)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      PACKAGE="$2"
      shift 2
      ;;
    --manifest-asset)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      PRODUCT_MANIFEST_ASSET="$2"
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

case "$CHANNEL" in
  stable|preview) ;;
  *) fail "unknown channel: $CHANNEL" ;;
esac
is_repository_slug "$SOURCE_REPOSITORY" || fail "invalid source repository: $SOURCE_REPOSITORY"
is_package_name "$PACKAGE" || fail "invalid package name: $PACKAGE"
is_asset_name "$PRODUCT_MANIFEST_ASSET" || fail "invalid product manifest asset: $PRODUCT_MANIFEST_ASSET"

if [ "$CHANNEL" = stable ] && [ -n "$REQUESTED_VERSION" ]; then
  [[ "$REQUESTED_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "stable version must be a vX.Y.Z tag: $REQUESTED_VERSION"
fi
if [ "$CHANNEL" = preview ] && [ -n "$REQUESTED_VERSION" ]; then
  [[ "$REQUESTED_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+\+[0-9a-f]{7}|preview-[0-9a-f]{40})$ ]] \
    || fail "preview version must be X.Y.Z-preview.N+<7-hex> or preview-<40-hex>: $REQUESTED_VERSION"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fetch_releases() {
  # --paginate is intentional. The newest release can be a runtime product or
  # an invalid application release, so selection happens after validation.
  gh api --paginate \
    --header 'Accept: application/vnd.github+json' \
    "repos/$SOURCE_REPOSITORY/releases?per_page=100"
}

fetch_asset() {
  local asset_id="$1" destination="$2" label="$3"
  # A listed asset is part of candidate provenance. A failed fetch is an API
  # failure, not an ineligible release: fail closed.
  gh api \
    --header 'Accept: application/octet-stream' \
    "repos/$SOURCE_REPOSITORY/releases/assets/$asset_id" \
    > "$destination" \
    || fail "GitHub API failed while fetching $label asset $asset_id"
}

release_asset_id() {
  local release="$1" name="$2"
  jq -er --arg name "$name" \
    '[.assets[] | select(.name == $name and .state == "uploaded" and ((.size | type) == "number" and .size > 0))] |
     if length == 1 then .[0].id else error("asset must be unique and uploaded") end' \
    <<<"$release"
}

release_asset_is_complete() {
  local release="$1" name="$2"
  jq -e --arg name "$name" '
    ((.assets | type) == "array") and
    (any(.assets[]; .name == $name and .state == "uploaded" and
      ((.size | type) == "number" and .size > 0)))
  ' <<<"$release" >/dev/null
}

release_assets_are_well_formed() {
  local release="$1"
  jq -e '
    ((.assets | type) == "array" and (.assets | length) > 0) and
    ([.assets[].name] | (length == (unique | length))) and
    all(.assets[];
      ((.name | type) == "string" and (.name | test("^[A-Za-z0-9._+~-]+$"))) and
      (.state == "uploaded") and
      ((.size | type) == "number" and .size > 0) and
      ((.id | type) == "number" and .id > 0)
    )
  ' <<<"$release" >/dev/null
}

manifest_assets_are_well_formed() {
  local manifest="$1"
  jq -e '
    ((.artifacts | type) == "array" and (.artifacts | length) > 0) and
    ([.artifacts[].name] | (length == (unique | length))) and
    all(.artifacts[];
      ((.name | type) == "string" and (.name | test("^[A-Za-z0-9._+~-]+$"))) and
      (.target | type == "string" and
        (. == "x86_64-unknown-linux-gnu" or
         . == "aarch64-unknown-linux-gnu" or
         . == "aarch64-apple-darwin" or
         . == "x86_64-apple-darwin")) and
      ((.kind | type) == "string" and (.kind | test("^[A-Za-z0-9._+-]+$"))) and
      ((.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$"))) and
      (.size | type == "number" and . > 0 and floor == .)
    ) and
    ((.components | type) == "array" and (.components | length) > 0) and
    ([.components[].name] | (length == (unique | length)))
  ' "$manifest" >/dev/null 2>/dev/null
}

validate_external_manifest_digest() {
  local release="$1" manifest_file="$2" manifest_id sidecar_id sidecar_file expected actual
  manifest_id="$(release_asset_id "$release" "$PRODUCT_MANIFEST_ASSET")" || return 1
  sidecar_id="$(release_asset_id "$release" "$PRODUCT_MANIFEST_ASSET.sha256")" || return 1
  expected="$(sha256_file "$manifest_file")"
  valid_sha256 "$expected" || return 1
  sidecar_file="$tmp_dir/product-manifest-sidecar-$manifest_id.txt"
  fetch_asset "$sidecar_id" "$sidecar_file" "$PRODUCT_MANIFEST_ASSET.sha256"
  actual="$(read_sidecar_digest "$sidecar_file" "$PRODUCT_MANIFEST_ASSET")" || return 1
  [ "$actual" = "$expected" ] || return 1
  printf '%s\n' "$expected"
}

verify_asset_digest() {
  local release="$1" payload_name="$2"
  local payload_id sidecar_id payload_file sidecar_file expected actual
  payload_id="$(release_asset_id "$release" "$payload_name")" || return 1
  sidecar_id="$(release_asset_id "$release" "$payload_name.sha256")" || return 1
  payload_file="$tmp_dir/subordinate-$payload_id.json"
  sidecar_file="$tmp_dir/subordinate-sidecar-$payload_id.txt"
  fetch_asset "$payload_id" "$payload_file" "$payload_name"
  fetch_asset "$sidecar_id" "$sidecar_file" "$payload_name.sha256"
  expected="$(sha256_file "$payload_file")"
  actual="$(read_sidecar_digest "$sidecar_file" "$payload_name")" || return 1
  [ "$actual" = "$expected" ] || return 1
  printf '%s\n' "$payload_file"
}

validate_asset_sidecar() {
  local release="$1" payload_name="$2" expected="$3"
  local sidecar_id sidecar_file actual
  valid_sha256 "$expected" || return 1
  sidecar_id="$(release_asset_id "$release" "$payload_name.sha256")" || return 1
  sidecar_file="$tmp_dir/asset-sidecar-$sidecar_id.txt"
  fetch_asset "$sidecar_id" "$sidecar_file" "$payload_name.sha256"
  actual="$(read_sidecar_digest "$sidecar_file" "$payload_name")" || return 1
  [ "$actual" = "$expected" ]
}

parent_manifest_digest() {
  local file="$1"
  jq -er '
    .parent_manifest_sha256 |
    select(type == "string" and test("^[0-9a-f]{64}$"))
  ' "$file"
}

validate_subordinate_records() {
  local release="$1" tag="$2" source_ref="$3" source_commit="$4" version="$5" manifest_sha="$6"
  local release_manifest_id record_file release_manifest_file package_file

  release_manifest_id="$(release_asset_id "$release" release-manifest.json)" || return 1
  release_manifest_file="$tmp_dir/release-manifest-$release_manifest_id.json"
  record_file="$(verify_asset_digest "$release" release-record.json)" || return 1
  package_file="$(verify_asset_digest "$release" manifest.json)" || return 1
  fetch_asset "$release_manifest_id" "$release_manifest_file" release-manifest.json

  [ "$(parent_manifest_digest "$record_file")" = "$manifest_sha" ] || return 1
  [ "$(parent_manifest_digest "$release_manifest_file")" = "$manifest_sha" ] || return 1
  [ "$(parent_manifest_digest "$package_file")" = "$manifest_sha" ] || return 1

  jq -e \
    --arg schema "$RELEASE_RECORD_SCHEMA" --arg repository "$SOURCE_REPOSITORY" \
    --arg tag "$tag" --arg source_commit "$source_commit" --arg version "$version" \
    --arg manifest_sha "$manifest_sha" \
    '(.schema == $schema) and
     (.parent_manifest_sha256 == $manifest_sha) and
     (.build.repository == $repository) and (.build.tag == $tag) and
     (.build.commit == $source_commit) and
     (.build.crate_version == $version) and
     (.build.debian_version == $version) and
     (.build.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$"))' \
    "$record_file" >/dev/null || return 1
  jq -e \
    --arg schema "$PACKAGE_RELEASE_SCHEMA" --arg repository "$SOURCE_REPOSITORY" \
    --arg source_ref "$source_ref" \
    --arg source_commit "$source_commit" --arg version "$version" \
    --arg manifest_sha "$manifest_sha" \
    '(.schema == $schema) and
     (.parent_manifest_sha256 == $manifest_sha) and
     (.source_repository == $repository) and (.source_ref == $source_ref) and
     (.source_commit == $source_commit) and (.version == $version)' \
    "$release_manifest_file" >/dev/null || return 1
  jq -e \
    --arg manifest_sha "$manifest_sha" --arg source_commit "$source_commit" \
    '(.parent_manifest_sha256 == $manifest_sha) and (.source_sha == $source_commit)' \
    "$package_file" >/dev/null || return 1
}

validate_product_manifest() {
  local release="$1" manifest_file="$2" tag="$3" version="$4" source_ref="$5" source_commit="$6"

  # Sole application authority. Exact keys exclude any self-digest field;
  # canonical bytes are hashed externally by the sidecar and records.
  jq -e \
    --arg schema "$PRODUCT_MANIFEST_SCHEMA" --arg product "$PRODUCT_ID" \
    --arg repository "$SOURCE_REPOSITORY" --arg expected_ref "$source_ref" \
    --arg expected_commit "$source_commit" --arg expected_tag "$tag" \
    --arg expected_version "$version" --arg channel "$CHANNEL" \
    '((keys | sort) == ["artifacts","channel","components","product_id","release_id","release_tag","schema","source_commit","source_ref","source_repository","version"]) and
     .schema == $schema and .product_id == $product and .channel == $channel and
     .source_repository == $repository and .source_ref == $expected_ref and
     .source_commit == $expected_commit and .release_tag == $expected_tag and
     (.release_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:/-]*$")) and
     .version == $expected_version and
     (.source_commit | test("^[0-9a-f]{40}$")) and
     (.version | if $channel == "stable" then test("^[0-9]+\\.[0-9]+\\.[0-9]+$")
       else test("^[0-9]+\\.[0-9]+\\.[0-9]+-preview\\.[0-9]+\\+[0-9a-f]{7}$") end)' \
    "$manifest_file" >/dev/null 2>/dev/null || return 1

  manifest_assets_are_well_formed "$manifest_file" || return 1
  if [ "$CHANNEL" = preview ]; then
    [ "${version##*+}" = "${source_commit:0:7}" ] || return 1
  else
    [[ "$tag" == v$version ]] || return 1
  fi

  # Runtime-only releases do not have this complete application component set.
  jq -e '
    ([.components[].name] | sort) == ["velnor-runner","velnor-workflow","velnorctl"] and
    all(.components[];
      (keys | sort) == ["binary","crate","name","targets","version"] and
      .name == .crate and
      (.binary | type == "string" and test("^[A-Za-z0-9._+-]+$")) and
      (.version | type == "string") and
      (.targets | type == "array" and
        (. | length > 0 and length == (unique | length) and
          all(.[];
            . == "x86_64-unknown-linux-gnu" or
            . == "aarch64-unknown-linux-gnu" or
            . == "aarch64-apple-darwin" or
            . == "x86_64-apple-darwin") and
          index("x86_64-unknown-linux-gnu") != null and
          index("aarch64-unknown-linux-gnu") != null))
    )
  ' "$manifest_file" >/dev/null 2>/dev/null || return 1

  local deb_version="$version"
  if [ "$CHANNEL" = preview ]; then
    deb_version="${version/-preview./.preview.}"
  fi
  local deb_prefix="$PACKAGE-$deb_version"
  if [ "$CHANNEL" = preview ]; then
    deb_prefix="$PACKAGE-preview-$deb_version"
  fi
  for arch in amd64 arm64; do
    local target name
    if [ "$arch" = amd64 ]; then target=x86_64-unknown-linux-gnu; else target=aarch64-unknown-linux-gnu; fi
    name="$deb_prefix-$arch.deb"
    artifact_sha="$(jq -er --arg name "$name" --arg target "$target" --arg kind "$APT_ARTIFACT_KIND" \
      '[.artifacts[] | select(.name == $name and .kind == $kind and .target == $target)] |
       if length == 1 then .[0].sha256 else error("APT artifact must be unique") end' \
      "$manifest_file" 2>/dev/null)" || return 1
    jq -e --arg name "$name" --arg target "$target" --arg kind "$APT_ARTIFACT_KIND" \
      'any(.artifacts[]; .name == $name and .kind == $kind and .target == $target)' \
    "$manifest_file" >/dev/null 2>/dev/null || return 1
    release_asset_is_complete "$release" "$name" || return 1
    release_asset_is_complete "$release" "$name.sha256" || return 1
    validate_asset_sidecar "$release" "$name" "$artifact_sha" || return 1
  done

  local expected_deb_assets
  expected_deb_assets="$(printf '%s\n' \
    "$deb_prefix-amd64.deb" "$deb_prefix-amd64.deb.sha256" \
    "$deb_prefix-arm64.deb" "$deb_prefix-arm64.deb.sha256" | \
    jq -R -s 'split("\n") | map(select(length > 0)) | sort')"
  jq -e --arg package "$PACKAGE" --argjson expected "$expected_deb_assets" \
    '[.assets[].name | select(startswith($package) and test("[.]deb([.]sha256)?$"))] | sort == $expected' \
    <<<"$release" >/dev/null || return 1

  while IFS=$'\t' read -r artifact_name artifact_size; do
    local release_size
    release_size="$(jq -er --arg name "$artifact_name" '[.assets[] | select(.name == $name)] | .[0].size' <<<"$release")" || return 1
    [ "$release_size" = "$artifact_size" ] || return 1
  done < <(jq -r '.artifacts[] | [.name,.size] | @tsv' "$manifest_file")

  local target_commit
  target_commit="$(jq -er '.target_commitish | strings' <<<"$release")" || return 1
  [ "$target_commit" = "$source_commit" ] || return 1
}

validate_candidate() {
  local release="$1"
  local tag version source_ref source_commit manifest_id manifest_file manifest_sha preview_tag_commit
  local prerelease draft

  release_assets_are_well_formed "$release" || return 1
  jq -e '
    (.id | type == "number" and . > 0 and floor == .) and
    (.html_url | type == "string" and length > 0) and
    (.published_at | type == "string" and length > 0) and
    (.draft | type == "boolean") and (.prerelease | type == "boolean")
  ' <<<"$release" >/dev/null || return 1
  draft="$(jq -er '.draft | tostring' <<<"$release")" || return 1
  prerelease="$(jq -er '.prerelease | tostring' <<<"$release")" || return 1
  [ "$draft" = false ] || return 1

  tag="$(jq -er '.tag_name | strings' <<<"$release")" || return 1
  if [ "$CHANNEL" = stable ]; then
    [ "$prerelease" = false ] || return 1
    [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    version="${tag#v}"
    [ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "$tag" ] || return 1
    source_ref="refs/tags/$tag"
  else
    # A rolling `preview` pointer is an index, never a package source.
    [[ "$tag" =~ ^preview-([0-9a-f]{40})$ ]] || return 1
    preview_tag_commit="${BASH_REMATCH[1]}"
    [ "$prerelease" = true ] || return 1
    source_ref="refs/heads/main"
  fi

  source_commit="$(jq -er '.target_commitish | strings' <<<"$release")" || return 1
  valid_source_commit "$source_commit" || return 1
  if [ "$CHANNEL" = preview ]; then
    [ "$source_commit" = "$preview_tag_commit" ] || return 1
  fi

  manifest_id="$(release_asset_id "$release" "$PRODUCT_MANIFEST_ASSET")" || return 1
  manifest_file="$tmp_dir/product-manifest-$manifest_id.json"
  fetch_asset "$manifest_id" "$manifest_file" "$PRODUCT_MANIFEST_ASSET"
  manifest_sha="$(validate_external_manifest_digest "$release" "$manifest_file")" || return 1

  version="$(jq -er '.version | strings' "$manifest_file" 2>/dev/null)" || return 1
  if [ "$CHANNEL" = preview ]; then
    [ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "$version" ] || [ "$REQUESTED_VERSION" = "$tag" ] || return 1
  fi
  validate_product_manifest "$release" "$manifest_file" "$tag" "$version" "$source_ref" "$source_commit" || return 1

  local required_asset
  for required_asset in \
    "$PRODUCT_MANIFEST_ASSET" \
    "$PRODUCT_MANIFEST_ASSET.sha256" \
    release-manifest.json \
    SHA256SUMS \
    release-record.json \
    release-record.json.sha256 \
    manifest.json \
    manifest.json.sha256; do
    release_asset_is_complete "$release" "$required_asset" || return 1
  done
  validate_subordinate_records "$release" "$tag" "$source_ref" "$source_commit" "$version" "$manifest_sha" || return 1

  jq -S -c \
    --arg channel "$CHANNEL" \
    --arg product_id "$PRODUCT_ID" \
    --arg repository "$SOURCE_REPOSITORY" \
    --arg package "$PACKAGE" \
    --arg manifest_asset "$PRODUCT_MANIFEST_ASSET" \
    --arg tag "$tag" \
    --arg version "$version" \
    --arg source_ref "$source_ref" \
    --arg source_commit "$source_commit" \
    --arg manifest_schema "$PRODUCT_MANIFEST_SCHEMA" \
    --arg manifest_sha256 "$manifest_sha" \
    --slurpfile manifest "$manifest_file" \
    '(
      [.assets[] | {id,name,size,state,browser_download_url}] | sort_by(.name)
    ) as $release_assets |
    {
      channel: $channel,
      product_id: $product_id,
      source_repository: $repository,
      package: $package,
      tag: $tag,
      release_tag: $tag,
      version: $version,
      source_ref: $source_ref,
      source_commit: $source_commit,
      manifest_asset: $manifest_asset,
      manifest_schema: $manifest_schema,
      manifest_sha256: $manifest_sha256,
      release_id: $manifest[0].release_id,
      provider_release_id: .id,
      release_url: .html_url,
      published_at: .published_at,
      target_commitish: .target_commitish,
      release_assets: $release_assets,
      manifest: $manifest[0]
    }' <<<"$release"
}

release_pages="$(fetch_releases)" \
  || fail "GitHub API failed while listing releases"
releases="$(jq -s -e '
  if all(.[]; type == "array") then (add // []) else error("release API returned a non-array page") end
' <<<"$release_pages")" \
  || fail "GitHub API returned malformed release pages"

candidates="$tmp_dir/candidates.jsonl"
: > "$candidates"
release_count="$(jq 'length' <<<"$releases")"
for ((index = 0; index < release_count; index += 1)); do
  release="$(jq -c ".[$index]" <<<"$releases")"
  if candidate="$(validate_candidate "$release")"; then
    printf '%s\n' "$candidate" >> "$candidates"
  fi
done

[ -s "$candidates" ] || fail "no eligible $CHANNEL application release found in paginated release set"

if [ "$CHANNEL" = stable ]; then
  jq -s -e 'sort_by(.version | split(".") | map(tonumber)) | .[-1]' "$candidates"
else
  # Immutable preview releases are retained. Select the highest product
  # prerelease sequence after validation; never use a mutable pointer/latest.
  jq -s -e '
    sort_by(.version | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)-preview\\.(?<sequence>[0-9]+)\\+") |
      [.major,.minor,.patch,.sequence] | map(tonumber)) | .[-1]
  ' "$candidates"
fi
