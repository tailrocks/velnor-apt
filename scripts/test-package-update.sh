#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R "$root/." "$tmp/repo"
verified="$tmp/verified"
mkdir "$verified"
version=1.2.3
commit=0123456789abcdef0123456789abcdef01234567
: > "$tmp/assets.jsonl"
for arch in amd64 arm64; do
  name="velnor-runner-${version}-${arch}.deb"
  printf 'fixture-%s\n' "$arch" > "$verified/$name"
  digest=$(shasum -a 256 "$verified/$name" | awk '{print $1}')
  jq -cn --arg name "$name" --arg sha256 "$digest" '{name:$name,sha256:$sha256}' >> "$tmp/assets.jsonl"
done
jq -Sn --arg source_repository tailrocks/velnor --arg source_ref refs/tags/v$version \
  --arg source_commit "$commit" --arg version "$version" --slurpfile assets "$tmp/assets.jsonl" \
  '{schema:"velnor.package-release.v1",source_repository:$source_repository,source_ref:$source_ref,source_commit:$source_commit,version:$version,assets:$assets}' > "$verified/release-manifest.json"
jq -Sn --arg source_repository tailrocks/velnor --arg source_ref refs/tags/v$version \
  --arg source_digest "$commit" --slurpfile manifest "$verified/release-manifest.json" \
  '{source_repository:$source_repository,source_ref:$source_ref,source_digest:$source_digest,manifest:$manifest[0]}' > "$verified/identity.json"

(
  cd "$tmp/repo"
  VELNOR_VERIFIED_PACKAGE_DIR="$verified" ./scripts/package-update.sh
  shasum -a 256 package-state.json > "$tmp/first.sha"
  VELNOR_VERIFIED_PACKAGE_DIR="$verified" ./scripts/package-update.sh
  shasum -a 256 -c "$tmp/first.sha"
  jq -e '.version=="1.2.3" and (.packages|length)==2' package-state.json
)

cp "$tmp/repo/package-state.json" "$tmp/stable-state.json"
expect_stable_rejection() {
  local label="$1" input="$2" before

  rm -f "$tmp/repo/package-state.json"
  if (cd "$tmp/repo" && VELNOR_VERIFIED_PACKAGE_DIR="$input" ./scripts/package-update.sh) >/dev/null 2>&1; then
    echo "stable channel accepted: $label" >&2
    exit 1
  fi
  [ ! -e "$tmp/repo/package-state.json" ] \
    || { echo "stable state created despite rejection: $label" >&2; exit 1; }

  cp "$tmp/stable-state.json" "$tmp/repo/package-state.json"
  before=$(shasum -a 256 "$tmp/repo/package-state.json" | awk '{print $1}')
  if (cd "$tmp/repo" && VELNOR_VERIFIED_PACKAGE_DIR="$input" ./scripts/package-update.sh) >/dev/null 2>&1; then
    echo "stable channel accepted with prior state: $label" >&2
    exit 1
  fi
  [ "$(shasum -a 256 "$tmp/repo/package-state.json" | awk '{print $1}')" = "$before" ] \
    || { echo "stable state changed despite rejection: $label" >&2; exit 1; }
}

mkdir -p "$tmp/stable-bad"
for case in malformed missing-manifest missing-payload tampered-payload wrong-architecture \
  package-version duplicate-architecture arbitrary-digest null-digest identity-manifest \
  identity-source-digest asset-extra; do
  input="$tmp/stable-bad/$case"
  mkdir "$input"
  cp "$verified"/* "$input/"
  mutation=''
  case "$case" in
    malformed)
      printf '{\n' > "$input/release-manifest.json"
      ;;
    missing-manifest)
      rm "$input/release-manifest.json"
      ;;
    missing-payload)
      rm "$input/velnor-runner-${version}-arm64.deb"
      ;;
    tampered-payload)
      printf 'tampered\n' > "$input/velnor-runner-${version}-amd64.deb"
      ;;
    wrong-architecture)
      mutation='.assets[1].name = "velnor-runner-1.2.3-riscv64.deb"'
      ;;
    package-version)
      mutation='.assets[0].name = "velnor-runner-9.9.9-amd64.deb" |
                 .assets[1].name = "velnor-runner-9.9.9-arm64.deb"'
      ;;
    duplicate-architecture)
      mutation='.assets[1].name = "velnor-runner-9.9.9-amd64.deb"'
      ;;
    arbitrary-digest)
      mutation='.assets[0].sha256 = "not-a-digest"'
      ;;
    null-digest)
      mutation='.assets[0].sha256 = null'
      ;;
    identity-manifest)
      jq '.manifest.version = "9.9.9"' "$input/identity.json" > "$tmp/bad.json"
      mv "$tmp/bad.json" "$input/identity.json"
      ;;
    identity-source-digest)
      jq '.source_digest = "ffffffffffffffffffffffffffffffffffffffff"' "$input/identity.json" > "$tmp/bad.json"
      mv "$tmp/bad.json" "$input/identity.json"
      ;;
    asset-extra)
      mutation='.assets[0].extra = "unexpected"'
      ;;
  esac
  if [ -n "$mutation" ]; then
    jq "$mutation" "$input/release-manifest.json" > "$tmp/bad.json"
    mv "$tmp/bad.json" "$input/release-manifest.json"
  fi
  expect_stable_rejection "$case" "$input"
done

# ============================ preview channel ==================================
# The rolling `preview` release carries no release-record/identity pair: its
# release-manifest.json is the only source-owned record, the version follows
# X.Y.Z~preview.N+<7-hex> bound to the main commit, and the state lands in
# package-state-preview.json without ever touching package-state.json. The
# assets use the dotted form GitHub serves (`~` is rewritten to `.` on upload).
preview_version="1.2.3~preview.7+0123456"
preview_asset_version="1.2.3.preview.7+0123456"
pverified="$tmp/verified-preview"
mkdir "$pverified"
: > "$tmp/preview-assets.jsonl"
for arch in amd64 arm64; do
  name="velnor-runner-preview-${preview_asset_version}-${arch}.deb"
  printf 'preview-fixture-%s\n' "$arch" > "$pverified/$name"
  digest=$(shasum -a 256 "$pverified/$name" | awk '{print $1}')
  jq -cn --arg name "$name" --arg sha256 "$digest" '{name:$name,sha256:$sha256}' >> "$tmp/preview-assets.jsonl"
done
# The single-quoted jq program deliberately keeps jq variables literal for jq.
# shellcheck disable=SC2016
preview_manifest='{
  schema:"velnor.package-release.v1",
  source_repository:$source_repository,
  source_ref:$source_ref,
  source_commit:$source_commit,
  version:$version,
  assets:$assets
}'
jq -Sn --arg source_repository tailrocks/velnor --arg source_ref refs/heads/main \
  --arg source_commit "$commit" --arg version "$preview_version" \
  --slurpfile assets "$tmp/preview-assets.jsonl" "$preview_manifest" \
  > "$pverified/release-manifest.json"

(
  cd "$tmp/repo"
  shasum -a 256 package-state.json > "$tmp/stable-state.sha"
  VELNOR_PACKAGE_CHANNEL=preview VELNOR_VERIFIED_PACKAGE_DIR="$pverified" ./scripts/package-update.sh
  jq -e '.version=="1.2.3~preview.7+0123456" and .source_ref=="refs/heads/main" and
         (.packages|length)==2 and .schema=="velnor.apt-package-state.v1" and
         ([.packages[].name] | sort) == ([
           "velnor-runner-preview-1.2.3.preview.7+0123456-amd64.deb",
           "velnor-runner-preview-1.2.3.preview.7+0123456-arm64.deb"] | sort)' \
    package-state-preview.json
  shasum -a 256 -c "$tmp/stable-state.sha"
)

# Every incoherent preview manifest must be rejected without writing state and
# must preserve a previously valid preview state.
cp "$tmp/repo/package-state-preview.json" "$tmp/preview-state.json"
expect_preview_rejection() {
  local label="$1" input="$2" before

  rm -f "$tmp/repo/package-state-preview.json"
  if (cd "$tmp/repo" && VELNOR_PACKAGE_CHANNEL=preview \
        VELNOR_VERIFIED_PACKAGE_DIR="$input" ./scripts/package-update.sh) >/dev/null 2>&1; then
    echo "preview channel accepted: $label" >&2
    exit 1
  fi
  [ ! -e "$tmp/repo/package-state-preview.json" ] \
    || { echo "preview state created despite rejection: $label" >&2; exit 1; }

  cp "$tmp/preview-state.json" "$tmp/repo/package-state-preview.json"
  before=$(shasum -a 256 "$tmp/repo/package-state-preview.json" | awk '{print $1}')
  if (cd "$tmp/repo" && VELNOR_PACKAGE_CHANNEL=preview \
        VELNOR_VERIFIED_PACKAGE_DIR="$input" ./scripts/package-update.sh) >/dev/null 2>&1; then
    echo "preview channel accepted with prior state: $label" >&2
    exit 1
  fi
  [ "$(shasum -a 256 "$tmp/repo/package-state-preview.json" | awk '{print $1}')" = "$before" ] \
    || { echo "preview state changed despite rejection: $label" >&2; exit 1; }
}

mkdir -p "$tmp/preview-bad"
for case in ref grammar sha asset-name asset-version single-asset malformed missing-manifest \
  missing-payload tampered-payload wrong-architecture arbitrary-digest null-digest \
  asset-extra duplicate-architecture; do
  input="$tmp/preview-bad/$case"
  mkdir "$input"
  cp "$pverified"/* "$input/"
  mutation=''
  case "$case" in
    ref)           mutation='.source_ref = "refs/tags/v1.2.3"' ;;
    grammar)       mutation='.version = "1.2.3"' ;;
    sha)           mutation='.source_commit = "fffffffffffffffffffffffffffffffffffffff0"' ;;
    # A tilde asset name can never be served (`~` is rewritten to `.` on
    # upload); a dotted name for a foreign version is a different release.
    asset-name)    mutation='.assets[0].name = "velnor-runner-preview-9.9.9~preview.1+0123456-amd64.deb"' ;;
    asset-version) mutation='.assets[0].name = "velnor-runner-preview-9.9.9.preview.1+0123456-amd64.deb"' ;;
    single-asset)  mutation='.assets |= .[0:1]' ;;
    malformed)
      printf '{\n' > "$input/release-manifest.json"
      ;;
    missing-manifest)
      rm "$input/release-manifest.json"
      ;;
    missing-payload)
      rm "$input/velnor-runner-preview-${preview_asset_version}-arm64.deb"
      ;;
    tampered-payload)
      printf 'tampered\n' > "$input/velnor-runner-preview-${preview_asset_version}-amd64.deb"
      ;;
    wrong-architecture)
      mutation='.assets[1].name = "velnor-runner-preview-1.2.3.preview.7+0123456-riscv64.deb"'
      ;;
    arbitrary-digest)
      mutation='.assets[0].sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
      ;;
    null-digest)
      mutation='.assets[0].sha256 = null'
      ;;
    asset-extra)
      mutation='.assets[0].extra = "unexpected"'
      ;;
    duplicate-architecture)
      mutation='.assets[1].name = "velnor-runner-preview-1.2.3.preview.7+0123456-amd64.deb"'
      ;;
  esac
  if [ -n "$mutation" ]; then
    jq "$mutation" "$input/release-manifest.json" > "$tmp/bad.json"
    mv "$tmp/bad.json" "$input/release-manifest.json"
  fi
  expect_preview_rejection "$case" "$input"
done

# An unlisted channel must fail closed, exactly like an incoherent manifest.
rm -f "$tmp/repo/package-state-preview.json"
if (cd "$tmp/repo" && VELNOR_PACKAGE_CHANNEL=beta \
      VELNOR_VERIFIED_PACKAGE_DIR="$pverified" ./scripts/package-update.sh); then
  echo "unknown channel was accepted" >&2
  exit 1
fi
[ ! -e "$tmp/repo/package-state-preview.json" ] \
  || { echo "state written for an unknown channel" >&2; exit 1; }

echo "package-update preview channel checks passed"
