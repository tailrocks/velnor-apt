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

A coherent tagged `velnor-runner` release is independently verified and then
published here; `apt upgrade` picks it up.

## How it is built

1. [Velnor](https://github.com/tailrocks/velnor) builds both architecture
   packages, immutable OCI image, manifest, checksums, and one release record
   from the same tagged commit.
2. [`publish.yml`](.github/workflows/publish.yml) downloads those source-owned
   assets directly. It independently resolves the tag and verifies every
   package, manifest, image, signer, and record digest before `reprepro`.
3. Publication retains the exact previously signed package pair for rollback,
   signs fresh repository metadata plus a publication record, and deploys only
   the verified Pages artifact. Velnor is the default execution lane; operators
   may explicitly select GitHub or both lanes. Pages always uses GitHub Actions,
   never a branch.

Design and operator runbook: [velnor `docs/debian-apt-repo.md`](https://github.com/tailrocks/velnor/blob/main/docs/debian-apt-repo.md).

## Release and server deployment

1. Merge the signed-off Velnor release commit, then push its matching `vX.Y.Z`
   tag. The source workflow fails unless tag, crate, package, manifest, OCI, and
   source identities agree.
2. Dispatch `Publish apt repo` with that tag. The publisher downloads only the
   immutable source release, verifies coherence before `reprepro`, retains the
   signed previous pair, signs the new index/publication record, then deploys.
3. Before changing a server, verify that the signed candidate is visible:

   ```bash
   sudo apt-get update
   apt-cache policy velnor-runner
   ```

4. Drain the Velnor daemons and install the published candidate only through
   APT. Do not sideload a `.deb` or replace `/usr/bin/velnor-runner` directly:

   ```bash
   sudo apt-get install velnor-runner
   dpkg-query -W velnor-runner
   sudo systemctl start velnor-daemon
   ```

5. Run `velnor-runner doctor` and the fixture smoke test. The signed index keeps
   the previous coherent version available. Roll back only through APT after
   verifying its exact candidate; never sideload a release asset.

## One-time setup (maintainer)

- Create a dedicated GPG signing key (do not reuse across projects). Store the private key and passphrase securely. Manually copy the armored private key to the GitHub secret `APT_GPG_PRIVATE_KEY` and passphrase to `APT_GPG_PASSPHRASE`. Commit/publish the **public** half as `velnor.gpg` (and into the published tree).
- Set `SignWith:` in [`conf/distributions`](conf/distributions) to the key id.
- Enable **GitHub Pages** for this repo → Source: `GitHub Actions` (you should **always** use GitHub Actions for Pages deployments in these setups; never "Deploy from a branch").
- Set **Custom domain** to `velnor-apt.tailrocks.com`.
- Keep the committed `velnor.gpg` fingerprint equal to the private publisher
  key. The workflow fails before publication when they differ.

## Maintainer release path

1. Commit and push the Velnor release commit, then push its new `vX.Y.Z` tag.
2. Confirm Velnor's unified release workflow built and validated both
   architectures, manifest, OCI image, checksums, and release record.
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
