# Mix application graphs (experimental)

Mix evaluates project semantics. Bazel schedules and caches one OTP application
per compilation action. APIs and the manifest schema remain experimental.

## Analyze and pin dependencies

Fetch with ordinary Mix explicitly, then run the analyzer from a ruleset checkout:

```sh
cd /path/to/project
mix deps.get --check-locked
elixir /path/to/rules_elixir/tools/dependency_sync.exs \
  --project . --output rules_elixir.lock.json
# Check without rewriting:
elixir /path/to/rules_elixir/tools/dependency_sync.exs \
  --project . --output rules_elixir.lock.json --check
```

Pass `--input ../VERSION` for additional files read by `mix.exs`. Extra inputs
must exist. The manifest fingerprints `mix.exs`, the lockfile and extra inputs,
which identify the dependency graph. Configuration is loaded during analysis but
is not fingerprinted: a configuration edit needs no new manifest unless it
changes the resolved graph. Arbitrary reads from project code are not
automatically discoverable: declare their inputs.

Each environment is analyzed in a fresh VM. Schema 1 has `dev`, `test` and `prod`
snapshots, each with a root, resolved packages and input hashes. Edges retain
`runtime`, `optional`, `override` and dependency-specific environment metadata.
Sources retain Hex package/application distinctions, exact versions and outer
checksums, full Git revisions, or path provenance. Mix performs convergence;
there is no Starlark version resolver or manual edge-removal list.

Umbrella roots, custom dependency `compile`/`system_env` options,
non-OTP dependencies, custom Hex repositories and sparse/subdirectory Git sources currently
fail explicitly.
