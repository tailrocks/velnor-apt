# velnor-apt

apt repository for **[Velnor](https://github.com/donbeave/velnor)** — the
self-hosted GitHub Actions runner. Installs and upgrades `velnor-runner` (the
runner daemon) with native `apt`.

The signed repository is published to GitHub Pages at:

> https://www.zhokhov.com/velnor-apt/

## Install

```bash
# 1. trust the signing key (scoped to this repo via signed-by)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://www.zhokhov.com/velnor-apt/velnor.gpg \
  | sudo tee /etc/apt/keyrings/velnor.gpg > /dev/null

# 2. add the repo
echo "deb [signed-by=/etc/apt/keyrings/velnor.gpg] https://www.zhokhov.com/velnor-apt stable main" \
  | sudo tee /etc/apt/sources.list.d/velnor.list

# 3. install
sudo apt update
sudo apt install velnor-runner

# 4. configure the runner (token, repo URL, labels, slots) then start it
sudo nano /etc/velnor/velnor.env
sudo systemctl enable --now velnor-daemon
```

## Upgrade

```bash
sudo apt update && sudo apt upgrade
```

A new tagged release of `velnor-runner` adds a new `.deb` to this repo; `apt
upgrade` picks it up.

## How it is built

1. The [velnor](https://github.com/donbeave/velnor) repo builds the `.deb` with
   `cargo-deb` on a tagged release and attaches it to the GitHub Release.
2. The [`publish.yml`](.github/workflows/publish.yml) workflow here downloads that
   `.deb`, adds it to the apt pool with `reprepro` (which GPG-signs `Release` /
   `InRelease`), and publishes the tree (`dists/`, `pool/`, `velnor.gpg`) to the
   `gh-pages` branch → GitHub Pages.

Design notes: [velnor `docs/debian-apt-repo.md`](https://github.com/donbeave/velnor/blob/main/docs/debian-apt-repo.md).

## One-time setup (maintainer)

- Create a GPG signing key; add its **private** half + passphrase as repo secrets
  `APT_GPG_PRIVATE_KEY` and `APT_GPG_PASSPHRASE`; commit/publish the **public**
  half as `velnor.gpg` (and into the published tree).
- Set `SignWith:` in [`conf/distributions`](conf/distributions) to the key id.
- Enable **GitHub Pages** for this repo → Source: `gh-pages` branch.
- If [velnor](https://github.com/donbeave/velnor) is private, add a read token
  secret so `publish.yml` can download the release `.deb`.

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
