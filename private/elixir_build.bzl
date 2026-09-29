"""Build or stage Elixir from declared distribution files."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_erlang//tools:erlang_toolchain.bzl", "erlang_dirs", "maybe_install_erlang")

ElixirInfo = provider(
    doc = "Elixir distribution and its compatible OTP toolchain information.",
    fields = ["release_dir", "elixir_home", "version_file", "otpinfo"],
)

def _distribution_impl(ctx, prebuilt):
    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    ctx.actions.run_shell(
        inputs = depset(
            direct = ctx.files.srcs + [ctx.file.root],
            transitive = [runfiles.files],
        ),
        outputs = [release_dir, version_file],
        command = """set -euo pipefail
{maybe_install_erlang}
export PATH={erlang_home}/bin:"$PATH"
ABS_RELEASE_DIR="$PWD"/{release}
ABS_VERSION_FILE="$PWD"/{version}
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cp -RL {source}/. "$BUILD_DIR/"
chmod -R u+w "$BUILD_DIR"
cd "$BUILD_DIR"
export HOME="$PWD"
export ERL_COMPILER_OPTIONS=deterministic
{build}
test -d bin && test -d lib
chmod +x bin/*
mkdir -p "$ABS_RELEASE_DIR"
cp -R bin lib "$ABS_RELEASE_DIR/"
"$ABS_RELEASE_DIR/bin/iex" --version > "$ABS_VERSION_FILE"
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = shell.quote(erlang_home),
            source = shell.quote(ctx.file.root.dirname),
            release = shell.quote(release_dir.path),
            version = shell.quote(version_file.path),
            build = "" if prebuilt else "make",
        ),
        execution_requirements = {"block-network": "1"},
        mnemonic = "ElixirDistribution",
        progress_message = "Staging prebuilt Elixir" if prebuilt else "Compiling Elixir from source",
    )
    otpinfo = ctx.toolchains["@rules_erlang//tools:toolchain_type"].otpinfo
    return [
        DefaultInfo(files = depset([release_dir, version_file])),
        otpinfo,
        ElixirInfo(
            otpinfo = otpinfo,
            release_dir = release_dir,
            elixir_home = None,
            version_file = version_file,
        ),
    ]

def _source_impl(ctx):
    return _distribution_impl(ctx, prebuilt = False)

def _prebuilt_impl(ctx):
    return _distribution_impl(ctx, prebuilt = True)

_DISTRIBUTION_ATTRS = {
    "srcs": attr.label_list(allow_files = True, mandatory = True),
    "root": attr.label(allow_single_file = True, mandatory = True, doc = "A marker file at the distribution root."),
}

elixir_build = rule(
    implementation = _source_impl,
    attrs = _DISTRIBUTION_ATTRS,
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)

elixir_prebuilt = rule(
    implementation = _prebuilt_impl,
    attrs = _DISTRIBUTION_ATTRS,
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)

def _elixir_external_impl(ctx):
    elixir_home = ctx.attr.elixir_home
    if elixir_home == "":
        elixir_home = ctx.attr._elixir_home[BuildSettingInfo].value

    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    ctx.actions.run_shell(
        inputs = runfiles.files,
        outputs = [version_file],
        command = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

"{elixir_home}"/bin/iex --version > {version_file}
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
            elixir_home = elixir_home,
            version_file = version_file.path,
        ),
        mnemonic = "ELIXIR",
        progress_message = "Validating elixir at {}".format(elixir_home),
    )

    return [
        DefaultInfo(
            files = depset([version_file]),
        ),
        ctx.toolchains["@rules_erlang//tools:toolchain_type"].otpinfo,
        ElixirInfo(
            otpinfo = ctx.toolchains["@rules_erlang//tools:toolchain_type"].otpinfo,
            release_dir = None,
            elixir_home = elixir_home,
            version_file = version_file,
        ),
    ]

elixir_external = rule(
    implementation = _elixir_external_impl,
    attrs = {
        "_elixir_home": attr.label(default = Label("//:elixir_home")),
        "elixir_home": attr.string(),
    },
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)
