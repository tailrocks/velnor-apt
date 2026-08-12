#!/usr/bin/env bash
set -euo pipefail

verified=${VELNOR_VERIFIED_PACKAGE_DIR:?missing VELNOR_VERIFIED_PACKAGE_DIR}
manifest="$verified/release-manifest.json"
identity="$verified/identity.json"

jq -e '
  keys == ["manifest","source_digest","source_ref","source_repository"] and
  .source_repository == "tailrocks/velnor" and
  (.source_ref | test("^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.source_digest | test("^[0-9a-f]{40}$"))
' "$identity" >/dev/null

jq -e '
  keys == ["assets","schema","source_commit","source_ref","source_repository","version"] and
  .schema == "velnor.package-release.v1" and
  .source_repository == "tailrocks/velnor" and
  (.source_ref | test("^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.source_commit | test("^[0-9a-f]{40}$")) and
  (.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
  ([.assets[] | select(.name | test("^velnor-runner-[0-9]+[.][0-9]+[.][0-9]+-(amd64|arm64)[.]deb$"))] | length) == 2
' "$manifest" >/dev/null

test "$(jq -r .source_ref "$identity")" = "$(jq -r .source_ref "$manifest")"
test "$(jq -r .source_digest "$identity")" = "$(jq -r .source_commit "$manifest")"

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
}' "$manifest" > package-state.json

jq -e '
  keys == ["packages","schema","source_commit","source_ref","source_repository","version"] and
  .schema == "velnor.apt-package-state.v1" and
  (.packages | length) == 2 and
  [.packages[].name] == ([.packages[].name] | sort | unique)
' package-state.json >/dev/null
