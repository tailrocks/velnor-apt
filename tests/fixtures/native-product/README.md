# Native product manifest fixture

This is a schema-shaped synthetic fixture for the APT consumer. It is not a
published native release and is not authoritative provider or signing
evidence. Native renderer checkpoint `9908296d28d27e0d5b993d1e48ea7a96bc31db83`
intentionally blocks `x86_64-apple-darwin`, so it cannot emit a complete
four-target provider inventory. The fixture therefore keeps the reviewed
four-target census only for offline consumer tests.

The unique 18-row census is 12 binaries + 4 archives (2 Linux `archive` rows
and 2 Apple `homebrew-archive` rows) + 2 APT packages. The Apple rows are part
of the four archive rows, not an additional pair.

The reviewed native renderer was executed with synthetic inputs in its clean
990 worktree:

```text
cargo test --locked --manifest-path crates/velnor-workflow/Cargo.toml \
  rendered_native_product_assembly_produces_runner_and_homebrew_contract_bytes \
  -- --nocapture
```

That test passed (`1 passed, 1868 filtered out`). It validates the producer
assembly path and schema, but its temporary output is removed; it does not
produce this checked-in fixture or prove provider authority. Exact source and
fixture digests are recorded in `provenance.json`.

The APT consumer performs structural identity/census checks here. Cryptographic
release-attestation verification remains the central runtime's real verifier;
these fixture bytes must never be treated as cryptographic proof.
