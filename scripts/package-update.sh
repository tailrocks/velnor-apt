#!/usr/bin/env bash
set -euo pipefail

# Channel selection. `stable` (default, and the historical contract) validates a
# tagged release and rewrites package-state.json. `preview` validates the rolling
# `preview` release and rewrites package-state-preview.json instead. Anything
# else fails closed.
channel=${VELNOR_PACKAGE_CHANNEL:-stable}
case "$channel" in
  stable) ;;
  preview) ;;
  *)
    printf 'package-update: unknown channel: %s\n' "$channel" >&2
    exit 1
    ;;
esac

# The preview suite sorts strictly before the corresponding release (dpkg `~`).
PREVIEW_VERSION_RE='^[0-9]+[.][0-9]+[.][0-9]+~preview[.][0-9]+\+[0-9a-f]{7}$'

verified=${VELNOR_VERIFIED_PACKAGE_DIR:?missing VELNOR_VERIFIED_PACKAGE_DIR}
manifest="$verified/release-manifest.json"
state=package-state.json
if [ "$channel" = preview ]; then
  # The rolling preview release ships no release-record/identity pair: its
  # release-manifest.json is the only source-owned coherence record, so the
  # identity cross-check below does not apply.
  state=package-state-preview.json
fi

identity="$verified/identity.json"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

validate_verified_package_assets() {
  local name digest payload actual
  while IFS=$'\t' read -r name digest; do
    [ -n "$name" ] || {
      printf 'package-update: manifest asset row is empty\n' >&2
      return 1
    }
    payload="$verified/$name"
    [ -f "$payload" ] || {
      printf 'package-update: verified asset is missing: %s\n' "$name" >&2
      return 1
    }
    actual="$(sha256_file "$payload")"
    [ "$actual" = "$digest" ] || {
      printf 'package-update: verified asset digest mismatch: %s\n' "$name" >&2
      return 1
    }
  done < <(jq -er '.assets[] | [.name,.sha256] | @tsv' "$manifest")
}

if [ "$channel" = stable ]; then
  jq -e '
    keys == ["manifest","source_digest","source_ref","source_repository"] and
    .source_repository == "tailrocks/velnor" and
    (.source_ref | test("^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.source_digest | test("^[0-9a-f]{40}$")) and
    (.manifest | type == "object")
  ' "$identity" >/dev/null

  jq -e --slurpfile manifest_copy "$manifest" '
    .manifest == $manifest_copy[0]
  ' "$identity" >/dev/null

  version="$(jq -er '.version | strings | select(test("^[0-9]+[.][0-9]+[.][0-9]+$"))' "$manifest")"
  jq -e --arg version "$version" '
    keys == ["assets","schema","source_commit","source_ref","source_repository","version"] and
    .schema == "velnor.package-release.v1" and
    .source_repository == "tailrocks/velnor" and
    (.source_ref | test("^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.source_commit | test("^[0-9a-f]{40}$")) and
    .version == $version and
    (.assets | type == "array" and length == 2) and
    ([.assets[].name] | sort) ==
      (["velnor-runner-" + $version + "-amd64.deb",
        "velnor-runner-" + $version + "-arm64.deb"] | sort) and
    all(.assets[];
      (keys | sort) == ["name","sha256"] and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  ' "$manifest" >/dev/null

  test "$(jq -r .source_ref "$identity")" = "$(jq -r .source_ref "$manifest")"
  test "$(jq -r .source_digest "$identity")" = "$(jq -r .source_commit "$manifest")"
else
  jq -e --arg version_re "$PREVIEW_VERSION_RE" '
    keys == ["assets","schema","source_commit","source_ref","source_repository","version"] and
    .schema == "velnor.package-release.v1" and
    .source_repository == "tailrocks/velnor" and
    .source_ref == "refs/heads/main" and
    (.source_commit | test("^[0-9a-f]{40}$")) and
    (.version | test($version_re)) and
    (.assets | length) == 2 and
    all(.assets[];
      (keys | sort) == ["name","sha256"] and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    .source_commit[0:7] ==
      (.version | capture("^[0-9]+[.][0-9]+[.][0-9]+~preview[.][0-9]+\\+(?<sha>[0-9a-f]{7})$").sha) and
    # GitHub rewrites release asset names on upload (`~` becomes `.`), so the
    # served assets are the dotted form while `.version` keeps the tilde
    # contract the version grammar and dpkg ordering are defined on.
    (.version as $v |
      ([.assets[].name] | sort) ==
      (["amd64","arm64"] |
        map("velnor-runner-preview-" + ($v | sub("~"; ".")) + "-" + . + ".deb") | sort))
  ' "$manifest" >/dev/null
fi

validate_verified_package_assets

jq -S '{
  schema:"velnor.apt-package-state.v1",
  source_repository,
  source_ref,
  source_commit,
  version,
  packages:(
    [.assets[] | select(.name | test("[. ]deb$")) | {name,sha256}]
    | sort_by(.name)
  )
}' "$manifest" > "$state"

jq -e '
  keys == ["packages","schema","source_commit","source_ref","source_repository","version"] and
  .schema == "velnor.apt-package-state.v1" and
  (.packages | length) == 2 and
  [.packages[].name] == ([.packages[].name] | sort | unique)
' "$state" >/dev/null

if [ "$channel" = preview ]; then
  jq -e --arg version_re "$PREVIEW_VERSION_RE" '
    (.version | test($version_re)) and
    all(.packages[]; (.sha256 | test("^[0-9a-f]{64}$"))) and
    # Same asset-name normalization as the manifest check: the recorded package
    # names are the dotted download keys, never the tilde version.
    (.version as $v |
      ([.packages[].name] | sort) ==
      (["amd64","arm64"] |
        map("velnor-runner-preview-" + ($v | sub("~"; ".")) + "-" + . + ".deb") | sort))
  ' "$state" >/dev/null
fi
