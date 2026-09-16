# NO_WORKFLOWS_REQUIRED

Clean-room regeneration at velnor @ e05aee6: `apt-repository` is a descriptive
profile label only. velnor-workflow has no Class-A/B primitive for APT feed CI
(ci-apt, publish, package-update, package-updater, renovate, composite actions).

Classification: **C** (`migrations/generic-workflow-generator/capability-matrix.md`
— "APT feed update").

Typed config produces `ci-unit-docs.yml` only. APT workflows are intentionally
omitted until the generator gains apt-repository primitives (signed reprepro +
Pages publish, package channel updater).

Omitted: `ci.yml`, `ci-apt.yml`, `publish.yml`, `package-update.yml`,
`package-updater.yml`, `renovate.yml`, and composite actions (`aggregate`,
`cache-contract`, `run-gate`).

No legacy workflow YAML was copied during this migration.
