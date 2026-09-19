#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/release-discovery.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/manifests" "$work/releases"

cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
endpoint=$(printf '%s\n' "$*" | awk '{print $NF}')
case "$*" in
  *"releases?per_page=100")
    if env | rg -q '^FAKE_API_FAILURE=1$'; then exit 23; fi
    cat "$FAKE_ROOT/pages.json"
    ;;
  *"/releases/assets/"*)
    if env | rg -q '^FAKE_MANIFEST_FAILURE=1$'; then exit 24; fi
    id=$(printf '%s\n' "$endpoint" | sed 's#^.*/##')
    cat "$FAKE_ROOT/manifests/$id"
    ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$work/bin/gh"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
asset() {
  jq -cn --argjson id "$1" --arg name "$2" \
    '{id:$id,name:$name,size:1,state:"uploaded",browser_download_url:("https://example.invalid/" + $name)}'
}
components() {
  jq -cn '[{name:"velnor-runner",crate:"velnor-runner",version:"0.1.277",binary:"velnor-runner",targets:["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin"]},
    {name:"velnorctl",crate:"velnorctl",version:"0.1.0",binary:"velnorctl",targets:["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin"]},
    {name:"velnor-workflow",crate:"velnor-workflow",version:"0.1.0",binary:"velnor-workflow",targets:["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin"]}]'
}
make_manifest() {
  local id="$1" version="$2" tag="$3" ref="$4" commit="$5" arm="$6" amd="$7" include_arm="$8" artifacts
  artifacts=$(jq -cn --arg amd "$amd" --arg arm "$arm" --argjson ok "$include_arm" \
    '[{name:$amd,target:"x86_64-unknown-linux-gnu",kind:"apt-package",sha256:("aa"*32),size:1}] +
     (if $ok then [{name:$arm,target:"aarch64-unknown-linux-gnu",kind:"apt-package",sha256:("bb"*32),size:1}] else [] end)')
  jq -S -n --arg version "$version" --arg tag "$tag" --arg ref "$ref" --arg commit "$commit" \
    --arg release_id "fixture-$tag" --argjson artifacts "$artifacts" --argjson components "$(components)" \
    '{schema:"velnor.product-manifest/v1",product_id:"velnor",
      channel:(if ($version|test("-preview[.]")) then "preview" else "stable" end),
      version:$version,source_repository:"tailrocks/velnor",source_ref:$ref,source_commit:$commit,
      release_tag:$tag,release_id:$release_id,artifacts:$artifacts,components:$components}' \
    > "$work/manifests/$id"
  sha256 "$work/manifests/$id" > "$work/manifests/$((id + 1))"
  local parent
  parent=$(sha256 "$work/manifests/$id")
  jq -S -n --arg tag "$tag" --arg commit "$commit" --arg version "$version" --arg parent "$parent" \
    --arg manifest_sha "pending" \
    '{schema:"velnor.release-record/v1",parent_manifest_sha256:$parent,
      build:{repository:"tailrocks/velnor",tag:$tag,commit:$commit,crate_version:$version,debian_version:$version,manifest_sha256:$manifest_sha}}' \
    > "$work/manifests/$((id + 2))"
  jq -S -n --arg ref "$ref" --arg commit "$commit" --arg version "$version" --arg parent "$parent" \
    '{schema:"velnor.package-release.v1",parent_manifest_sha256:$parent,source_repository:"tailrocks/velnor",source_ref:$ref,source_commit:$commit,version:$version,assets:[]}' \
    > "$work/manifests/$((id + 3))"
  jq -S -n --arg commit "$commit" --arg parent "$parent" \
    '{parent_manifest_sha256:$parent,source_sha:$commit,version:1,crate_version:"0.1.277"}' \
    > "$work/manifests/$((id + 4))"
  local manifest_sha
  manifest_sha=$(sha256 "$work/manifests/$((id + 4))")
  jq --arg manifest_sha "$manifest_sha" '.build.manifest_sha256 = $manifest_sha' \
    "$work/manifests/$((id + 2))" > "$work/manifests/$((id + 2)).tmp"
  mv "$work/manifests/$((id + 2)).tmp" "$work/manifests/$((id + 2))"
  sha256 "$work/manifests/$((id + 2))" > "$work/manifests/$((id + 2)).sha256"
  sha256 "$work/manifests/$((id + 4))" > "$work/manifests/$((id + 4)).sha256"
}
make_release() {
  local id="$1" tag="$2" prerelease="$3" commit="$4" amd="$5" arm="$6" include_arm="$7"
  local next=$((id * 100 + 1)) assets='[]' name obj
  local amd_sha arm_sha
  amd_sha=$(printf 'aa%.0s' {1..32})
  arm_sha=$(printf 'bb%.0s' {1..32})
  for name in product-manifest.json product-manifest.json.sha256 release-manifest.json SHA256SUMS release-record.json release-record.json.sha256 manifest.json manifest.json.sha256; do
    case "$name" in
      product-manifest.json) obj=$(asset "$id" "$name") ;;
      product-manifest.json.sha256) obj=$(asset "$((id + 1))" "$name") ;;
      release-record.json) obj=$(asset "$((id + 2))" "$name") ;;
      release-manifest.json) obj=$(asset "$((id + 3))" "$name") ;;
      manifest.json) obj=$(asset "$((id + 4))" "$name") ;;
      release-record.json.sha256) cp "$work/manifests/$((id + 2)).sha256" "$work/manifests/$next"; obj=$(asset "$next" "$name"); next=$((next + 1)) ;;
      manifest.json.sha256) cp "$work/manifests/$((id + 4)).sha256" "$work/manifests/$next"; obj=$(asset "$next" "$name"); next=$((next + 1)) ;;
      *) obj=$(asset "$next" "$name"); next=$((next + 1)) ;;
    esac
    assets=$(jq -c --argjson obj "$obj" '. + [$obj]' <<< "$assets")
  done
  for name in "$amd" "$amd.sha256"; do
    case "$name" in
      "$amd.sha256") printf '%s\n' "$amd_sha" > "$work/manifests/$next" ;;
    esac
    obj=$(asset "$next" "$name"); next=$((next + 1))
    assets=$(jq -c --argjson obj "$obj" '. + [$obj]' <<< "$assets")
  done
  if [ "$include_arm" = true ]; then
    for name in "$arm" "$arm.sha256"; do
      case "$name" in
        "$arm.sha256") printf '%s\n' "$arm_sha" > "$work/manifests/$next" ;;
      esac
      obj=$(asset "$next" "$name"); next=$((next + 1))
      assets=$(jq -c --argjson obj "$obj" '. + [$obj]' <<< "$assets")
    done
  fi
  jq -S -n --argjson id "$id" --arg tag "$tag" --argjson prerelease "$prerelease" --arg commit "$commit" --argjson assets "$assets" \
    '{id:$id,tag_name:$tag,draft:false,prerelease:$prerelease,target_commitish:$commit,html_url:("https://example.invalid/" + $tag),published_at:"2026-09-19T00:00:00Z",assets:$assets}' \
    > "$work/releases/$id"
}

c122=2222222222222222222222222222222222222222
c123=3333333333333333333333333333333333333333
c999=4444444444444444444444444444444444444444
make_manifest 122 1.2.2 v1.2.2 refs/tags/v1.2.2 "$c122" velnor-runner-1.2.2-arm64.deb velnor-runner-1.2.2-amd64.deb true
make_release 122 v1.2.2 false "$c122" velnor-runner-1.2.2-amd64.deb velnor-runner-1.2.2-arm64.deb true
make_manifest 222 1.2.3 v1.2.3 refs/tags/v1.2.3 "$c123" velnor-runner-1.2.3-arm64.deb velnor-runner-1.2.3-amd64.deb true
make_release 222 v1.2.3 false "$c123" velnor-runner-1.2.3-amd64.deb velnor-runner-1.2.3-arm64.deb true
make_manifest 999 9.9.9 v9.9.9 refs/tags/v9.9.9 "$c999" velnor-runner-9.9.9-arm64.deb velnor-runner-9.9.9-amd64.deb false
make_release 999 v9.9.9 false "$c999" velnor-runner-9.9.9-amd64.deb velnor-runner-9.9.9-arm64.deb false
make_manifest 333 7.7.7 v7.7.7 refs/tags/v7.7.7 "$c999" velnor-runner-7.7.7-arm64.deb velnor-runner-7.7.7-amd64.deb true
jq '.source_repository = "attacker/repo" | .source_ref = "refs/heads/main"' "$work/manifests/333" > "$work/manifests/333.tmp"
mv "$work/manifests/333.tmp" "$work/manifests/333"
sha256 "$work/manifests/333" > "$work/manifests/334"
make_release 333 v7.7.7 false "$c999" velnor-runner-7.7.7-amd64.deb velnor-runner-7.7.7-arm64.deb true
make_manifest 444 6.6.6 v6.6.6 refs/tags/v6.6.6 "$c999" velnor-runner-6.6.6-arm64.deb velnor-runner-6.6.6-amd64.deb true
printf '%s\n' '{malformed' > "$work/manifests/444"
sha256 "$work/manifests/444" > "$work/manifests/445"
make_release 444 v6.6.6 false "$c999" velnor-runner-6.6.6-amd64.deb velnor-runner-6.6.6-arm64.deb true

jq -S -n '{id:901,tag_name:"velnor-workflow-runtime-v1-newer",draft:false,prerelease:false,target_commitish:"5555555555555555555555555555555555555555",html_url:"https://example.invalid/runtime",published_at:"2026-09-19T00:00:00Z",assets:[{id:90101,name:"manifest.json",size:1,state:"uploaded",browser_download_url:"https://example.invalid/runtime"}]}' > "$work/releases/901"
jq -S -n '{id:902,tag_name:"v8.0.0",draft:false,prerelease:true,target_commitish:"6666666666666666666666666666666666666666",html_url:"https://example.invalid/pre",published_at:"2026-09-19T00:00:00Z",assets:[]}' > "$work/releases/902"
jq -s -c . "$work/releases/901" "$work/releases/902" "$work/releases/999" "$work/releases/333" "$work/releases/444" > "$work/page-1"
jq -s -c . "$work/releases/222" "$work/releases/122" > "$work/page-2"
cat "$work/page-1" "$work/page-2" > "$work/pages.json"
export FAKE_ROOT="$work" PATH="$work/bin:$PATH"

"$script" --channel stable > "$work/stable.json"
jq -e --arg commit "$c123" '.tag=="v1.2.3" and .version=="1.2.3" and .source_commit==$commit and .release_id=="fixture-v1.2.3" and .provider_release_id==222 and .manifest.schema=="velnor.product-manifest/v1" and (.manifest_sha256|test("^[0-9a-f]{64}$"))' "$work/stable.json" >/dev/null
"$script" --channel stable --version v1.2.2 > "$work/explicit.json"
jq -e --arg commit "$c122" '.tag=="v1.2.2" and .source_commit==$commit' "$work/explicit.json" >/dev/null

pver=1.2.3-preview.7+7777777
pdot=1.2.3.preview.7+7777777
pcommit=7777777777777777777777777777777777777777
ptag=preview-7777777777777777777777777777777777777777
make_manifest 777 "$pver" "$ptag" refs/heads/main "$pcommit" "velnor-runner-preview-$pdot-arm64.deb" "velnor-runner-preview-$pdot-amd64.deb" true
make_release 777 "$ptag" true "$pcommit" "velnor-runner-preview-$pdot-amd64.deb" "velnor-runner-preview-$pdot-arm64.deb" true
jq -s -c . "$work/releases/777" > "$work/pages.json"
printf stable-retained > "$work/package-state.json"
printf preview-retained > "$work/package-state-preview.json"
before_stable=$(sha256 "$work/package-state.json")
before_preview=$(sha256 "$work/package-state-preview.json")
(cd "$work" && "$script" --channel preview > preview.json)
jq -e --arg version "$pver" --arg commit "$pcommit" '.tag=="preview-"+$commit and .version==$version and .source_ref=="refs/heads/main" and .source_commit==$commit' "$work/preview.json" >/dev/null
[ "$(sha256 "$work/package-state.json")" = "$before_stable" ]
[ "$(sha256 "$work/package-state-preview.json")" = "$before_preview" ]

expect_failure() {
  local name="$1"; shift
  local stderr="$work/$name.stderr"
  if "$@" > /dev/null 2> "$stderr"; then echo "expected failure: $name" >&2; exit 1; fi
}
jq -s -c . "$work/releases/901" > "$work/pages.json"
expect_failure no-eligible "$script" --channel stable
grep -F 'no eligible stable application release' "$work/no-eligible.stderr" >/dev/null
jq -s -c . "$work/releases/902" > "$work/pages.json"
expect_failure old-only "$script" --channel stable
grep -F 'no eligible stable application release' "$work/old-only.stderr" >/dev/null
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure api-failure env FAKE_API_FAILURE=1 "$script" --channel stable
grep -F 'GitHub API failed while listing releases' "$work/api-failure.stderr" >/dev/null
expect_failure asset-api-failure env FAKE_MANIFEST_FAILURE=1 "$script" --channel stable
grep -F 'GitHub API failed while fetching' "$work/asset-api-failure.stderr" >/dev/null
jq -S -n '{id:778,tag_name:"preview",draft:false,prerelease:true,target_commitish:"7777777777777777777777777777777777777777",html_url:"https://example.invalid/preview",published_at:"2026-09-19T00:00:00Z",assets:[]}' > "$work/releases/778"
jq -s -c . "$work/releases/778" > "$work/pages.json"
expect_failure rolling-preview "$script" --channel preview
grep -F 'no eligible preview application release' "$work/rolling-preview.stderr" >/dev/null
echo 'release discovery checks passed'
