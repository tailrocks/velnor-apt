# Native product manifest fixture

These bytes are the canonical `velnor.product-manifest/v1` assembly fixture
consumed by the APT projection. The producer-side rendered assembly test owns
the executable native payload generation and contract verification; this
fixture keeps only its manifest bytes and detached checksum in the consumer
repository. Provider release metadata, asset bytes, and cryptographic
attestation remain test-only inputs in `scripts/test-release-discovery.sh`.

Producer source: `tailrocks/velnor`, branch
`codex/github-first-native-product-v3`, renderer checkpoint
`9908296d28d27e0d5b993d1e48ea7a96bc31db83`.
