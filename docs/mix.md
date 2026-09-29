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

Overrides are checked against resolved package names. They are explicit adapter
boundaries; the override author must preserve the resolved application identity
and behavior. Inactive packages may still be materialized for drift checking;
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

`mix_config` is necessary when dependencies read root application configuration,
including `Application.compile_env/3`. Generated dependencies load it using the
root environment, then compile using their own resolved environment (normally
`prod`). Configuration files participate in those actions' cache keys. Local
path adapters should set `compile_config`, `is_dependency = True` and the
appropriate `environment` themselves.

The canonical flag is `--@rules_elixir//:mix_env=dev|test|prod`. Test/release
transitions change only this setting on the application edge. It is target
scoped so execution tools do not inherit application environment changes.
Compilers run offline with dependency compilation/checks disabled. Dependencies
are presented as symlinks to their existing artifacts, not copied for every
application. Each app exports its own `ebin`, `priv`, `include` and consolidated
protocols; release outputs contain bytes rather than temporary symlinks.

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
