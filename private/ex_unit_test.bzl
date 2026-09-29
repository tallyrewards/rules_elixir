load("@bazel_skylib//lib:shell.bzl", "shell")
load(
    "@rules_erlang//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)
load(
    "@rules_erlang//:util.bzl",
    "path_join",
)
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)
load(
    "//private:erl_libs.bzl",
    "erl_libs_contents",
)

def _package_relative_path(ctx, p):
    if ctx.label.package == "":
        return p
    return p.removeprefix(ctx.label.package + "/")

def _impl(ctx):
    # Stage writable inputs in scratch space; only test-produced files belong
    # in TEST_UNDECLARED_OUTPUTS_DIR.
    copy_srcs_and_data_commands = [
        'mkdir -p $(dirname "{dst}") && cp "{src}" "{dst}"'.format(
            src = s.path,
            dst = path_join("${TEST_TMPDIR}", s.path),
        )
        for s in ctx.files.srcs + ctx.files.data
    ]

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        headers = True,
        deps = flat_deps(ctx.attr.deps),
        ez_deps = ctx.files.ez_deps,
        dir = erl_libs_dir,
        expand_ezs = True,
    )

    package = ctx.label.package

    erl_libs_path = path_join(package, erl_libs_dir)

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = True)

    if not ctx.attr.is_windows:
        env = "\n".join([
            "export {}={}".format(k, v)
            for k, v in ctx.attr.env.items()
        ])
        output = ctx.actions.declare_file(ctx.label.name)
        script = """\
#!/usr/bin/env bash
set -eo pipefail

{maybe_install_erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

{copy_srcs_and_data_commands}

export ERL_LIBS="$TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path}"

cd "${{TEST_TMPDIR}}/{package}"

export HOME=${{PWD}}

{env}

{setup}
set -x
${{ABS_ELIXIR_HOME}}/bin/elixir \\
    {elixir_opts} \\
    {srcs_args} \\
    | tee test.log
set +x
# A failing suite makes elixir exit non-zero, and the `set -eo pipefail` above
# carries that through the tee, so the failure path needs no assertion of its
# own. The one thing an exit code cannot express is a suite that executed no
# tests at all: ExUnit reports that as success, which lets a target whose
# sources silently stopped matching any test pass forever. Assert against it.
#
# Running nothing is only a defect when nothing was *meant* to run. A target
# that filters by tag and excludes everything it has is doing what it was asked
# to, and is a normal way to shard a suite, so an exclusion count means the
# summary is honest and the target passes.
#
#   Elixir 1.20   "Result: 0 tests"                vs "Result: 0 tests, 2 excluded"
#   earlier       "0 tests, 0 failures"            vs "0 tests, 0 failures (11 excluded)"
#
# Reading the summary text is only acceptable for this one condition; everything
# else defers to the exit code, which does not change between releases.
summary="$(tail -n 4 test.log)"
if printf '%s\n' "$summary" | grep -Eq "Result: 0 tests|(^|[^0-9])0 tests," &&
   ! printf '%s\n' "$summary" | grep -q "excluded"; then
    echo "ex_unit_test: the suite executed no tests, and excluded none" >&2
    exit 1
fi
rm test.log
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            elixir_home = elixir_home,
            copy_srcs_and_data_commands = "\n".join(copy_srcs_and_data_commands),
            erl_libs_path = erl_libs_path,
            package = package,
            env = env,
            setup = ctx.attr.setup,
            elixir_opts = " ".join([shell.quote(opt) for opt in ctx.attr.elixir_opts]),
            srcs_args = " \\\n    ".join([
                "-r {}".format(_package_relative_path(ctx, s.path))
                for s in ctx.files.srcs
            ]),
        )
    else:
        fail("not implemented")
        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """
"""

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = erlang_runfiles.merge(elixir_runfiles)
    runfiles = runfiles.merge_all(
        [
            ctx.runfiles(ctx.files.srcs + ctx.files.data + erl_libs_files),
        ] + [
            tool[DefaultInfo].default_runfiles
            for tool in ctx.attr.tools
        ],
    )

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

ex_unit_test = rule(
    implementation = _impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".exs"],
        ),
        "is_windows": attr.bool(mandatory = True),
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "tools": attr.label_list(cfg = "target"),
        "env": attr.string_dict(),
        "setup": attr.string(),
        "elixir_opts": attr.string_list(),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
