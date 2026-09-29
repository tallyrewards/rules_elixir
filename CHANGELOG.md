# Changelog

## Unreleased — experimental Mix graph

- Upgrade to rules_erlang 3.21.0 and use its public toolchain and application APIs.
- Fetch Elixir distributions during repository setup; direct rules now use srcs and root.
- Include Erlang sources, headers and resources in the Hex bootstrap archive.
- Export versioned Mix dependency manifests using offline dev, test and prod analysis.
- Compile Mix applications with declared configuration, resources and prebuilt OTP dependencies.
- Compile Rebar applications offline against the same OTP providers.
- Normalize temporary source paths in BEAM debug and documentation metadata.
- Materialize checked-in dependency graphs and reject ambiguous sources, missing edges and cycles.
- Check manifest drift offline, including verified Git provenance without checkout metadata.
- Compile each dependency against only the root configuration keys it reads.
- Reject an override target that provides a different application.
- Declare native compiler inputs and auxiliary tools, preserve runfiles and reject unsupported platforms.
- Run ExUnit against the precompiled test graph and retain requested test outputs.
- Set Mix partition identity before configuration and preserve external partitions when unsharded.

## 1.3.0

Adds a third way to supply Elixir: an already-compiled distribution.

### Added

- **`prebuilt_elixir_from_http_archive` and `prebuilt_elixir_from_hex_builds`**
  (`bzlmod/extensions.bzl`, `repositories/elixir_config.bzl`,
  new `repositories/BUILD_prebuilt.tpl`, new `elixir_prebuilt` in
  `private/elixir_build.bzl`).

  The mirror of what rules_erlang 3.20.0 added for OTP, and for the same reason:
  neither existing path can consume a downloadable prebuilt.
  `external_elixir_from_path` needs an `elixir_home` that already exists on the
  machine running the action, and `internal_elixir_from_http_archive` always feeds
  its URL to `elixir_build`, which runs `make`.

  `elixir_build` extracts a source archive, runs `make`, and copies the resulting
  `bin/` and `lib/` into the release directory. A precompiled distribution *is*
  those two directories, so staging one is extraction plus the same validation
  step -- run `iex --version` and record what it reports.

  ```python
  elixir_config_ext.prebuilt_elixir_from_hex_builds(
      name = "elixir_1_19_4",
      version = "1.19.4",
      otp_major = "28",
      sha256 = "8fd7b5705b756c0e1ec71f9e8281b4b75801b9564f0205b5035319e8505ad2b4",
  )
  ```

  **Unlike OTP, no relocation step is needed.** An OTP installation bakes ROOTDIR
  into its start scripts and ships an `Install` script to repoint it; Elixir's
  launchers resolve their own root relative to `argv[0]`, so a precompiled
  distribution works from wherever it is unpacked.

  **Also unlike OTP, one archive serves every platform.** Elixir compiles to BEAM
  bytecode, which is architecture-independent -- the published archive contains no
  native objects -- which is why `prebuilt_elixir_from_hex_builds` takes an
  `otp_major` rather than an `arch`/`os` pair, and why there is no
  `exec_compatible_with` attribute here.

  The rule accepts both zip and tar archives, because hex.pm publishes a zip while
  other distributions are tarballs, and GNU tar cannot read zip. It fails with an
  explicit message when `unzip` is absent for a zip input, and when the extracted
  archive has no `bin/` and `lib/` -- the likely mistake being an Elixir *source*
  archive, whose failure would otherwise surface as a confusing missing-file error
  after extraction.

  As with the OTP change, a prebuilt installation registers under the existing
  `:elixir_internal` constraint and keeps the `:elixir_build` target name, so
  moving a repository between the source and prebuilt paths is a `MODULE.bazel`
  edit and nothing else.

## 1.2.0

First release from <https://github.com/bazelverse/rules_elixir>.

Continues from the **v1.1.0** tag of the unmaintained upstream, carrying the
fixes that were being kept downstream as a vendored copy. Requires
`rules_erlang` **3.18.0**.

Every change is a separate commit, so `git diff v1.1.0..v1.2.0` is exactly this
list and nothing else.

### Fixed

- **Skip system Elixir** (`repositories/elixir_config.bzl`). Honour
  `RULES_ELIXIR_SKIP_SYSTEM=1`, so a build can use a hermetic toolchain instead
  of probing the host for an Elixir install.

- **Portable tarball extraction** (`private/elixir_build.bzl`). The same GNU-tar
  assumption fixed in rules_erlang 3.18.0. `--transform` does not exist in the
  bsdtar that macOS ships, so every Elixir target failed on macOS before
  compiling anything.

- **Allow an empty `LICENSE` glob** (`elixir_app.bzl`). `elixir_app` hard-failed
  on any package without a `LICENSE` file.

- **Compile-time data** (`elixir_app.bzl`, `private/elixir_bytecode.bzl`).
  `elixir_bytecode` could not declare compile-time file inputs, so a package
  reading a file during compilation, or declaring `@external_resource`, failed in
  the sandbox.

- **ExUnit test headers** (`private/ex_unit_test.bzl`). `ex_unit_test` staged its
  dependencies without their `include/` directories, so a test using
  `Record.extract(from_lib: ...)` died before running a case. Compilation rules
  stage headers; tests now do too.

- **ExUnit workspace layout** (`private/ex_unit_test.bzl`). `ex_unit_test`
  flattened `srcs` and `data` by stripping the package prefix, which breaks any
  test resolving a repository-relative path off `__DIR__`.

- **Stage test inputs into `TEST_TMPDIR`** (`private/ex_unit_test.bzl`).
  `ex_unit_test` copied every `srcs` and `data` file into
  `TEST_UNDECLARED_OUTPUTS_DIR` and ran there. Bazel treats that directory as
  artifacts the test *produced*, so it stats and mime-types every entry to build
  the manifest, then uploads them. Each target shipped a few thousand of its own
  inputs to the CAS per run. On a remote executor carrying no `file(1)` it also
  emitted roughly 2,150 "command not found" lines per test. Nothing was ever
  collected from there on purpose.

- **Migrate off the deprecated Windows condition** (`ex_unit_test.bzl`).
  `@bazel_tools//src/conditions:host_windows` is deprecated and warned on every
  `ex_unit_test` target; it is now the `@platforms//os:windows` constraint. This
  is also a semantic correction. The old key matched the *host*, while the flag
  decides whether the generated runner is a batch file or a shell script, a
  property of the platform the test *executes* on. For a test rule that is the
  target platform.

  The key is a `Label`, not a bare string. A `select()` key written as a string
  resolves against the repo mapping of the package that *instantiates* the macro,
  so a string would have obliged every consumer to add
  `bazel_dep(name = "platforms")` of their own and failed with "No repository
  visible as `@platforms`" if they did not. The question never arose while the
  key was `@bazel_tools//...`, because `bazel_tools` is an implicit dependency of
  every module and is visible from everywhere.

- **ExUnit result detection under Elixir 1.20** (`private/ex_unit_test.bzl`). The
  runner asserted on the summary text, matching `0 failure` and `[0-9] test`.
  Elixir 1.20 replaced `N tests, M failures` with `Result: N passed`, so under it
  every *passing* suite failed its own assertion.

  Failure detection now rests on the exit code, which the `set -eo pipefail` at
  the top of the runner already carried through the `tee`, and which does not
  change between releases.

  One assertion on the summary text remains, because there is exactly one thing
  the exit code cannot express: a suite that executed no tests reports success,
  which would let a target whose sources stopped matching any test pass forever.
  It fires only when nothing ran *and* nothing was excluded. A target that
  filters by tag and excludes everything it has is doing what it was asked to,
  and is a normal way to shard a suite, so an exclusion count means the summary
  is honest and the target passes. Both spellings are read while the supported
  window spans Elixir 1.19 and 1.20.

  This is the one behavioural difference from 1.1.0. A suite that defines no
  tests at all, and excludes none, passed before and now fails. That is the case
  `//:empty_test` has always asserted should fail.

### Added

- **`mix_archive_build`** (`mix_archive_build.bzl`,
  `private/mix_archive_build.bzl`): build a `.ez` Mix archive. The rules could
  already compile an Elixir app but could not produce an archive, and
  `mix archive.install` is the only way to give Mix something it needs *before*
  it can resolve a project. Adapted from rabbitmq-server's
  `bazel/elixir/mix_archive_build.bzl` (MPL-2.0), the same lineage as this
  ruleset.

- **`hex` module extension** (`bzlmod/extensions.bzl`): builds Hex itself from
  source as a Mix archive, exported as `@hex//:archive`.

  Every consumer needs this and cannot discover it. Mix aborts with "Could not
  find an SCM for dependency" on any dependency entry in a `mix.exs` unless Hex
  is installed as an archive, including in a build that supplies all
  dependencies from Bazel and passes `--no-deps-check`. Hex has no dependencies
  of its own, so it bootstraps with an empty dependency graph. The version
  defaults to `DEFAULT_HEX_VERSION` and is overridable with the
  `from_github_release` tag, mirroring `internal_elixir_from_github_release`.

### Removed

- **Bazel 7 support**, declared as `bazel_compatibility = [">=8.0.0"]`. This
  follows `rules_erlang` 3.18.0, which requires Bazel 8 and which this release
  requires in turn, so 7 was already unreachable in practice.

### Changed

- **Dependencies moved to current stable.**

  | | from | to |
  | --- | --- | --- |
  | rules_erlang | 3.16.0 | 3.18.0 |
  | bazel_skylib | 1.7.1 | 1.9.2 |
  | platforms | - | 1.1.0 (new) |

  `platforms` is new because `ex_unit_test` selects on `@platforms//os:windows`;
  see the Windows condition entry above for why the dependency belongs here
  rather than in every consumer.

- **`sh_test` loads from `@rules_shell`** (`test/BUILD.bazel`,
  `test/MODULE.bazel`). It stopped being a native rule in Bazel 8, so the test
  module gained both the load statement and a `rules_shell` dependency.

- **`@platforms//host:host` replaces `@local_config_platform//:host`**
  (`examples/internal-elixir`). Bazel 8 removed the autoconfigured
  `local_config_platform` repository. The example's platforms also register
  themselves as execution platforms, which Bazel 9 requires of any target
  platform that has to run tests.

- **The `internal-elixir` example builds OTP 29.0.5 and Elixir 1.20.3**, up from
  OTP 26.2.5 and Elixir 1.16.1. It is the only from-source coverage there is, and
  it was pinned two OTP majors behind the supported window.

- **CI covers the latest two Elixir minors against the latest two OTP majors**,
  currently 1.20 on OTP 29 and 1.19 on OTP 28. Elixir supports a moving window of
  OTP majors, so the matrix tests pairs rather than crossing the two lists. The
  Bazel matrix lives in the registry presubmit, which covers 8.x and 9.x.

- **The registry presubmit installs Elixir**, which it never did. It built
  `@rules_elixir//...` with only Erlang on the machine, leaving the external
  Elixir toolchain nothing to resolve. It also moves from the `platforms:`
  mapping to the `tasks:` schema, and activates the kerl build so the Elixir
  archive finds an ERTS to run on.

  The structure here comes from rabbitmq/rules_elixir#7, merged from upstream's
  final state; the versions are this project's.

- **Fix the registry source template's archive name** (`.bcr/source.template.json`).
  It asked for `rules_elixir-{TAG}.tar.gz`, but the release workflow uploads
  `rules_elixir-{VERSION}.tar.gz`, and this repository tags with a leading `v`.
  The two are only equal when the tag carries no prefix, so the published URL
  would have been `rules_elixir-v1.2.0.tar.gz` and returned a 404.

- **Publishing targets the Bazel Central Registry.** The workflow that pushed to
  `rabbitmq/bazel-central-registry@erlang-packages`, a private registry fork this
  project cannot write to, is replaced by `bazel-contrib/publish-to-bcr`. The
  registry entry for that fork is also dropped from every `.bazelrc`; it served
  `rules_erlang` 3.15.x and nothing reads it now.

### Compatibility

For a bzlmod consumer, 1.2.0 is a drop-in replacement for 1.1.0: no rule, macro,
provider or attribute changed. The `rules_erlang` dependency moves from 3.16.0 to
3.18.0, which is itself a drop-in replacement.

One behaviour differs, described under the ExUnit entry above: an `ex_unit_test`
that runs no tests and excludes none now fails rather than passes. A target that
excludes everything by tag is unaffected.

Requires Bazel 8 or newer. Tested on Bazel 8.7.0 and 9.2.0.

Neither module is on the Bazel Central Registry yet, so a consumer needs an
override for `rules_elixir` **and** one for `rules_erlang`. Overrides only take
effect in the root module, which is why both are needed even though only one is a
direct dependency. See the Installation section of the README.
