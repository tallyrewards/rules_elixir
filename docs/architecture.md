# Mix application graph

Mix evaluates project semantics. Bazel fetches pinned sources, schedules one
compile action per OTP application, and caches the resulting artifacts.

```text
mix.exs + mix.lock + configuration
                 |
        offline Mix analysis
                 |
     checked-in JSON manifest
                 |
      Bzlmod source repositories
                 |
   independently compiled OTP apps
                 |
           tests / releases
```

## Contracts

- **Exact dependencies.** The manifest records immutable source identities and
  the resolved dev, test and prod graphs. Mix handles dependency convergence;
  conflicting application instances fail rather than selecting another version.
- **Dependencies read only the configuration they use.** A dependency compiles
  in its own environment, normally `prod`, against the configured values of
  the application environment keys it reads, recorded by compiling it once
  without root configuration. Other configuration is not one of its inputs.
- **One application per action.** Mix or Rebar compiles against dependencies
  already built by Bazel. Compile aliases are preserved, and build actions
  block network access. Compiled dependencies are shared through symlinks.
- **Ordinary OTP providers.** Applications export the public `ErlangAppInfo`.
  `MixProjectInfo` adds the project definition Mix consumers evaluate.
- **Precompiled consumers.** Tests use the shared test graph and map Bazel shards
  to Mix partitions. Named releases assemble the prod graph using the release
  configuration in `mix.exs`.
- **Declared native tools.** Public `rules_cc` APIs provide C/C++ compilers and
  flags. Auxiliary executables are supplied by a separate toolchain. Generic
  rules contain no package-name build policies.

## Current limits

The rules and manifest schema are experimental. See [the usage guide](mix.md)
for supported inputs and explicit adapter boundaries.

The default cache boundary is an OTP application. A source edit can therefore
recompile the whole application and invalidate all of its test shards. Opt-in
persistent Mix state workers keep Mix's build directory between compilations,
but only within a live worker; cached application outputs cannot recreate it. This
optimization is experimental and does not implement affected-test selection.

The OTP adapter uses the public Erlang toolchain and application provider.
Existing direct Elixir compilation rules remain available, and their dependency
views link existing application directories instead of copying them.

Configured Elixir distributions are checksum verified and extracted during
repository setup. Source compilation and prebuilt staging use declared files
and require no action-time downloads. Low-level `elixir_build` and
`elixir_prebuilt` targets now take `srcs` and a `root` marker file; URL-based
callers should use the existing module-extension tags, which retain their API.

The pinned rules_erlang source/prebuilt rules still fetch OTP archives in build
actions and unpack them to an absolute installation path. Their public toolchain
exposes that archive/path, rather than a relocatable runtime and shared-library
closure. Closing this gap requires changes in the shared OTP toolchain; adding
a second OTP build implementation here would duplicate its ownership.

System OTP, Elixir, C compilers, SDKs and shell utilities do not establish
hermetic remote execution. The Linux fixture has passed remote execution with
network access disabled and the client checkout and caches hidden from workers.
A fresh output directory reused every cached action and received identical
release bytes. Production adoption still requires validation with fully declared
toolchains or an immutable worker image. See [remote validation](remote.md). Native
compilation currently requires matching execution and target CPU/OS; separate
platform payloads remain future work. Compile actions check native output headers
for the target CPU and file format. Runtime fixtures must still verify ABI
compatibility and shared-library dependencies.

Project code can read undeclared files or environment variables. Declare those
inputs explicitly. Conditional compilation must depend on declared dependencies,
rather than modules incidentally loaded by another project's compiler session.
Runtime code must keep mutable data outside compiled application directories.

Compilation normalizes Elixir debug and documentation source paths without
changing executable code or user literals. Some macros preserve absolute source
paths inside executable literals; those BEAM files can differ across build
directories. Semantic release comparison remains necessary even when remote
cache reuse reproduces a producer's bytes exactly.

Test databases, service startup, asset generation and final image packaging
belong to consuming projects. Compare application metadata, actual BEAM files,
resources, startup modes and runtime configuration before replacing an existing
build pipeline. `tools/compare_releases.exs` checks release metadata, BEAM
inventories and runtime configuration; resource and native behavior checks
remain application-specific.

## Regression coverage

Repository fixtures exercise semantic drift, graph rejection, root configuration,
dependency aliases, generated files and trees, compile-only dependencies, Rebar,
native loading during compilation and release execution, test shards, and
relocated named releases. The existing compatibility suite is retained. CI is
configured for the documented Elixir/OTP pairs and the Mix fixture on Linux and
macOS; local results do not substitute for hosted matrix validation.
