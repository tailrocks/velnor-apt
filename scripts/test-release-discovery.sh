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
  *"repos/tailrocks/velnor")
    if [ "${FAKE_REPOSITORY_FAILURE:-}" = 1 ]; then exit 25; fi
    jq -cn \
      --arg full_name "${FAKE_REPOSITORY_FULL_NAME:-tailrocks/velnor}" \
      --argjson id "${FAKE_REPOSITORY_ID:-1255367013}" \
      '{id:$id,full_name:$full_name}'
    ;;
  *"releases?per_page=100")
    if [ "${FAKE_API_FAILURE:-}" = 1 ]; then exit 23; fi
    cat "$FAKE_ROOT/pages.json"
    ;;
  *"/releases/assets/"*)
    if [ "${FAKE_MANIFEST_FAILURE:-}" = 1 ]; then exit 24; fi
    id=$(printf '%s\n' "$endpoint" | sed 's#^.*/##')
    if [ -n "${FAKE_FAIL_ASSET_ID:-}" ] && [ "$id" = "$FAKE_FAIL_ASSET_ID" ]; then exit 24; fi
    cat "$FAKE_ROOT/manifests/$id"
    ;;
  *"/git/ref/tags/"*)
    tag=$(printf '%s\n' "$endpoint" | sed 's#^.*/##')
    if [ -n "${FAKE_FAIL_REF_TAG:-}" ] && [ "$tag" = "$FAKE_FAIL_REF_TAG" ]; then exit 26; fi
    commit=$(jq -s -er --arg tag "$tag" 'first(add[] | select(.tag_name == $tag) | .target_commitish)' "$FAKE_ROOT/pages.json")
    if [ "${FAKE_REF_MISMATCH:-}" = 1 ]; then commit=ffffffffffffffffffffffffffffffffffffffff; fi
    jq -cn --arg commit "$commit" '{object:{type:"commit",sha:$commit}}'
    ;;
  *"/compare/main..."*)
    commit=$(printf '%s\n' "$endpoint" | sed 's#^.*/compare/main\.\.\.##')
    if [ -n "${FAKE_FAIL_COMPARE_COMMIT:-}" ] && [ "$commit" = "$FAKE_FAIL_COMPARE_COMMIT" ]; then exit 27; fi
    case "${FAKE_PREVIEW_BRANCH_MODE:-behind}" in
      behind)
        jq -cn --arg commit "$commit" '{status:"behind",base_commit:{sha:("8888888888888888888888888888888888888888")},merge_base_commit:{sha:$commit}}'
        ;;
      identical)
        jq -cn --arg commit "$commit" '{status:"identical",base_commit:{sha:$commit},merge_base_commit:{sha:$commit}}'
        ;;
      non-ancestor)
        jq -cn --arg commit "$commit" '{status:"diverged",base_commit:{sha:("8888888888888888888888888888888888888888")},merge_base_commit:{sha:("7777777777777777777777777777777777777777")}}'
        ;;
      *) echo "unknown FAKE_PREVIEW_BRANCH_MODE" >&2; exit 2 ;;
    esac
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
  local size=1
  [ -z "${4:-}" ] || size=$(wc -c < "$4" | tr -d '[:space:]')
  jq -cn --argjson id "$1" --arg name "$2" --arg tag "$3" --argjson size "$size" \
    '{id:$id,name:$name,size:$size,state:"uploaded",browser_download_url:("https://github.com/tailrocks/velnor/releases/download/" + $tag + "/" + $name)}'
}
components() {
  jq -cn '[
    {name:"velnor-runner",crate:"velnor-runner",version:"0.1.277",binary:"velnor-runner",feature:"release-build",identity:"version",targets:["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin","x86_64-apple-darwin"]},
    {name:"velnor-workflow",crate:"velnor-workflow",version:"0.1.0",binary:"velnor-workflow",feature:null,identity:"revision",targets:["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin","x86_64-apple-darwin"]},
    {name:"velnorctl",crate:"velnorctl",version:"0.1.0",binary:"velnorctl",feature:"release-build",identity:"version",targets:["x86_64-unknown-linux-gnu","aarch64-unknown-linux-gnu","aarch64-apple-darwin","x86_64-apple-darwin"]}]'
}
make_manifest() {
  local id="$1" version="$2" tag="$3" ref="$4" commit="$5" arm="$6" amd="$7" include_arm="$8" artifacts='[]'
  local target component asset_name payload digest size archive_kind archive_name archive_path archive_dir
  local amd_payload="$work/manifests/payload-$id-$amd" arm_payload="$work/manifests/payload-$id-$arm"
  local amd_sha arm_sha amd_size arm_size

  # Disposable schema-compatible generation. The unique 18-row census is 12
  # binaries + 4 archives (2 Linux archives + 2 Apple Homebrew archives) + 2
  # APT packages. Native 990 intentionally blocks Intel and does not emit this
  # complete provider inventory; these bytes never claim producer authority.
  for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu aarch64-apple-darwin x86_64-apple-darwin; do
    while IFS=$'\t' read -r component; do
      asset_name="$component-$target"
      payload="$work/manifests/payload-$id-$asset_name"
      printf 'native-a8-fixture-%s-%s-%s\n' "$id" "$component" "$target" > "$payload"
      digest=$(sha256 "$payload")
      size=$(wc -c < "$payload" | tr -d '[:space:]')
      artifacts=$(jq -c --arg name "$asset_name" --arg target "$target" --arg digest "$digest" --argjson size "$size" \
        '. + [{name:$name,target:$target,kind:"binary",sha256:$digest,size:$size}]' <<<"$artifacts")
    done < <(components | jq -r '.[] | [.name] | @tsv')

    archive_name="velnorctl-$version-$target.tar.gz"
    archive_path="$work/manifests/payload-$id-$archive_name"
    archive_dir="$work/manifests/archive-$id-$target"
    mkdir -p "$archive_dir"
    printf 'archive-identity-%s-%s\n' "$id" "$target" > "$archive_dir/identity.json"
    printf 'archive-manifest-%s-%s\n' "$version" "$target" > "$archive_dir/manifest.json"
    while IFS=$'\t' read -r component; do
      printf 'archive-component-%s-%s-%s\n' "$id" "$component" "$target" > "$archive_dir/$component"
    done < <(components | jq -r '.[] | [.name] | @tsv')
    tar -czf "$archive_path" -C "$archive_dir" identity.json manifest.json velnor-runner velnor-workflow velnorctl
    rm -rf -- "$archive_dir"
    digest=$(sha256 "$archive_path")
    size=$(wc -c < "$archive_path" | tr -d '[:space:]')
    archive_kind=archive
    case "$target" in *-apple-darwin) archive_kind=homebrew-archive ;; esac
    artifacts=$(jq -c --arg name "$archive_name" --arg target "$target" --arg kind "$archive_kind" --arg digest "$digest" --argjson size "$size" \
      '. + [{name:$name,target:$target,kind:$kind,sha256:$digest,size:$size}]' <<<"$artifacts")
  done

  printf 'fixture-amd64-%s\n' "$id" > "$amd_payload"
  amd_sha=$(sha256 "$amd_payload")
  amd_size=$(wc -c < "$amd_payload" | tr -d '[:space:]')
  printf 'fixture-arm64-%s\n' "$id" > "$arm_payload"
  arm_sha=$(sha256 "$arm_payload")
  arm_size=$(wc -c < "$arm_payload" | tr -d '[:space:]')
  artifacts=$(jq -c --arg name "$amd" --arg target "x86_64-unknown-linux-gnu" --arg digest "$amd_sha" --argjson size "$amd_size" \
    '. + [{name:$name,target:$target,kind:"apt-package",sha256:$digest,size:$size}]' <<<"$artifacts")
  if [ "$include_arm" = true ]; then
    artifacts=$(jq -c --arg name "$arm" --arg target "aarch64-unknown-linux-gnu" --arg digest "$arm_sha" --argjson size "$arm_size" \
      '. + [{name:$name,target:$target,kind:"apt-package",sha256:$digest,size:$size}]' <<<"$artifacts")
  fi
  jq -S -n --arg version "$version" --arg tag "$tag" --arg ref "$ref" --arg commit "$commit" \
    --arg release_id "$id" --argjson artifacts "$artifacts" --argjson components "$(components)" \
    '{schema:"velnor.product-manifest/v1",product_id:"velnor",
      channel:(if ($version|test("-preview[.]")) then "preview" else "stable" end),
      version:$version,source_repository:"tailrocks/velnor",source_ref:$ref,source_commit:$commit,
      release_tag:$tag,release_id:$release_id,artifacts:$artifacts,components:$components}' \
    > "$work/manifests/$id"
  sha256 "$work/manifests/$id" > "$work/manifests/$((id + 1))"
  local parent
  parent=$(sha256 "$work/manifests/$id")
  jq -S -n --arg commit "$commit" --arg parent "$parent" \
    '{parent_manifest_sha256:$parent,source_sha:$commit,version:1,crate_version:"0.1.277"}' \
    > "$work/manifests/$((id + 4))"
  local manifest_sha
  manifest_sha=$(sha256 "$work/manifests/$((id + 4))")
  jq -S -n --arg tag "$tag" --arg commit "$commit" --arg version "$version" --arg parent "$parent" \
    --arg manifest_sha "$manifest_sha" --arg amd_sha "$amd_sha" --arg arm_sha "$arm_sha" \
    --argjson ok "$include_arm" \
    '{schema:"velnor.release-record/v1",parent_manifest_sha256:$parent,
      build:{repository:"tailrocks/velnor",tag:$tag,commit:$commit,crate_version:$version,debian_version:$version,manifest_version:1,manifest_sha256:$manifest_sha},
      architectures:([
        {arch:"amd64",target:"x86_64-unknown-linux-gnu",binary_sha256:("cc"*32),deb_sha256:$amd_sha,oci_platform_digest:("sha256:" + ("aa"*32))}
      ] + (if $ok then [
        {arch:"arm64",target:"aarch64-unknown-linux-gnu",binary_sha256:("dd"*32),deb_sha256:$arm_sha,oci_platform_digest:("sha256:" + ("bb"*32))}
      ] else [] end)),
      oci_index_digest:("sha256:" + ("ee"*32)),
      oci_image_ref:("ghcr.io/tailrocks/velnor/app@sha256:" + ("ee"*32)),
      oci_labels:{version:$version,revision:$commit,source:"https://github.com/tailrocks/velnor",manifest_sha256:$manifest_sha},
      apt:{origin:"Velnor",suite:(if ($version|test("-preview[.]")) then "preview" else "stable" end),component:"main"}}' \
    > "$work/manifests/$((id + 2))"
  jq -S -n --arg ref "$ref" --arg commit "$commit" --arg version "$version" --arg parent "$parent" \
    --argjson artifacts "$artifacts" \
    '{schema:"velnor.package-release.v1",parent_manifest_sha256:$parent,source_repository:"tailrocks/velnor",source_ref:$ref,source_commit:$commit,version:$version,assets:[$artifacts[] | select(.kind == "apt-package") | {name,sha256}]}' \
    > "$work/manifests/$((id + 3))"
  sha256 "$work/manifests/$((id + 2))" > "$work/manifests/$((id + 2)).sha256"
  sha256 "$work/manifests/$((id + 4))" > "$work/manifests/$((id + 4)).sha256"
}
make_release() {
  local id="$1" tag="$2" prerelease="$3" commit="$4" amd="$5" arm="$6" include_arm="$7"
  local next=$((id * 100 + 1)) assets='[]' name obj body attestation_file manifest_sha
  local amd_sha arm_sha artifact_name artifact_kind payload sidecar
  amd_sha=$(sha256 "$work/manifests/payload-$id-$amd")
  arm_sha=$(sha256 "$work/manifests/payload-$id-$arm")
  manifest_sha=$(sha256 "$work/manifests/$id")
  attestation_file="$work/manifests/attestation-$id"
  jq -S -n --arg source_ref "$(jq -er '.source_ref' "$work/manifests/$id")" \
    --arg source_commit "$commit" --arg tag "$tag" --arg release_id "$id" \
    --arg manifest_sha "$manifest_sha" --argjson artifacts "$(jq -c '.artifacts' "$work/manifests/$id")" \
    '{schema:"velnor.github-release-attestation/v1",provider:"github",
      source_repository:"tailrocks/velnor",source_ref:$source_ref,source_commit:$source_commit,
      resolved_source_ref:$source_ref,resolved_source_commit:$source_commit,release_tag:$tag,
      release_id:$release_id,target_commitish:$source_commit,
      release_url:("https://github.com/tailrocks/velnor/releases/tag/" + $tag),
      manifest_sha256:$manifest_sha,assets:$artifacts}' > "$attestation_file"
  for name in product-manifest.json product-manifest.json.sha256 release-manifest.json SHA256SUMS release-record.json release-record.json.sha256 manifest.json manifest.json.sha256 release-attestation.json; do
    body=''
    case "$name" in
      product-manifest.json) body="$work/manifests/$id"; obj=$(asset "$id" "$name" "$tag" "$body") ;;
      product-manifest.json.sha256) body="$work/manifests/$((id + 1))"; obj=$(asset "$((id + 1))" "$name" "$tag" "$body") ;;
      release-record.json) body="$work/manifests/$((id + 2))"; obj=$(asset "$((id + 2))" "$name" "$tag" "$body") ;;
      release-manifest.json) body="$work/manifests/$((id + 3))"; obj=$(asset "$((id + 3))" "$name" "$tag" "$body") ;;
      release-attestation.json)
        cp -- "$attestation_file" "$work/manifests/$next"
        obj=$(asset "$next" "$name" "$tag" "$work/manifests/$next"); next=$((next + 1)) ;;
      SHA256SUMS)
        if [ "$include_arm" = true ]; then
          printf '%s  %s\n%s  %s\n' "$amd_sha" "$amd" "$arm_sha" "$arm" > "$work/manifests/$next"
        else
          printf '%s  %s\n' "$amd_sha" "$amd" > "$work/manifests/$next"
        fi
        body="$work/manifests/$next"; obj=$(asset "$next" "$name" "$tag" "$body"); next=$((next + 1)) ;;
      manifest.json) body="$work/manifests/$((id + 4))"; obj=$(asset "$((id + 4))" "$name" "$tag" "$body") ;;
      release-record.json.sha256) cp "$work/manifests/$((id + 2)).sha256" "$work/manifests/$next"; obj=$(asset "$next" "$name" "$tag" "$work/manifests/$next"); next=$((next + 1)) ;;
      manifest.json.sha256) cp "$work/manifests/$((id + 4)).sha256" "$work/manifests/$next"; obj=$(asset "$next" "$name" "$tag" "$work/manifests/$next"); next=$((next + 1)) ;;
      *) obj=$(asset "$next" "$name" "$tag"); next=$((next + 1)) ;;
    esac
    assets=$(jq -c --argjson obj "$obj" '. + [$obj]' <<< "$assets")
  done
  while IFS=$'\t' read -r artifact_name artifact_kind; do
    payload="$work/manifests/payload-$id-$artifact_name"
    cp -- "$payload" "$work/manifests/$next"
    obj=$(asset "$next" "$artifact_name" "$tag" "$work/manifests/$next"); next=$((next + 1))
    assets=$(jq -c --argjson obj "$obj" '. + [$obj]' <<< "$assets")
    if [ "$artifact_kind" = apt-package ]; then
      sidecar="$work/manifests/payload-$id-$artifact_name.sha256"
      printf '%s\n' "$(sha256 "$payload")" > "$sidecar"
      cp -- "$sidecar" "$work/manifests/$next"
      obj=$(asset "$next" "$artifact_name.sha256" "$tag" "$work/manifests/$next"); next=$((next + 1))
      assets=$(jq -c --argjson obj "$obj" '. + [$obj]' <<< "$assets")
    fi
  done < <(jq -r '.artifacts[] | [.name,.kind] | @tsv' "$work/manifests/$id")
  jq -S -n --argjson id "$id" --arg tag "$tag" --argjson prerelease "$prerelease" --arg commit "$commit" --argjson assets "$assets" \
    '{id:$id,tag_name:$tag,draft:false,prerelease:$prerelease,target_commitish:$commit,html_url:("https://github.com/tailrocks/velnor/releases/tag/" + $tag),published_at:"2026-09-19T00:00:00Z",assets:$assets}' \
    > "$work/releases/$id"
}

c122=2222222222222222222222222222222222222222
c123=3333333333333333333333333333333333333333
c999=4444444444444444444444444444444444444444
make_manifest 122 1.2.2 v1.2.2 refs/tags/v1.2.2 "$c122" velnor-runner-1.2.2-arm64.deb velnor-runner-1.2.2-amd64.deb true
make_release 122 v1.2.2 false "$c122" velnor-runner-1.2.2-amd64.deb velnor-runner-1.2.2-arm64.deb true
make_manifest 222 1.2.3 v1.2.3 refs/tags/v1.2.3 "$c123" velnor-runner-1.2.3-arm64.deb velnor-runner-1.2.3-amd64.deb true
make_release 222 v1.2.3 false "$c123" velnor-runner-1.2.3-amd64.deb velnor-runner-1.2.3-arm64.deb true
c124=1212121212121212121212121212121212121212
make_manifest 555 1.2.4 v1.2.4 refs/tags/v1.2.4 "$c124" velnor-runner-1.2.4-arm64.deb velnor-runner-1.2.4-amd64.deb true
make_release 555 v1.2.4 false "$c124" velnor-runner-1.2.4-amd64.deb velnor-runner-1.2.4-arm64.deb true
make_manifest 999 9.9.9 v9.9.9 refs/tags/v9.9.9 "$c999" velnor-runner-9.9.9-arm64.deb velnor-runner-9.9.9-amd64.deb false
make_release 999 v9.9.9 false "$c999" velnor-runner-9.9.9-amd64.deb velnor-runner-9.9.9-arm64.deb false
make_manifest 333 7.7.7 v7.7.7 refs/tags/v7.7.7 "$c999" velnor-runner-7.7.7-arm64.deb velnor-runner-7.7.7-amd64.deb true
jq '.source_repository = "attacker/repo" | .source_ref = "refs/heads/main"' "$work/manifests/333" > "$work/manifests/333.tmp"
mv "$work/manifests/333.tmp" "$work/manifests/333"
sha256 "$work/manifests/333" > "$work/manifests/334"
make_release 333 v7.7.7 false "$c999" velnor-runner-7.7.7-amd64.deb velnor-runner-7.7.7-arm64.deb true
make_manifest 444 6.6.6 v6.6.6 refs/tags/v6.6.6 "$c999" velnor-runner-6.6.6-arm64.deb velnor-runner-6.6.6-amd64.deb true
make_release 444 v6.6.6 false "$c999" velnor-runner-6.6.6-amd64.deb velnor-runner-6.6.6-arm64.deb true
printf '%s\n' '{malformed' > "$work/manifests/444"
sha256 "$work/manifests/444" > "$work/manifests/445"

jq -S -n '{id:901,tag_name:"velnor-workflow-runtime-v1-newer",draft:false,prerelease:false,target_commitish:"5555555555555555555555555555555555555555",html_url:"https://example.invalid/runtime",published_at:"2026-09-19T00:00:00Z",assets:[{id:90101,name:"manifest.json",size:1,state:"uploaded",browser_download_url:"https://example.invalid/runtime"}]}' > "$work/releases/901"
jq -S -n '{id:902,tag_name:"v8.0.0",draft:false,prerelease:true,target_commitish:"6666666666666666666666666666666666666666",html_url:"https://example.invalid/pre",published_at:"2026-09-19T00:00:00Z",assets:[]}' > "$work/releases/902"
jq -s -c . "$work/releases/901" "$work/releases/902" "$work/releases/999" "$work/releases/333" "$work/releases/444" > "$work/page-1"
jq -s -c . "$work/releases/222" "$work/releases/122" > "$work/page-2"
cat "$work/page-1" "$work/page-2" > "$work/pages.json"
export FAKE_ROOT="$work" PATH="$work/bin:$PATH"

# This is a schema-shaped synthetic fixture. It is not a native 990 release:
# that producer intentionally blocks Intel and therefore has no complete
# four-target provider output. Keep provider release metadata and payload bytes
# synthetic below; fail if the checked-in fixture drifts from the reviewed
# schema2 contract. Renderer provenance is recorded beside the fixture.
native_fixture="$root/tests/fixtures/native-product/product-manifest.json"
native_fixture_sidecar="$native_fixture.sha256"
native_fixture_provenance="$root/tests/fixtures/native-product/provenance.json"
native_fixture_sha=$(sha256 "$native_fixture")
[ "$(awk 'NF == 2 {print $1 "  " $2}' "$native_fixture_sidecar")" = "$native_fixture_sha  product-manifest.json" ]
jq -e --arg fixture_sha "$native_fixture_sha" '
  .fixture_status == "synthetic-schema-fixture" and
  .provider_authoritative == false and
  .cryptographic_attestation_verified == false and
  .native_renderer_commit == "9908296d28d27e0d5b993d1e48ea7a96bc31db83" and
  .native_renderer_result == "1 passed, 1868 filtered out" and
  .renderer_output_persisted == false and
  .fixture_manifest_sha256 == $fixture_sha and
  (.blocked_native_targets == ["x86_64-apple-darwin"])
' "$native_fixture_provenance" >/dev/null
# The 18 rows are unique: 12 binaries + 4 archives (2 Linux archive plus 2
# Apple Homebrew archive) + 2 APT packages. Homebrew rows are in the archive
# total, not an additional count.
jq -e '
  (keys | sort) == ["artifacts","channel","components","product_id","release_id","release_tag","schema","source_commit","source_ref","source_repository","version"] and
  .schema == "velnor.product-manifest/v1" and .product_id == "velnor" and
  (.release_id | type == "string" and test("^[1-9][0-9]*$")) and
  (.components | length == 3) and (.components | all(.targets | length == 4)) and
  (.artifacts | length == 18) and
  ((.artifacts | map(.kind) | sort | group_by(.) | map({kind:.[0],count:length})) ==
    [{kind:"apt-package",count:2},{kind:"archive",count:2},{kind:"binary",count:12},{kind:"homebrew-archive",count:2}])
' "$native_fixture" >/dev/null

"$script" --channel stable > "$work/stable.json"
jq -e --arg commit "$c123" '.tag=="v1.2.3" and .version=="1.2.3" and .source_commit==$commit and .release_id=="222" and .provider_repository_id==1255367013 and .provider_release_id==222 and .manifest.schema=="velnor.product-manifest/v1" and (.manifest.components | length == 3) and (.manifest.components | all(.targets | length == 4)) and (.manifest.artifacts | length == 18) and ((.manifest.artifacts | map(.kind) | sort | group_by(.) | map({kind:.[0],count:length})) == [{kind:"apt-package",count:2},{kind:"archive",count:2},{kind:"binary",count:12},{kind:"homebrew-archive",count:2}]) and (.manifest_sha256|test("^[0-9a-f]{64}$"))' "$work/stable.json" >/dev/null
jq -e '
  (keys | sort) == [
    "channel","manifest","manifest_asset","manifest_schema",
    "manifest_sha256","package","product_id","provider_release_id",
    "provider_repository_id","published_at","release_assets","release_id",
    "release_tag","release_url","source_commit","source_ref",
    "source_ref_resolution","source_repository","tag","target_commitish",
    "version"
  ] and
  .manifest_asset == "product-manifest.json" and
  .manifest_schema == "velnor.product-manifest/v1" and
  .manifest.release_id == .release_id and
  .manifest.version == .version and
  .manifest.source_repository == .source_repository and
  .manifest.source_ref == .source_ref and
  .manifest.source_commit == .source_commit and
  .manifest.release_tag == .release_tag and
  any(.release_assets[]; .name == "release-attestation.json")
' "$work/stable.json" >/dev/null
"$script" --channel stable --version v1.2.2 > "$work/explicit.json"
jq -e --arg commit "$c122" '.tag=="v1.2.2" and .source_commit==$commit' "$work/explicit.json" >/dev/null

pver=1.2.3-preview.7+7777777
pdot=1.2.3.preview.7+7777777
pcommit=7777777777777777777777777777777777777777
ptag=preview-7777777777777777777777777777777777777777
make_manifest 777 "$pver" "$ptag" refs/heads/main "$pcommit" "velnor-runner-preview-$pdot-arm64.deb" "velnor-runner-preview-$pdot-amd64.deb" true
make_release 777 "$ptag" true "$pcommit" "velnor-runner-preview-$pdot-amd64.deb" "velnor-runner-preview-$pdot-arm64.deb" true
pver8=1.2.3-preview.8+8888888
pdot8=1.2.3.preview.8+8888888
pcommit8=8888888888888888888888888888888888888888
ptag8=preview-8888888888888888888888888888888888888888
make_manifest 888 "$pver8" "$ptag8" refs/heads/main "$pcommit8" "velnor-runner-preview-$pdot8-arm64.deb" "velnor-runner-preview-$pdot8-amd64.deb" true
make_release 888 "$ptag8" true "$pcommit8" "velnor-runner-preview-$pdot8-amd64.deb" "velnor-runner-preview-$pdot8-arm64.deb" true
jq -s -c . "$work/releases/777" > "$work/pages.json"
printf stable-retained > "$work/package-state.json"
printf preview-retained > "$work/package-state-preview.json"
before_stable=$(sha256 "$work/package-state.json")
before_preview=$(sha256 "$work/package-state-preview.json")
(cd "$work" && "$script" --channel preview > preview.json)
jq -e --arg version "$pver" --arg commit "$pcommit" '.tag=="preview-"+$commit and .version==$version and .source_ref=="refs/heads/main" and .source_commit==$commit and .source_ref_resolution.proof_ref==("refs/tags/preview-"+$commit) and .source_ref_resolution.declared_ref_provenance.ref=="refs/heads/main" and .source_ref_resolution.declared_ref_provenance.relation=="ancestor" and .source_ref_resolution.declared_ref_provenance.merge_base_commit==$commit' "$work/preview.json" >/dev/null
[ "$(sha256 "$work/package-state.json")" = "$before_stable" ]
[ "$(sha256 "$work/package-state-preview.json")" = "$before_preview" ]

expect_failure() {
  local name="$1"; shift
  local stderr="$work/$name.stderr"
  local stdout="$work/$name.stdout"
  if "$@" > "$stdout" 2> "$stderr"; then echo "expected failure: $name" >&2; exit 1; fi
}

expect_failure requested-stable-leading-zero "$script" --channel stable --version v01.2.3
expect_failure requested-preview-leading-zero "$script" --channel preview --version 01.2.3-preview.7+7777777

# SemVer components and preview sequences are canonical decimals. Leading
# zeroes must not create a second spelling of a provider release/version.
attestation_asset_id=$(jq -er '.assets[] | select(.name == "release-attestation.json") | .id' "$work/releases/222")
for path in 222 223 224 225 22201 22202 226 22203; do cp "$work/manifests/$path" "$work/baseline-$path"; done
cp "$work/manifests/$attestation_asset_id" "$work/baseline-attestation"
cp "$work/releases/222" "$work/baseline-release-222"
restore_candidate() {
  for path in 222 223 224 225 22201 22202 226 22203; do cp "$work/baseline-$path" "$work/manifests/$path"; done
  cp "$work/baseline-attestation" "$work/manifests/$attestation_asset_id"
  cp "$work/baseline-release-222" "$work/releases/222"
  jq -s -c . "$work/releases/222" > "$work/pages.json"
}

jq '.tag_name = "v01.2.3"' "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure stable-leading-zero-tag "$script" --channel stable

jq '.version = "01.2.3-preview.7+7777777"' "$work/manifests/777" > "$work/manifests/777.tmp"
mv "$work/manifests/777.tmp" "$work/manifests/777"
sha256 "$work/manifests/777" > "$work/manifests/778"
jq -s -c . "$work/releases/777" > "$work/pages.json"
expect_failure preview-leading-zero-version "$script" --channel preview

restore_candidate
jq 'del(.assets[] | select(.name == "release-attestation.json"))' "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure missing-release-attestation "$script" --channel stable

restore_candidate
jq '.release_id = "999"' "$work/manifests/$attestation_asset_id" > "$work/manifests/$attestation_asset_id.tmp"
mv "$work/manifests/$attestation_asset_id.tmp" "$work/manifests/$attestation_asset_id"
expect_failure release-attestation-identity "$script" --channel stable

restore_candidate
jq '.release_url = "https://evil.example/releases/tag/v1.2.3"' "$work/manifests/$attestation_asset_id" > "$work/manifests/$attestation_asset_id.tmp"
mv "$work/manifests/$attestation_asset_id.tmp" "$work/manifests/$attestation_asset_id"
expect_failure release-attestation-url "$script" --channel stable

restore_candidate
jq '.assets[0].sha256 = ("f" * 64)' "$work/manifests/$attestation_asset_id" > "$work/manifests/$attestation_asset_id.tmp"
mv "$work/manifests/$attestation_asset_id.tmp" "$work/manifests/$attestation_asset_id"
expect_failure release-attestation-assets "$script" --channel stable

restore_candidate

(cd "$work" && expect_failure preview-source-not-ancestor env FAKE_PREVIEW_BRANCH_MODE=non-ancestor "$script" --channel preview)
grep -F 'no eligible preview application release' "$work/preview-source-not-ancestor.stderr" >/dev/null
jq -s -c . "$work/releases/901" > "$work/pages.json"
expect_failure no-eligible "$script" --channel stable
grep -F 'no eligible stable application release' "$work/no-eligible.stderr" >/dev/null
jq -s -c . "$work/releases/902" > "$work/pages.json"
expect_failure old-only "$script" --channel stable
grep -F 'no eligible stable application release' "$work/old-only.stderr" >/dev/null
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure api-failure env FAKE_API_FAILURE=1 "$script" --channel stable
grep -F 'GitHub API failed while listing releases' "$work/api-failure.stderr" >/dev/null
expect_failure repository-api-failure env FAKE_REPOSITORY_FAILURE=1 "$script" --channel stable
grep -F 'GitHub API failed while fetching repository identity' "$work/repository-api-failure.stderr" >/dev/null
expect_failure repository-identity-mismatch env FAKE_REPOSITORY_FULL_NAME=evil/repo "$script" --channel stable
grep -F 'GitHub API repository identity does not match the selected source' "$work/repository-identity-mismatch.stderr" >/dev/null
expect_failure asset-api-failure env FAKE_MANIFEST_FAILURE=1 "$script" --channel stable
grep -F 'GitHub API failed while fetching' "$work/asset-api-failure.stderr" >/dev/null
# Newer listed release fails the provider fetch; older remains valid. A
# swallowed fail() would emit 1.2.3. Provider errors must abort instead.
restore_candidate
jq -s -c . "$work/releases/555" "$work/releases/222" > "$work/pages.json"
expect_failure mixed-newer-api-fail-older-valid env FAKE_FAIL_ASSET_ID=555 "$script" --channel stable
grep -F 'GitHub API failed while fetching' "$work/mixed-newer-api-fail-older-valid.stderr" >/dev/null
if grep -q '"version":"1.2.3"' "$work/mixed-newer-api-fail-older-valid.stdout"; then
  echo "provider failure selected older release" >&2
  exit 1
fi
[ ! -s "$work/mixed-newer-api-fail-older-valid.stdout" ]
# Sidecar 556 is fetched only from validate_external_manifest_digest (was $()).
restore_candidate
jq -s -c . "$work/releases/555" "$work/releases/222" > "$work/pages.json"
expect_failure mixed-newer-sidecar-api-fail-older-valid env FAKE_FAIL_ASSET_ID=556 "$script" --channel stable
grep -F 'GitHub API failed while fetching' "$work/mixed-newer-sidecar-api-fail-older-valid.stderr" >/dev/null
if grep -q '"version":"1.2.3"' "$work/mixed-newer-sidecar-api-fail-older-valid.stdout"; then
  echo "sidecar provider failure selected older release" >&2
  exit 1
fi
[ ! -s "$work/mixed-newer-sidecar-api-fail-older-valid.stdout" ]
# Newer tag-ref transport failure must abort, not emit older 1.2.3.
restore_candidate
jq -s -c . "$work/releases/555" "$work/releases/222" > "$work/pages.json"
expect_failure mixed-newer-ref-api-fail-older-valid env FAKE_FAIL_REF_TAG=v1.2.4 "$script" --channel stable
grep -F 'GitHub API failed while resolving tag ref' "$work/mixed-newer-ref-api-fail-older-valid.stderr" >/dev/null
if grep -q '"version":"1.2.3"' "$work/mixed-newer-ref-api-fail-older-valid.stdout"; then
  echo "tag-ref provider failure selected older release" >&2
  exit 1
fi
[ ! -s "$work/mixed-newer-ref-api-fail-older-valid.stdout" ]
# Newer preview compare transport failure must abort, not emit preview.7.
jq -s -c . "$work/releases/888" "$work/releases/777" > "$work/pages.json"
expect_failure mixed-newer-compare-api-fail-older-valid env FAKE_FAIL_COMPARE_COMMIT=8888888888888888888888888888888888888888 "$script" --channel preview
grep -F 'GitHub API failed while comparing main' "$work/mixed-newer-compare-api-fail-older-valid.stderr" >/dev/null
if grep -q '1.2.3-preview.7' "$work/mixed-newer-compare-api-fail-older-valid.stdout"; then
  echo "compare provider failure selected older preview" >&2
  exit 1
fi
[ ! -s "$work/mixed-newer-compare-api-fail-older-valid.stdout" ]
jq -S -n '{id:778,tag_name:"preview",draft:false,prerelease:true,target_commitish:"7777777777777777777777777777777777777777",html_url:"https://example.invalid/preview",published_at:"2026-09-19T00:00:00Z",assets:[]}' > "$work/releases/778"
jq -s -c . "$work/releases/778" > "$work/pages.json"
expect_failure rolling-preview "$script" --channel preview
grep -F 'no eligible preview application release' "$work/rolling-preview.stderr" >/dev/null

# Hostile mutations stay internally byte-addressed where practical. Each
# mutation must make the typed application candidate ineligible.
restore_candidate
jq '.assets += [{id:999999,name:"unexpected-extra.txt",size:1,state:"uploaded",browser_download_url:"https://github.com/tailrocks/velnor/releases/download/v1.2.3/unexpected-extra.txt"}]' \
  "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure extra-release-asset "$script" --channel stable

restore_candidate
duplicate_asset_id=$(jq -er '.assets[0].id' "$work/releases/222")
jq --argjson duplicate_id "$duplicate_asset_id" '.assets[1].id = $duplicate_id' \
  "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure duplicate-release-asset-id "$script" --channel stable

for control_name in discovery.json product-manifest.json product-manifest.json.sha256 \
  release-manifest.json SHA256SUMS release-record.json release-record.json.sha256 \
  manifest.json manifest.json.sha256 release-attestation.json; do
  restore_candidate
  jq --arg name "$control_name" '.artifacts[0].name = $name' \
    "$work/manifests/222" > "$work/manifests/222.tmp"
  mv "$work/manifests/222.tmp" "$work/manifests/222"
  sha256 "$work/manifests/222" > "$work/manifests/223"
  control_test_name=$(printf '%s' "$control_name" | tr '[:upper:].' '[:lower:]-')
  expect_failure "reserved-control-$control_test_name" "$script" --channel stable
done

restore_candidate
jq '.components[] |= if .name == "velnorctl" then .binary = "evilctl" else . end' \
  "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
expect_failure binary-name-drift "$script" --channel stable

restore_candidate
jq '(.artifacts[] | select(.kind == "archive" and .target == "x86_64-unknown-linux-gnu")).target = "aarch64-unknown-linux-gnu"' \
  "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
expect_failure archive-target-census "$script" --channel stable

restore_candidate
jq '(.artifacts[0].kind) = "unknown-artifact"' \
  "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
expect_failure unknown-artifact-kind "$script" --channel stable

restore_candidate
printf 'tampered\n' > "$work/manifests/22201"
expect_failure sha256-sums-tamper "$script" --channel stable

restore_candidate
jq '.assets = [{name:"wrong.deb",sha256:("e" * 64)}]' \
  "$work/manifests/225" > "$work/manifests/225.tmp"
mv "$work/manifests/225.tmp" "$work/manifests/225"
expect_failure release-manifest-assets-tamper "$script" --channel stable

restore_candidate
jq '.architectures = []' "$work/manifests/224" > "$work/manifests/224.tmp"
mv "$work/manifests/224.tmp" "$work/manifests/224"
sha256 "$work/manifests/224" > "$work/manifests/22202"
expect_failure release-record-census "$script" --channel stable

restore_candidate
printf 'homebrew-good\n' > "$work/manifests/homebrew-good"
homebrew_sha=$(sha256 "$work/manifests/homebrew-good")
homebrew_size=$(wc -c < "$work/manifests/homebrew-good" | tr -d '[:space:]')
jq --arg name "velnorctl-1.2.3-aarch64-apple-darwin.tar.gz" --arg sha "$homebrew_sha" \
  --argjson size "$homebrew_size" '.artifacts += [{name:$name,target:"aarch64-apple-darwin",kind:"homebrew-archive",sha256:$sha,size:$size}]' \
  "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
printf 'tampered-homebrew\n' > "$work/manifests/2299"
jq --arg name "velnorctl-1.2.3-aarch64-apple-darwin.tar.gz" \
  '.assets += [{id:2299,name:$name,size:17,state:"uploaded",browser_download_url:("https://github.com/tailrocks/velnor/releases/download/v1.2.3/" + $name)}]' \
  "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure homebrew-digest-tamper "$script" --channel stable

restore_candidate
jq '(.assets[] | select(.name == "product-manifest.json")).browser_download_url = ""' \
  "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure asset-url-missing "$script" --channel stable

restore_candidate
expect_failure source-ref-mismatch env FAKE_REF_MISMATCH=1 "$script" --channel stable

restore_candidate
jq '.id = 222 | .html_url = "https://github.com/tailrocks/velnor/releases/tag/v1.2.3"' \
  "$work/releases/222" > "$work/releases/duplicate"
jq -s -c . "$work/releases/222" "$work/releases/duplicate" > "$work/pages.json"
expect_failure ambiguous-version "$script" --channel stable

restore_candidate
jq '.release_id = "bad release id"' "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
expect_failure release-id-grammar "$script" --channel stable

restore_candidate
jq '.release_id = "0222"' "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
expect_failure release-id-leading-zero "$script" --channel stable

restore_candidate
jq '.release_id = "223"' "$work/manifests/222" > "$work/manifests/222.tmp"
mv "$work/manifests/222.tmp" "$work/manifests/222"
sha256 "$work/manifests/222" > "$work/manifests/223"
expect_failure release-id-provider-mismatch "$script" --channel stable

restore_candidate
jq '.version = 999' "$work/manifests/226" > "$work/manifests/226.tmp"
mv "$work/manifests/226.tmp" "$work/manifests/226"
sha256 "$work/manifests/226" > "$work/manifests/22203"
expect_failure package-manifest-version "$script" --channel stable

restore_candidate
jq '.crate_version = "evil"' "$work/manifests/226" > "$work/manifests/226.tmp"
mv "$work/manifests/226.tmp" "$work/manifests/226"
sha256 "$work/manifests/226" > "$work/manifests/22203"
expect_failure package-manifest-crate-version "$script" --channel stable

restore_candidate
jq '.html_url = "https://evil.example/release"' "$work/releases/222" > "$work/releases/222.tmp"
mv "$work/releases/222.tmp" "$work/releases/222"
jq -s -c . "$work/releases/222" > "$work/pages.json"
expect_failure release-url-origin "$script" --channel stable

echo 'release discovery checks passed'
