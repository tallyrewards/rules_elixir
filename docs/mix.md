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
fail explicitly. Custom Mix *compilers* are supported when their inputs and
tools are declared. Root and dependency compile aliases run inside their compile
action and are suppressed in precompiled test/release consumers. Represent unsupported native builders with explicit Bazel
targets via overrides rather than allowing action-time dependency fetching.

## Materialize the graph

In addition to the normal Elixir/Erlang toolchain setup:

```starlark
packages = use_extension("@rules_elixir//bzlmod:mix_deps.bzl", "mix_deps")
packages.from_file(
    name = "project_deps",
    manifest = "//:rules_elixir.lock.json",
    compile_config = "//:compile_config",
)
use_repo(packages, "project_deps")
```

Repository evaluation reads JSON and fetches pinned sources; it does not run
Mix. Hex archives are checksum verified; Git sources use full revisions. Git
repositories generate a provenance file for offline drift checks, so those checks
do not need a `.git` directory or run Git inside build actions. Give
independent roots distinct graph names. A graph rejects source identity conflicts,
unresolved edges and cycles. A compiled closure also rejects two providers for
the same OTP application rather than silently choosing one.

Path packages require an explicit target:

```starlark
packages.override(graph = "project_deps", app = "shared", target = "//shared:app")
```

Overrides are checked against resolved package names, and an override target
must provide the application it replaces. They are explicit adapter boundaries;
the override author must preserve the resolved application's behavior. Inactive packages may still be materialized for drift checking;
the generated `mix_dependencies()` selects the actual root graph.

## Compile an application

```starlark
load("@project_deps//:defs.bzl", "mix_dependencies")
load("@rules_elixir//:mix_app.bzl", "mix_app")
load("@rules_elixir//:mix_config.bzl", "mix_config")

mix_config(
    name = "compile_config",
    config = "config/config.exs",
    srcs = glob(["config/**"]),
    visibility = ["//visibility:public"],
)
mix_app(
    name = "app",
    app_name = "my_app",
    mix_exs = "mix.exs",
    srcs = ["mix.lock"] + glob(["lib/**", "config/**", "priv/**"]),
    deps = mix_dependencies(),
)
```

Declare every compile-time resource. Files from the project's repository retain
their common source layout, including parent files such as `../VERSION`.
`generated_srcs = {":generator": "lib/generated"}` stages a single generated
file or TreeArtifact at a project-relative destination. Cross-repository inputs
must use that mapping rather than relying on an accidental common prefix.

`mix_config` evaluates the root configuration for the current environment.
Dependencies compile in their own resolved environment (normally `prod`) against
the part of it they read, as they would under Mix:

1. A dependency first compiles without root configuration, recording every
   application environment key it reads. That includes `Application.compile_env/3`
   and `Application.get_env/3` calls the compiler does not track.
2. The keys it read select their configured values.
3. With no configured keys, the first result is used. Otherwise the dependency
   compiles again with those values.

A configuration edit therefore recompiles only the dependencies that read an
edited key, and whatever is compiled against them. A dependency that reads a
configured key only once configured (a conditional read) fails the build, naming
the key, rather than compiling without its value. As in Mix, Rebar dependencies
compile without root configuration. Local path adapters should set
`compile_config`, `is_dependency = True` and the appropriate `environment`
themselves.

The canonical flag is `--@rules_elixir//:mix_env=dev|test|prod`. Test/release
transitions change only this setting on the application edge. It is target
scoped so execution tools do not inherit application environment changes.
Compilers run offline with dependency compilation/checks disabled. Dependencies
are presented as symlinks to their existing artifacts, not copied for every
application. Each app exports its own `ebin`, `priv`, `include` and consolidated
protocols; release outputs contain bytes rather than temporary symlinks.

## Native tools

Native source-bearing applications use the selected public `rules_cc` C/C++
toolchain and its declared inputs, compile flags and environment. `--copt`,
`--conlyopt`, `--cxxopt` and `--linkopt` are forwarded. The package chooses its
output kind and link operation. `native_deps` accepts `CcInfo` targets: their
headers, public defines and include directories reach the compiler, and their
static libraries and link options are supplied through `LDFLAGS`. The package's
native builder must use `LDFLAGS` after its object/source arguments. For example:

```starlark
mix_app(
    name = "app",
    app_name = "native_app",
    mix_exs = "mix.exs",
    srcs = glob(["lib/**", "src/**"]),
    native_deps = ["//native_support:library"],
)
```

Dynamic and `alwayslink` libraries require explicit linking/packaging adapters;
the rule does not silently drop their runtime requirements. A separate toolchain declares auxiliary
executables such as Make:

```starlark
load("@rules_elixir//:mix_payloads.bzl", "mix_payloads")
mix_payloads(name = "native_tools", tools = {"@make//:make": "make"})
toolchain(
    name = "native_toolchain",
    toolchain = ":native_tools",
    toolchain_type = "@rules_elixir//:mix_payloads_toolchain_type",
)
# MODULE.bazel: register_toolchains("//:native_toolchain")
```

Tool labels may name an executable target (with its Bazel runfiles) or a single
executable file. Executable targets are invoked at their original path so
runfiles lookup continues to work through the native tools directory.

An empty tools mapping is sufficient for a compiler-only package. Use `native = True` for generated native inputs. Native source
detection currently covers C/C++/Objective-C inputs. Other native systems and
precompiled payload selection need explicit adapters. Cross-platform native
compilation is rejected: a compiler may load its NIF while building, so target
and execution artifacts cannot safely be conflated.

After compilation, native files in `priv` are checked against the target CPU and
file format. The checks support 64-bit ELF and Mach-O, including universal Mach-O
files with a matching slice. Unknown shared-library formats fail explicitly.
These header checks do not prove runtime ABI or shared-library compatibility;
test actual NIF loading on each supported platform.

Hermeticity is a property of the selected toolchain, too. The existing external
OTP/Elixir toolchains and auto-configured system C toolchain depend on host
installations. The shell/bootstrap still uses system utilities. This experimental
implementation does **not** establish remote-execution hermeticity merely by
setting `block-network` on compile and release actions. See the
[design notes](architecture.md) before production adoption.

## Test and release consumers

```starlark
load("@rules_elixir//:elixir_test.bzl", "elixir_test")
load("@rules_elixir//:elixir_release.bzl", "elixir_release")

mix_app(
    name = "app",
    # ...
    srcs = ["mix.lock"] + glob(["lib/**", "config/**", "priv/**"]) + select({
        "@rules_elixir//:mix_test": glob(["test/support/**"]),
        "//conditions:default": [],
    }),
)

elixir_test(
    name = "test",
    srcs = glob(["test/**"], exclude = ["test/support/**"]),
    app = ":app",
    shard_count = 4,
    test_outputs = ["tmp/junit-reports"],
)
elixir_release(name = "server", srcs = glob(["rel/**"]), app = ":app", release = "server")
elixir_release(name = "client", srcs = glob(["rel/**"]), app = ":app", release = "client")
```

Only files the compiler reads belong in the application's `srcs`, such as
`test/support` in the test environment. Test scripts, `test_helper.exs` and
fixtures belong to `elixir_test`, so editing a test reruns the test without
recompiling the application. A test stages the project's `mix.exs`, lockfile and
`config/`, its own `srcs`, and the compiled application graph; it does not depend
on the application's other sources.

All test shards consume the same `test` application. Bazel shard indices map to
Mix's one-based partitions before loading project configuration. Without Bazel
sharding, an explicit `MIX_TEST_PARTITION` is preserved; an external CI matrix
can pass it through `--test_env=MIX_TEST_PARTITION` and select the partition count
with `mix_args = ["--partitions", "4"]`. Keep `shard_count` at one in that mode.
`mix_args`, Bazel `--test_arg`, `env` and `data` (runfiles, not staged into the
project) are available for ordinary test configuration. `test_outputs` preserves selected
project-relative paths under Bazel's undeclared test outputs, including failures.
Prepare databases and other services in the consuming project before running
the test. The rules do not execute test aliases that provision application
infrastructure.

Named releases share the `prod` graph and invoke Mix's release task with
`--no-compile --no-deps-check`. Application modes, runtime configuration and
overlays stay in `mix.exs`. Like a test, a release stages the project
definition and the compiled graph; declare `rel/` templates, overlays and other
files the release task reads in its `srcs`.
No database, OCI or deployment policy belongs in the generic release rule.

Bazel normalizes permissions on files in output directories, including adding
execute bits to ordinary data files. Release resource checks should compare bytes
and paths, and verify that required executables remain executable. The final
packaging layer must assign its intended file modes rather than inherit them
from a Bazel output tree. This follows Bazel's
[output metadata handling](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/skyframe/ActionOutputMetadataStore.java).

## CI drift checks

```starlark
load("@project_deps//:sources.bzl", "mix_dependency_sources")
load("@rules_elixir//:mix_lock_test.bzl", "mix_lock_test")

mix_lock_test(
    name = "lock_test",
    manifest = "rules_elixir.lock.json",
    sources = mix_dependency_sources() | {":analysis_sources": ""},
)
```

`analysis_sources` must supply `mix.exs`, `mix.lock`, configuration and extra
analysis inputs. Add path dependency sources at their declared paths. For a
project nested below shared files, set `project_dir` and map source destinations
accordingly. The test recomputes the manifest in an isolated offline workspace.
No checked-in file is rewritten. On failure, the regenerated manifest is retained
in Bazel's undeclared test outputs for comparison.
