# GitHub workflow guidance

- Keep one workflow shape for Velnor, GitHub, and `both` lanes.
- Velnor is the default; GitHub uses pinned `ubuntu-26.04` only when selected.
- Install tools and system packages through mise; commit `mise.lock`.
- Pin every third-party action to a full commit SHA.
- Keep permissions least-privilege, concurrency bounded, and every job timed out.
- Preserve identical repository-build semantics across lanes.
- Gate Pages artifact upload and deployment with `matrix.config.writer`.
- Never use `sudo` for cache ownership or permission repair. Only the audited
  mise OS-package bootstrap boundary may elevate internally.
