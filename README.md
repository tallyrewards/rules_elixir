# rules_elixir

Bazel rules for building Elixir applications. Compile an app, run its ExUnit
suites, build a Mix archive, and evaluate code with `iex`.

Built on [rules_erlang](https://github.com/bazelverse/rules_erlang), and requires
it. Elixir applications are OTP applications, so the Erlang toolchain, the app
metadata and the `ERL_LIBS` staging all come from there.

## Supported versions

Requires bzlmod and `rules_erlang` 3.18.0 or newer. Bazel 7 is not supported;
the Bazel Central Registry presubmit covers 8.x and 9.x, and `.bazelversion`
pins what GitHub CI runs.

CI covers the **latest two Elixir minors** against the **latest two OTP
majors**. Elixir supports a moving window of OTP majors, so the pairs are tested
as pairs rather than crossed:

| Elixir | Erlang/OTP |
| --- | --- |
| 1.20 | 29 |
| 1.19 | 28 |

Earlier versions may well work, and nothing has been deliberately broken for
them, but they are untested here. Treat them as use-at-your-own-risk.

## Status

This repository continues rabbitmq's `rules_elixir`, which is unmaintained.
`v1.1.0` was its last release.

**For a bzlmod consumer, 1.2.0 is a drop-in replacement for 1.1.0.** No rule,
macro, provider or attribute changed; every commit between the two tags is one
documented fix or addition. See [CHANGELOG.md](./CHANGELOG.md).

## Installation

> **Git pre-release only.** `rules_elixir` and `rules_erlang` are both awaiting
> Bazel Central Registry entries, so `bazel_dep` alone will not resolve and you
> need an override for each. Overrides only take effect in the **root module**,
> which is why you declare both even though only one is a direct dependency.
> Once the registry entries land, delete the overrides and keep the `bazel_dep`
> lines; nothing else changes.

```starlark
bazel_dep(name = "rules_elixir", version = "1.2.0")
bazel_dep(name = "rules_erlang", version = "3.18.0")

git_override(
    module_name = "rules_elixir",
    remote = "https://github.com/bazelverse/rules_elixir.git",
    commit = "0000000000000000000000000000000000000000",  # v1.2.0
)

git_override(
    module_name = "rules_erlang",
    remote = "https://github.com/bazelverse/rules_erlang.git",
    commit = "5531a30ab87ed7e2a63eb1a901c4eeac1bb2bcc6",  # 3.18.0
)
```

`commit` takes a full SHA, not a tag. Pin the commit a release tag points at
rather than the tag itself: a SHA cannot be moved, and it is the same thing the
registry will hand you later. `git rev-list -n1 v1.2.0` prints it.

The `version` in `bazel_dep` is still required. It is what the module reports to
the rest of the graph; the override decides what is actually fetched.

### Then, in the same `MODULE.bazel`

```starlark
elixir_config = use_extension(
    "@rules_elixir//bzlmod:extensions.bzl",
    "elixir_config",
)
use_repo(elixir_config, "elixir_config")

register_toolchains("@elixir_config//external:toolchain")
```

That uses the Elixir already on the machine. To have Bazel fetch and build a
pinned Elixir instead, declare it and register its toolchain:

```starlark
elixir_config.internal_elixir_from_github_release(
    name = "pinned",
    version = "1.20.3",
    sha256 = "ff22a894b130631443db1a193b4e8cb4762f697128566e43da848fd16c3777bd",
)

register_toolchains("@elixir_config//pinned:toolchain")
```

Installation names are global to the module graph; declaring one twice is an
error. Declaring an installation does not replace the host Elixir by itself:
fetched toolchains are only selected on an execution platform with the
`@elixir_config//:elixir_internal` constraint, so add a platform and select it:

```starlark
# BUILD.bazel
platform(
    name = "hermetic",
    constraint_values = ["@elixir_config//:elixir_internal"],
    parents = ["@platforms//host:host"],
)
```

```
# .bazelrc
build --extra_execution_platforms=//:hermetic
```

The `sha256` is of the source archive the extension fetches, which is
`https://github.com/elixir-lang/elixir/archive/refs/tags/v<version>.tar.gz`, not
one of the precompiled release assets.

Building Elixir from source needs an Erlang to build it with, so pair this with
`internal_erlang_from_github_release` from `rules_erlang` and keep the two
versions compatible. `examples/internal-elixir` is a working setup of exactly
that.

Set `RULES_ELIXIR_SKIP_SYSTEM=1` to stop the extension probing the host for an
Elixir install at all. That is what you want when every toolchain is hermetic:

```
build --repo_env=RULES_ELIXIR_SKIP_SYSTEM=1
build --repo_env=RULES_ERLANG_SKIP_SYSTEM=1
```

`@elixir_config//external:toolchain` then refers to the root module's first
declared installation, which still needs the platform above.

## Rules

| Rule | What it does |
| --- | --- |
| `elixir_app` | Compile an Elixir application into an OTP app |
| `elixir_external` | Wrap an Elixir installation outside the build |
| `ex_unit_test` | Run an ExUnit suite as a Bazel test |
| `mix_archive_build` | Build a `.ez` Mix archive |
| `iex_eval` | Evaluate Elixir code with `iex` |
| `elixir_build` | Build Elixir itself from source |
| `elixir_toolchain` | Declare an Elixir toolchain |

### Compiling an application

```starlark
load("@rules_elixir//:elixir_app.bzl", "elixir_app")

elixir_app(
    name = "my_app",
    srcs = glob(["lib/**/*.ex"]),
    app_name = "my_app",
    app_version = "0.1.0",
)
```

Declare anything read at compile time, whether reached through `File.read!/1` or
`@external_resource`. Undeclared files do not exist in the sandbox.

### Running tests

```starlark
load("@rules_elixir//:ex_unit_test.bzl", "ex_unit_test")

ex_unit_test(
    name = "my_app_test",
    srcs = glob(["test/**/*_test.exs"]),
    deps = [":my_app"],
)
```

Test inputs keep their package-relative layout, so a test resolving a path off
`__DIR__` finds what it expects.

## Hex

Mix will not resolve a project at all unless Hex is installed as an archive. Any
dependency entry in a `mix.exs` aborts with *"Could not find an SCM for
dependency"*, even a dev-only one that would never be compiled, and even in a
build that supplies every dependency from Bazel and passes `--no-deps-check`.

The `hex` extension builds Hex from source and exports it as `@hex//:archive`:

```starlark
hex = use_extension("@rules_elixir//bzlmod:extensions.bzl", "hex")
use_repo(hex, "hex")
```

Pin a different version with the `from_github_release` tag:

```starlark
hex.from_github_release(
    version = "2.5.1",
    sha256 = "...",
)
```

Hex has no dependencies of its own, so it bootstraps through
`mix_archive_build` with an empty dependency graph. That is why this can live
here rather than in every consuming module.

Fetching Hex *packages* is a different job from installing Hex the tool. For a
handful of packages see `rules_erlang`'s `erlang_package` extension; for a whole
application closure, its `hex_packages_extension`.

## Examples

See the `examples` directory. 

## License

Dual licensed under the Apache License Version 2.0 and the Mozilla Public
License Version 2.0.

You may consider this library to be licensed under **any of the licenses in that
list**. For example, you may choose the Apache License 2.0 and include this
library in a commercial product.

See [LICENSE](./LICENSE) for details. Copyright, including the notice for the
original upstream work, is covered separately in [COPYRIGHT.md](./COPYRIGHT.md).
