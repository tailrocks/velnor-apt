# velnor-apt

apt repository for **[Velnor](https://github.com/tailrocks/velnor)** — the
self-hosted GitHub Actions runner. Installs and upgrades `velnor-runner` (the
runner daemon) with native `apt`.

The signed repository is published to GitHub Pages at:

> https://velnor-apt.tailrocks.com/

## Install

```bash
# 1. trust the signing key (scoped to this repo via signed-by)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://velnor-apt.tailrocks.com/velnor.gpg \
  | sudo tee /etc/apt/keyrings/velnor.gpg > /dev/null

# 2. add the repo
echo "deb [signed-by=/etc/apt/keyrings/velnor.gpg] https://velnor-apt.tailrocks.com stable main" \
  | sudo tee /etc/apt/sources.list.d/velnor.list

# 3. install
sudo apt update
sudo apt install velnor-runner

# 4. configure non-secret settings and the operator-owned token separately
sudo nano /etc/velnor/velnor.env
sudo install -m 0600 /dev/null /etc/velnor/secrets.env
sudo nano /etc/velnor/secrets.env  # GITHUB_TOKEN=...
sudo systemctl enable --now velnor-daemon
```

## Upgrade

```bash
sudo apt update && sudo apt install velnor-runner
apt-cache policy velnor-runner
dpkg-query -W velnor-runner
```

A new tagged release of `velnor-runner` adds a new `.deb` to this repo; `apt
upgrade` picks it up.

## How it is built

1. The [velnor](https://github.com/tailrocks/velnor) repo builds the `.deb` with
   `cargo-deb` on a tagged release and attaches it to the GitHub Release
   (the .deb is part of the original project's release process).
2. If a PAT is configured, it also cross-uploads the .deb to the `velnor-apt`
   repository's Releases (same tag) and triggers the publish workflow.
3. The [`publish.yml`](.github/workflows/publish.yml) workflow here downloads the
   .deb from *this* repo's own release, adds it to the apt pool with `reprepro`,
   uploads the tree as a GitHub Pages artifact, and deploys it using GitHub
   Actions. The index on Pages includes only currently published versions (old .debs remain in historical Releases but are not part of the current apt repo). GitHub Pages is deployed via GitHub Actions, never from a branch.

Design notes: [velnor `docs/debian-apt-repo.md`](https://github.com/tailrocks/velnor/blob/main/docs/debian-apt-repo.md).

## One-time setup (maintainer)

- Create a dedicated GPG signing key (do not reuse across projects). Store the private key and passphrase securely. Manually copy the armored private key to the GitHub secret `APT_GPG_PRIVATE_KEY` and passphrase to `APT_GPG_PASSPHRASE`. Commit/publish the **public** half as `velnor.gpg` (and into the published tree).
- Set `SignWith:` in [`conf/distributions`](conf/distributions) to the key id.
- Enable **GitHub Pages** for this repo → Source: `GitHub Actions` (you should **always** use GitHub Actions for Pages deployments in these setups; never "Deploy from a branch").
- Set **Custom domain** to `velnor-apt.tailrocks.com`.
- If [velnor](https://github.com/tailrocks/velnor) is private, add a read token
  secret so `publish.yml` can download the release `.deb`.

## Maintainer release path

1. Commit and push the Velnor release commit, then push its new `vX.Y.Z` tag.
2. Confirm Velnor's `Release deb` workflow built and validated both architectures,
   uploaded the matching release assets here, and dispatched `Publish apt repo`.
3. Confirm this repository's publish and Pages deployment jobs are green.
4. Verify `dists/stable/InRelease` and the new `apt-cache policy` candidate
   before upgrading any server. Servers install only from this signed repository;
   do not sideload `.deb` release assets.

## License

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
