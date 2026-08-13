# GitHub workflow guidance

- Keep one workflow shape for Velnor, GitHub, and `both` lanes.
- Velnor is the default for secretless compute. Secret-bearing repository
  mutation jobs such as Renovate use pinned `ubuntu-26.04`; Velnor remains the
  read-only comparison lane for that workflow.
- Install tools and system packages through mise; commit `mise.lock`.
- Pin every third-party action to a full commit SHA.
- Keep permissions least-privilege, concurrency bounded, and every job timed out.
- Preserve identical repository-build semantics across lanes.
- Gate Pages artifact upload and deployment with `matrix.config.writer`; the
  GitHub-hosted lane is the only publisher because signing and Pages require
  credentials, while Velnor remains read-only verification.
- Never use `sudo` for cache ownership or permission repair. Only the audited
  mise OS-package bootstrap boundary may elevate internally.
