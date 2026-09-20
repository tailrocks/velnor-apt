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
# These names are producer/control records, not downloadable product payloads.
# A product artifact may not shadow any of them; otherwise a manifest can turn
# a control record into an executable/package row while the release still has
# a second object with the same semantic role.
CONTROL_ASSET_NAMES_JSON='["discovery.json","product-manifest.json","product-manifest.json.sha256","release-manifest.json","SHA256SUMS","release-record.json","release-record.json.sha256","manifest.json","manifest.json.sha256","release-attestation.json"]'
# Producer-owned release IDs are immutable GitHub provider identities. APT and
# Homebrew share this positive canonical decimal grammar; the manifest value
# must also equal the release object's provider ID.
RELEASE_ID_PATTERN='^[1-9][0-9]*$'
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
  # Command substitution subshells swallow `exit`. TERM the selector process
  # so a provider failure cannot be treated as candidate ineligibility.
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    kill -s TERM $$
  fi
  exit 1
}

is_repository_slug() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

is_package_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

is_canonical_decimal() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

is_bare_version() {
  local value="$1" major minor patch extra
  IFS='.' read -r major minor patch extra <<< "$value"
  [ -z "$extra" ] || return 1
  is_canonical_decimal "$major" \
    && is_canonical_decimal "$minor" \
    && is_canonical_decimal "$patch"
}

is_stable_tag() {
  local tag="$1"
  [[ "$tag" == v* ]] || return 1
  is_bare_version "${tag#v}"
}

is_preview_version() {
  local value="$1" base rest sequence sha
  [[ "$value" == *-preview.*+* ]] || return 1
  base="${value%%-preview.*}"
  rest="${value#*-preview.}"
  sequence="${rest%%+*}"
  sha="${rest#*+}"
  [ -n "$base" ] && [ -n "$sequence" ] && [ -n "$sha" ] \
    && is_bare_version "$base" \
    && is_canonical_decimal "$sequence" \
    && [[ "$sha" =~ ^[0-9a-f]{7}$ ]]
}

is_preview_tag() {
  [[ "$1" =~ ^preview-[0-9a-f]{40}$ ]]
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
  is_stable_tag "$REQUESTED_VERSION" \
    || fail "stable version must be a vX.Y.Z tag: $REQUESTED_VERSION"
fi
if [ "$CHANNEL" = preview ] && [ -n "$REQUESTED_VERSION" ]; then
  (is_preview_version "$REQUESTED_VERSION" || is_preview_tag "$REQUESTED_VERSION") \
    || fail "preview version must be X.Y.Z-preview.N+<7-hex> or preview-<40-hex>: $REQUESTED_VERSION"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
trap 'rm -rf -- "$tmp_dir"; exit 1' TERM

fetch_releases() {
  # --paginate is intentional. The newest release can be a runtime product or
  # an invalid application release, so selection happens after validation.
  gh api --paginate \
    --header 'Accept: application/vnd.github+json' \
    "repos/$SOURCE_REPOSITORY/releases?per_page=100"
}

fetch_repository() {
  # The repository ID is provider identity, not application metadata. Read it
  # directly from the provider API before inspecting any candidate release;
  # neither the product manifest nor its release attestation can supply it.
  gh api \
    --header 'Accept: application/vnd.github+json' \
    "repos/$SOURCE_REPOSITORY"
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

resolve_immutable_release_ref() {
  # target_commitish is release metadata, not a source-of-truth ref. Resolve
  # the immutable release tag through GitHub's ref API and compare its commit
  # with the release and canonical manifest before accepting the candidate.
  local tag="$1" ref_json object_type object_sha tag_json
  local tag_key="${tag//\//_}"
  local ref_file="$tmp_dir/git-ref-tags-$tag_key.json"
  local tag_file="$tmp_dir/git-tag-object-$tag_key.json"
  # Transport failure is not candidate ineligibility.
  gh api \
    --header 'Accept: application/vnd.github+json' \
    "repos/$SOURCE_REPOSITORY/git/ref/tags/$tag" \
    > "$ref_file" \
    || fail "GitHub API failed while resolving tag ref $tag"
  ref_json="$(cat "$ref_file")"
  object_type="$(jq -er '.object.type | strings' <<<"$ref_json")" || return 1
  object_sha="$(jq -er '.object.sha | strings' <<<"$ref_json")" || return 1
  case "$object_type" in
    commit)
      valid_source_commit "$object_sha" || return 1
      printf '%s\n' "$object_sha"
      ;;
    tag)
      gh api \
        --header 'Accept: application/vnd.github+json' \
        "repos/$SOURCE_REPOSITORY/git/tags/$object_sha" \
        > "$tag_file" \
        || fail "GitHub API failed while resolving annotated tag $tag"
      tag_json="$(cat "$tag_file")"
      [ "$(jq -er '.object.type | strings' <<<"$tag_json")" = commit ] || return 1
      object_sha="$(jq -er '.object.sha | strings' <<<"$tag_json")" || return 1
      valid_source_commit "$object_sha" || return 1
      printf '%s\n' "$object_sha"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_preview_branch_ancestry() {
  # A preview's immutable tag proves the build commit, but not the producer's
  # declared main-branch source. Compare the historical commit against the
  # current main tip and require the preview commit to be an ancestor. This
  # deliberately accepts a main tip that advanced after issuance; equality
  # with today's main is neither required nor meaningful provenance.
  local commit="$1" compare_json
  local compare_file="$tmp_dir/compare-main-$commit.json"
  gh api \
    --header 'Accept: application/vnd.github+json' \
    "repos/$SOURCE_REPOSITORY/compare/main...$commit" \
    > "$compare_file" \
    || fail "GitHub API failed while comparing main...$commit"
  compare_json="$(cat "$compare_file")"
  jq -e --arg commit "$commit" '
    ((.status == "behind") or (.status == "identical")) and
    (.merge_base_commit.sha == $commit) and
    (.base_commit.sha | type == "string" and test("^[0-9a-f]{40}$"))
  ' <<<"$compare_json" >/dev/null || return 1
  jq -c --arg commit "$commit" '
    {
      ref: "refs/heads/main",
      relation: (if .status == "identical" then "tip" else "ancestor" end),
      status: .status,
      merge_base_commit: .merge_base_commit.sha,
      base_commit: .base_commit.sha,
      head_commit: $commit,
      method: "github-compare-ancestry"
    }
  ' <<<"$compare_json"
}

provider_repository="$(fetch_repository)" \
  || fail "GitHub API failed while fetching repository identity"
provider_repository_id="$(jq -er \
  '.id | numbers | select(. > 0 and floor == .)' <<<"$provider_repository")" \
  || fail "GitHub API repository identity has no positive numeric ID"
jq -e --arg repository "$SOURCE_REPOSITORY" \
  '.full_name | strings == $repository' <<<"$provider_repository" >/dev/null \
  || fail "GitHub API repository identity does not match the selected source"

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
    ([.assets[].id] | (length == (unique | length))) and
    all(.assets[];
      ((.name | type) == "string" and (.name | test("^[A-Za-z0-9._+~-]+$"))) and
      (.state == "uploaded") and
      ((.size | type) == "number" and .size > 0) and
      ((.id | type) == "number" and .id > 0) and
      (.browser_download_url | type == "string" and test("^https://[^[:space:]]+$"))
    )
  ' <<<"$release" >/dev/null
}

release_asset_urls_are_canonical() {
  local release="$1" tag="$2" base
  base="https://github.com/$SOURCE_REPOSITORY/releases/download/$tag/"
  jq -e --arg base "$base" '
    all(.assets[]; .browser_download_url == ($base + .name))
  ' <<<"$release" >/dev/null
}

manifest_assets_are_well_formed() {
  local manifest="$1"
  jq -e --argjson control_names "$CONTROL_ASSET_NAMES_JSON" '
    ((.artifacts | type) == "array" and (.artifacts | length) == 18) and
    ([.artifacts[].name] | (length == (unique | length))) and
    all(.artifacts[];
      . as $artifact |
      ((keys | sort) == ["kind","name","sha256","size","target"]) and
      ((.name | type) == "string" and (.name | test("^[A-Za-z0-9._+~-]+$")) and
       ($control_names | index($artifact.name) | not)) and
      (.target | type == "string" and
        (. == "x86_64-unknown-linux-gnu" or
         . == "aarch64-unknown-linux-gnu" or
         . == "aarch64-apple-darwin" or
         . == "x86_64-apple-darwin")) and
      ((.kind | type) == "string" and (.kind | test("^[A-Za-z0-9._+-]+$"))) and
      ((.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$"))) and
      (.size | type == "number" and . > 0 and floor == .)
    ) and
    ((.components | type) == "array" and (.components | length) == 3) and
    ([.components[].name] | (sort == ["velnor-runner","velnor-workflow","velnorctl"])) and
    all(.components[];
      (keys | sort) == ["binary","crate","feature","identity","name","targets","version"] and
      (.name == .crate and .name == .binary) and
      (.feature == null or .feature == "release-build") and
      (.identity == "version" or .identity == "revision") and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) and
      (.targets | type == "array" and
        (sort == ["aarch64-apple-darwin","aarch64-unknown-linux-gnu","x86_64-apple-darwin","x86_64-unknown-linux-gnu"]))
    ) and
    all(.artifacts[]; .kind == "binary" or .kind == "archive" or .kind == "homebrew-archive" or .kind == "apt-package") and
    (([.artifacts[] | select(.kind == "binary")] | length) == 12) and
    (([.artifacts[] | select(.kind == "apt-package")] | length) == 2) and
    (([.artifacts[] | select(.kind == "archive" or .kind == "homebrew-archive")] | length) == 4) and
    (. as $manifest |
      [$manifest.components[].binary] as $binaries |
      (["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin","x86_64-apple-darwin"] as $targets |
        ([$manifest.artifacts[] | select(.kind == "binary")] as $binary_rows |
          all($binary_rows[]; . as $row |
            any($binaries[]; . as $binary | $row.name == ($binary + "-" + $row.target))) and
          all($binaries[]; . as $binary |
            all($targets[]; . as $target |
              ([$binary_rows[] | select(.name == ($binary + "-" + $target) and .target == $target)] | length) == 1)) and
          all($targets[]; . as $target |
            ([$manifest.artifacts[] | select(.target == $target and .kind ==
              (if ($target | endswith("-apple-darwin")) then "homebrew-archive" else "archive" end))] | length) == 1) and
          ([$manifest.artifacts[] | select(.kind == "apt-package" and .target == "x86_64-unknown-linux-gnu")] | length) == 1 and
          ([$manifest.artifacts[] | select(.kind == "apt-package" and .target == "aarch64-unknown-linux-gnu")] | length) == 1
        )
      )
    )
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

validate_manifest_artifact_bytes() {
  local release="$1" manifest_file="$2"
  local artifact_name artifact_sha artifact_size
  while IFS=$'\t' read -r artifact_name artifact_sha artifact_size; do
    [ -n "$artifact_name" ] || return 1
    local asset_id payload_file actual_sha actual_size release_size
    asset_id="$(release_asset_id "$release" "$artifact_name")" || return 1
    payload_file="$tmp_dir/product-artifact-$asset_id"
    fetch_asset "$asset_id" "$payload_file" "$artifact_name"
    actual_sha="$(sha256_file "$payload_file")"
    actual_size="$(wc -c < "$payload_file" | tr -d '[:space:]')"
    release_size="$(jq -er --arg name "$artifact_name" \
      '[.assets[] | select(.name == $name)] | .[0].size' <<<"$release")" || return 1
    [ "$actual_sha" = "$artifact_sha" ] || return 1
    [ "$actual_size" = "$artifact_size" ] || return 1
    [ "$release_size" = "$artifact_size" ] || return 1
  done < <(jq -r '.artifacts[] | [.name,.sha256,(.size | tostring)] | @tsv' "$manifest_file")
}

validate_release_attestation() {
  # This is typed admission and byte/inventory equality only. It is deliberately
  # not cryptographic verification; the central runtime must invoke its real
  # provider-attestation verifier before publication or installation.
  local release="$1" tag="$2" source_ref="$3" source_commit="$4" manifest_sha="$5" manifest_file="$6"
  local attestation_id attestation_file provider_release_id actual_assets expected_assets
  provider_release_id="$(jq -er '.id | numbers | tostring' <<<"$release")" || return 1
  attestation_id="$(release_asset_id "$release" release-attestation.json)" || return 1
  attestation_file="$tmp_dir/release-attestation-$attestation_id.json"
  fetch_asset "$attestation_id" "$attestation_file" release-attestation.json
  jq -e \
    --arg schema "velnor.github-release-attestation/v1" \
    --arg repository "$SOURCE_REPOSITORY" --arg source_ref "$source_ref" \
    --arg source_commit "$source_commit" --arg tag "$tag" \
    --arg release_id "$provider_release_id" --arg release_url "https://github.com/$SOURCE_REPOSITORY/releases/tag/$tag" \
    --arg manifest_sha "$manifest_sha" \
    '((keys | sort) == ["assets","manifest_sha256","provider","release_id","release_tag","release_url","resolved_source_commit","resolved_source_ref","schema","source_commit","source_ref","source_repository","target_commitish"]) and
     .schema == $schema and .provider == "github" and
     .source_repository == $repository and .source_ref == $source_ref and
     .source_commit == $source_commit and .resolved_source_ref == $source_ref and
     .resolved_source_commit == $source_commit and .release_tag == $tag and
     .release_id == $release_id and .target_commitish == $source_commit and
     .release_url == $release_url and .manifest_sha256 == $manifest_sha and
     (.assets | type == "array")' \
    "$attestation_file" >/dev/null 2>/dev/null || return 1
  actual_assets="$(jq -S '.assets' "$attestation_file")" || return 1
  expected_assets="$(jq -S '.artifacts' "$manifest_file")" || return 1
  [ "$actual_assets" = "$expected_assets" ] || return 1
}

validate_sha256sums() {
  local release="$1" manifest_file="$2" sums_id sums_file sums_count
  sums_id="$(release_asset_id "$release" SHA256SUMS)" || return 1
  sums_file="$tmp_dir/sha256sums-$sums_id.txt"
  fetch_asset "$sums_id" "$sums_file" SHA256SUMS
  sums_count="$(awk 'NF { if (NF != 2) bad = 1; count++ }
    END { if (bad || count != 2) exit 1; print count }' "$sums_file")" || return 1
  [ "$sums_count" = 2 ] || return 1
  local apt_count
  apt_count="$(jq -er --arg kind "$APT_ARTIFACT_KIND" \
    '[.artifacts[] | select(.kind == $kind and
      (.target == "x86_64-unknown-linux-gnu" or .target == "aarch64-unknown-linux-gnu"))] | length' \
    "$manifest_file")" || return 1
  [ "$apt_count" = 2 ] || return 1

  local artifact_name expected_sha sums_sha sidecar_id sidecar_file sidecar_sha
  while IFS=$'\t' read -r artifact_name expected_sha; do
    [ -n "$artifact_name" ] || return 1
    sums_sha="$(awk -v name="$artifact_name" \
      '$2 == name { count++; value = $1 } END { if (count != 1) exit 1; print value }' \
      "$sums_file")" || return 1
    valid_sha256 "$sums_sha" || return 1
    [ "$sums_sha" = "$expected_sha" ] || return 1
    sidecar_id="$(release_asset_id "$release" "$artifact_name.sha256")" || return 1
    sidecar_file="$tmp_dir/sha256sums-sidecar-$sidecar_id.txt"
    fetch_asset "$sidecar_id" "$sidecar_file" "$artifact_name.sha256"
    sidecar_sha="$(read_sidecar_digest "$sidecar_file" "$artifact_name")" || return 1
    [ "$sidecar_sha" = "$sums_sha" ] || return 1
  done < <(jq -r --arg kind "$APT_ARTIFACT_KIND" \
    '[.artifacts[] | select(.kind == $kind and
      (.target == "x86_64-unknown-linux-gnu" or .target == "aarch64-unknown-linux-gnu"))]
     | if length == 2 then sort_by(.name)[] | [.name,.sha256] | @tsv else error("APT inventory must contain exactly two artifacts") end' \
    "$manifest_file")
}

parent_manifest_digest() {
  local file="$1"
  jq -er '
    .parent_manifest_sha256 |
    select(type == "string" and test("^[0-9a-f]{64}$"))
  ' "$file"
}

validate_subordinate_records() {
  local release="$1" tag="$2" source_ref="$3" source_commit="$4" version="$5" manifest_sha="$6" product_manifest_file="$7"
  local release_manifest_id record_file release_manifest_file package_file package_sha expected_assets actual_assets
  local record_manifest_version expected_crate_version

  release_manifest_id="$(release_asset_id "$release" release-manifest.json)" || return 1
  release_manifest_file="$tmp_dir/release-manifest-$release_manifest_id.json"
  verify_asset_digest "$release" release-record.json > "$tmp_dir/release-record.path" || return 1
  record_file="$(cat "$tmp_dir/release-record.path")"
  verify_asset_digest "$release" manifest.json > "$tmp_dir/package-manifest.path" || return 1
  package_file="$(cat "$tmp_dir/package-manifest.path")"
  fetch_asset "$release_manifest_id" "$release_manifest_file" release-manifest.json

  [ "$(parent_manifest_digest "$record_file")" = "$manifest_sha" ] || return 1
  [ "$(parent_manifest_digest "$release_manifest_file")" = "$manifest_sha" ] || return 1
  [ "$(parent_manifest_digest "$package_file")" = "$manifest_sha" ] || return 1
  package_sha="$(sha256_file "$package_file")"
  expected_assets="$(jq -S --arg kind "$APT_ARTIFACT_KIND" '
    [.artifacts[] | select(.kind == $kind and
      (.target == "x86_64-unknown-linux-gnu" or .target == "aarch64-unknown-linux-gnu")) |
      {name,sha256}] | sort_by(.name)
  ' "$product_manifest_file")" || return 1
  actual_assets="$(jq -S '.assets' "$release_manifest_file")" || return 1
  [ "$actual_assets" = "$expected_assets" ] || return 1

  record_manifest_version="$(jq -er \
    '.build.manifest_version | select(type == "number" and floor == . and . > 0)' \
    "$record_file")" || return 1
  expected_crate_version="$(jq -er --arg package "$PACKAGE" '
    [.components[] | select(.name == $package) | .version] |
    if length == 1 and (.[0] | type == "string" and length > 0) then .[0]
    else error("package component version must be unique") end
  ' "$product_manifest_file")" || return 1

  jq -e \
    --arg schema "$RELEASE_RECORD_SCHEMA" --arg repository "$SOURCE_REPOSITORY" \
    --arg tag "$tag" --arg source_commit "$source_commit" --arg version "$version" \
    --arg manifest_sha "$manifest_sha" --arg package_sha "$package_sha" --arg suite "$CHANNEL" \
    '(.schema == $schema) and
     (.parent_manifest_sha256 == $manifest_sha) and
     (.build.repository == $repository) and (.build.tag == $tag) and
     (.build.commit == $source_commit) and
     (.build.crate_version == $version) and
     (.build.debian_version == $version) and
     (.build.manifest_version | type == "number" and floor == . and . > 0) and
     (.build.manifest_sha256 == $package_sha) and
     (.architectures | type == "array" and length == 2) and
     ([.architectures[].arch] | sort) == ["amd64","arm64"] and
     all(.architectures[];
       (keys | sort) == ["arch","binary_sha256","deb_sha256","oci_platform_digest","target"] and
       ((.arch == "amd64" and .target == "x86_64-unknown-linux-gnu") or
        (.arch == "arm64" and .target == "aarch64-unknown-linux-gnu")) and
       (.binary_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.deb_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.oci_platform_digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
     ) and
     (.oci_index_digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
     (.oci_image_ref | type == "string" and length > 0) and
     (.oci_labels | type == "object" and
       .version == $version and .revision == $source_commit and
       (.manifest_sha256 == $package_sha)) and
     (.apt | type == "object" and .suite == $suite and .component == "main")' \
    "$record_file" >/dev/null || return 1
  local record_arch expected_target expected_deb actual_deb
  for record_arch in amd64 arm64; do
    if [ "$record_arch" = amd64 ]; then
      expected_target=x86_64-unknown-linux-gnu
    else
      expected_target=aarch64-unknown-linux-gnu
    fi
    expected_deb="$(jq -er --arg kind "$APT_ARTIFACT_KIND" --arg target "$expected_target" \
      '[.artifacts[] | select(.kind == $kind and .target == $target)] | .[0].sha256' \
      "$product_manifest_file")" || return 1
    actual_deb="$(jq -er --arg arch "$record_arch" \
      '.architectures[] | select(.arch == $arch) | .deb_sha256' "$record_file")" || return 1
    [ "$actual_deb" = "$expected_deb" ] || return 1
  done
  jq -e \
    --arg schema "$PACKAGE_RELEASE_SCHEMA" --arg repository "$SOURCE_REPOSITORY" \
    --arg source_ref "$source_ref" \
    --arg source_commit "$source_commit" --arg version "$version" \
    --arg manifest_sha "$manifest_sha" \
    '((keys | sort) == ["assets","parent_manifest_sha256","schema","source_commit","source_ref","source_repository","version"]) and
     (.schema == $schema) and
     (.parent_manifest_sha256 == $manifest_sha) and
     (.source_repository == $repository) and (.source_ref == $source_ref) and
    (.source_commit == $source_commit) and (.version == $version) and
    (.assets | type == "array" and length == 2) and
    all(.assets[]; (keys | sort) == ["name","sha256"] and
      (.name | type == "string") and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))' \
    "$release_manifest_file" >/dev/null || return 1
  jq -e \
    --arg manifest_sha "$manifest_sha" --arg source_commit "$source_commit" \
    --arg expected_crate_version "$expected_crate_version" \
    --argjson record_manifest_version "$record_manifest_version" \
    '((keys | sort) == ["crate_version","parent_manifest_sha256","source_sha","version"]) and
     (.parent_manifest_sha256 == $manifest_sha) and
     (.source_sha == $source_commit) and
     (.crate_version == $expected_crate_version) and
     (.version | type == "number" and floor == . and . > 0 and . == $record_manifest_version)' \
    "$package_file" >/dev/null || return 1
}

validate_product_manifest() {
  local release="$1" manifest_file="$2" tag="$3" version="$4" source_ref="$5" source_commit="$6"
  local provider_release_id
  provider_release_id="$(jq -er '.id | numbers | select(. > 0 and floor == .)' <<<"$release")" || return 1

  # Sole application authority. Exact keys exclude any self-digest field;
  # canonical bytes are hashed externally by the sidecar and records.
  jq -e \
    --arg schema "$PRODUCT_MANIFEST_SCHEMA" --arg product "$PRODUCT_ID" \
    --arg repository "$SOURCE_REPOSITORY" --arg expected_ref "$source_ref" \
    --arg expected_commit "$source_commit" --arg expected_tag "$tag" \
    --arg expected_version "$version" --arg channel "$CHANNEL" \
    --arg release_id_pattern "$RELEASE_ID_PATTERN" \
    --argjson expected_release_id "$provider_release_id" \
    '((keys | sort) == ["artifacts","channel","components","product_id","release_id","release_tag","schema","source_commit","source_ref","source_repository","version"]) and
     .schema == $schema and .product_id == $product and .channel == $channel and
     .source_repository == $repository and .source_ref == $expected_ref and
     .source_commit == $expected_commit and .release_tag == $expected_tag and
     (.release_id | type == "string" and test($release_id_pattern)) and
     (.release_id == ($expected_release_id | tostring)) and
     .version == $expected_version and
     (.source_commit | test("^[0-9a-f]{40}$")) and
     (.version | if $channel == "stable" then test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
       else test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)-preview\\.(0|[1-9][0-9]*)\\+[0-9a-f]{7}$") end)' \
    "$manifest_file" >/dev/null 2>/dev/null || return 1

  manifest_assets_are_well_formed "$manifest_file" || return 1
  if [ "$CHANNEL" = preview ]; then
    [ "${version##*+}" = "${source_commit:0:7}" ] || return 1
  else
    [[ "$tag" == v$version ]] || return 1
  fi

  # Runtime-only releases do not have this complete application component set.
  # Keep this projection identical to the native producer's four-target
  # component contract; APT filters only the two Linux package rows below.
  jq -e '
    ([.components[].name] | sort) == ["velnor-runner","velnor-workflow","velnorctl"] and
    all(.components[];
      (keys | sort) == ["binary","crate","feature","identity","name","targets","version"] and
      (.name == .crate and .name == .binary) and
      (.feature == null or .feature == "release-build") and
      (.identity == "version" or .identity == "revision") and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) and
      (.targets | type == "array" and
        (sort == ["aarch64-apple-darwin","aarch64-unknown-linux-gnu","x86_64-apple-darwin","x86_64-unknown-linux-gnu"]))
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

  # Every canonical artifact row is independently bound to the bytes served by
  # this immutable release. APT sidecars and SHA256SUMS add the package-format
  # proofs below; non-APT rows are still verified here rather than silently
  # being presented as part of an unverified product release.
  validate_manifest_artifact_bytes "$release" "$manifest_file" || return 1
  validate_sha256sums "$release" "$manifest_file" || return 1

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
  local resolved_source_commit expected_release_url preview_branch_provenance='null'
  local prerelease draft

  release_assets_are_well_formed "$release" || return 1
  tag="$(jq -er '.tag_name | strings' <<<"$release")" || return 1
  expected_release_url="https://github.com/$SOURCE_REPOSITORY/releases/tag/$tag"
  jq -e '
    (.id | type == "number" and . > 0 and floor == .) and
    (.html_url | type == "string" and length > 0) and
    (.published_at | type == "string" and length > 0) and
    (.draft | type == "boolean") and (.prerelease | type == "boolean")
  ' <<<"$release" >/dev/null || return 1
  draft="$(jq -er '.draft | tostring' <<<"$release")" || return 1
  prerelease="$(jq -er '.prerelease | tostring' <<<"$release")" || return 1
  [ "$draft" = false ] || return 1

  jq -e --arg expected_url "$expected_release_url" \
    '.html_url == $expected_url' <<<"$release" >/dev/null || return 1
  if [ "$CHANNEL" = stable ]; then
    [ "$prerelease" = false ] || return 1
    is_stable_tag "$tag" || return 1
    version="${tag#v}"
    [ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "$tag" ] || return 1
    source_ref="refs/tags/$tag"
  else
    # A rolling `preview` pointer is an index, never a package source.
    is_preview_tag "$tag" || return 1
    preview_tag_commit="${tag#preview-}"
    [ "$prerelease" = true ] || return 1
    source_ref="refs/heads/main"
  fi

  source_commit="$(jq -er '.target_commitish | strings' <<<"$release")" || return 1
  valid_source_commit "$source_commit" || return 1
  if [ "$CHANNEL" = preview ]; then
    [ "$source_commit" = "$preview_tag_commit" ] || return 1
  fi
  release_asset_urls_are_canonical "$release" "$tag" || return 1
  resolve_immutable_release_ref "$tag" > "$tmp_dir/resolved-source-commit" || return 1
  resolved_source_commit="$(cat "$tmp_dir/resolved-source-commit")"
  [ "$resolved_source_commit" = "$source_commit" ] || return 1
  if [ "$CHANNEL" = preview ]; then
    resolve_preview_branch_ancestry "$source_commit" > "$tmp_dir/preview-provenance.json" || return 1
    preview_branch_provenance="$(cat "$tmp_dir/preview-provenance.json")"
  fi

  manifest_id="$(release_asset_id "$release" "$PRODUCT_MANIFEST_ASSET")" || return 1
  manifest_file="$tmp_dir/product-manifest-$manifest_id.json"
  fetch_asset "$manifest_id" "$manifest_file" "$PRODUCT_MANIFEST_ASSET"
  validate_external_manifest_digest "$release" "$manifest_file" > "$tmp_dir/manifest.sha256" || return 1
  manifest_sha="$(cat "$tmp_dir/manifest.sha256")"

  version="$(jq -er '.version | strings' "$manifest_file" 2>/dev/null)" || return 1
  if [ "$CHANNEL" = preview ]; then
    [ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "$version" ] || [ "$REQUESTED_VERSION" = "$tag" ] || return 1
  fi
  validate_product_manifest "$release" "$manifest_file" "$tag" "$version" "$source_ref" "$source_commit" || return 1
  validate_release_attestation "$release" "$tag" "$source_ref" "$source_commit" "$manifest_sha" "$manifest_file" || return 1

  local required_asset
  for required_asset in \
    "$PRODUCT_MANIFEST_ASSET" \
    "$PRODUCT_MANIFEST_ASSET.sha256" \
    release-manifest.json \
    SHA256SUMS \
    release-attestation.json \
    release-record.json \
    release-record.json.sha256 \
    manifest.json \
    manifest.json.sha256; do
    release_asset_is_complete "$release" "$required_asset" || return 1
  done
  validate_subordinate_records "$release" "$tag" "$source_ref" "$source_commit" "$version" "$manifest_sha" "$manifest_file" || return 1

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
    --arg release_url "$expected_release_url" \
    --argjson provider_repository_id "$provider_repository_id" \
    --argjson preview_branch_provenance "$preview_branch_provenance" \
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
      provider_repository_id: $provider_repository_id,
      provider_release_id: .id,
      release_url: $release_url,
      published_at: .published_at,
      target_commitish: .target_commitish,
      release_assets: $release_assets,
      source_ref_resolution: (
        {
          proof_ref: ("refs/tags/" + $tag),
          resolved_commit: $source_commit,
          method: "github-git-ref"
        } + (if $channel == "preview" then {
          declared_ref_provenance: $preview_branch_provenance
        } else {} end)
      ),
      manifest: $manifest[0]
    }' <<<"$release"
}

# Keep the producer-owned discovery result byte shape aligned with the typed
# schema-2 `DiscoverySelection` consumer. The central runtime revalidates this
# document before fetching; this source-side gate prevents a future helper
# change from silently dropping the immutable release/manifest/attestation
# binding that handoff relies on.
validate_selection_contract() {
  local selection="$1"
  jq -e \
    --arg manifest_asset "$PRODUCT_MANIFEST_ASSET" \
    --arg manifest_sidecar "$PRODUCT_MANIFEST_ASSET.sha256" \
    '
    (keys | sort) == [
      "channel","manifest","manifest_asset","manifest_schema",
      "manifest_sha256","package","product_id","provider_release_id",
      "provider_repository_id","published_at","release_assets","release_id",
      "release_tag","release_url","source_commit","source_ref",
      "source_ref_resolution","source_repository","tag","target_commitish",
      "version"
    ] and
    (.channel == "stable" or .channel == "preview") and
    .product_id == "velnor" and
    .manifest_asset == $manifest_asset and
    .manifest_schema == "velnor.product-manifest/v1" and
    (.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.release_id | type == "string" and test("^[1-9][0-9]*$")) and
    (.provider_release_id | type == "number" and . > 0 and floor == .) and
    (.provider_repository_id | type == "number" and . > 0 and floor == .) and
    (.release_assets | type == "array" and length > 0 and
      ([.[].id] | length == (unique | length)) and
      all(.[];
        (keys | sort) == ["browser_download_url","id","name","size","state"] and
        (.id | type == "number" and . > 0 and floor == .) and
        (.name | type == "string") and
        (.size | type == "number" and . > 0 and floor == .) and
        .state == "uploaded" and
        (.browser_download_url | type == "string")) and
      any(.[]; .name == "release-attestation.json")) and
    (([.release_assets[].name] | sort) ==
      (([.manifest.artifacts[].name] +
        [.manifest.artifacts[] | select(.kind == "apt-package") | .name + ".sha256"] +
        [$manifest_asset, $manifest_sidecar,
         "release-record.json", "release-record.json.sha256", "manifest.json",
         "manifest.json.sha256", "release-manifest.json", "SHA256SUMS",
         "release-attestation.json"]) | sort)) and
    (.source_ref_resolution | type == "object") and
    (.manifest | type == "object" and
      .schema == "velnor.product-manifest/v1" and
      .release_id == $selection.release_id and
      .version == $selection.version and
      .source_repository == $selection.source_repository and
      .source_ref == $selection.source_ref and
      .source_commit == $selection.source_commit and
      .release_tag == $selection.release_tag)
  ' --argjson selection "$selection" <<<"$selection" >/dev/null
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
  candidate_file="$tmp_dir/candidate-$index.json"
  # Do not capture validate_candidate in $(); fetch_asset calls fail(), and a
  # subshell would turn a provider error into an ineligible candidate.
  if validate_candidate "$release" > "$candidate_file"; then
    candidate="$(cat "$candidate_file")"
    if validate_selection_contract "$candidate"; then
      printf '%s\n' "$candidate" >> "$candidates"
    fi
  fi
done

[ -s "$candidates" ] || fail "no eligible $CHANNEL application release found in paginated release set"

if [ "$CHANNEL" = stable ]; then
  jq -s -e '
    def selection_key: (.version | split(".") | map(tonumber));
    sort_by(selection_key) as $ordered |
    $ordered[-1] as $winner |
    [$ordered[] | select(selection_key == ($winner | selection_key))] as $ties |
    if ($ties | length) == 1 then $winner
    else error("ambiguous stable application release version") end
  ' "$candidates"
else
  # Immutable preview releases are retained. Select the highest product
  # prerelease sequence after validation; never use a mutable pointer/latest.
  jq -s -e '
    def selection_key:
      (.version | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)-preview\\.(?<sequence>[0-9]+)\\+") |
        [.major,.minor,.patch,.sequence] | map(tonumber));
    sort_by(selection_key) as $ordered |
    $ordered[-1] as $winner |
    [$ordered[] | select(selection_key == ($winner | selection_key))] as $ties |
    if ($ties | length) == 1 then $winner
    else error("ambiguous preview application release version") end
  ' "$candidates"
fi
