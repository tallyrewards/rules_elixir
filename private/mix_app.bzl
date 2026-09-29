"""One Mix compilation action per OTP application, using precompiled inputs."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:mix_config.bzl", "MixConfigInfo")
load(":elixir_toolchain.bzl", "elixir_dirs", "erlang_dirs", "maybe_install_erlang")

MixProjectInfo = provider(fields = {
    "config": "Source and dependency description for assembly/test consumers",
    "inputs": "Declared project and compiled closure inputs",
    "environment": "Effective project compilation environment",
    "consolidated": "Consolidated protocols",
})

def closure(deps):
    """Upstream flat_deps silently picks one app on conflict. Never do that."""
    apps = {}
    for dep in deps:
        for candidate in [dep] + dep[ErlangAppInfo].deps:
            name = candidate[ErlangAppInfo].app_name
            if name in apps and apps[name] != candidate:
                fail("incompatible instances of OTP application %s: %s and %s" % (name, apps[name].label, candidate.label))
            apps[name] = candidate
    return [apps[k] for k in sorted(apps)]

def dependency_description(apps):
    return [{
        "app": dep[ErlangAppInfo].app_name,
        "files": {
            "ebin": [f.path for f in dep[ErlangAppInfo].beam],
            "priv": [f.path for f in dep[ErlangAppInfo].priv],
            "include": [f.path for f in dep[ErlangAppInfo].include],
        },
    } for dep in apps]

def dependency_inputs(apps):
    return [f for dep in apps for f in dep[ErlangAppInfo].beam + dep[ErlangAppInfo].priv + dep[ErlangAppInfo].include]

def toolchain(ctx):
    (elixir_home, elixir_files) = elixir_dirs(ctx)
    (erlang_home, _, erlang_files) = erlang_dirs(ctx)
    return struct(
        elixir = elixir_home,
        erlang = erlang_home,
        files = depset(transitive = [elixir_files.files, erlang_files.files]),
        setup = maybe_install_erlang(ctx),
    )

def _environment(tc):
    return """set -euo pipefail
{setup}
EXECROOT="$PWD"
ELIXIR={elixir}
ERLANG={erlang}
[[ "$ELIXIR" = /* ]] || ELIXIR="$EXECROOT/$ELIXIR"
[[ "$ERLANG" = /* ]] || ERLANG="$EXECROOT/$ERLANG"
export PATH="$ELIXIR/bin:$ERLANG/bin:/usr/bin:/bin"
# C is available even in minimal images; select UTF-8 filenames in the VM.
export LANG=C LC_ALL=C
export ERL_FLAGS="${{ERL_FLAGS:-}} +fnu"
export ERL_COMPILER_OPTIONS=deterministic
""".format(setup = tc.setup, elixir = shell.quote(tc.elixir), erlang = shell.quote(tc.erlang))

def invocation(ctx, config, tc):
    return _environment(tc) + """
WORK=$(mktemp -d "${{TMPDIR:-/tmp}}/rules-elixir.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
"$ELIXIR/bin/elixir" {runner} {config} "$WORK" "$@"
""".format(runner = shell.quote(ctx.file._runner.path), config = shell.quote(config.path))

def _compile(ctx, manager):
    environment = ctx.attr.environment or ctx.attr._mix_env[BuildSettingInfo].value
    apps = closure(ctx.attr.deps)
    if ctx.attr.app_name in [d[ErlangAppInfo].app_name for d in apps]:
        fail("application cannot depend on another instance of itself: " + ctx.attr.app_name)
    files = depset(ctx.files.srcs + [ctx.file.project_file]).to_list()
    parts = ctx.file.project_file.short_path.split("/")[:-1]
    for f in files:
        if f.owner.workspace_name != ctx.file.project_file.owner.workspace_name:
            fail("srcs must belong to the project repository; use generated_srcs to map other inputs")
        directories = f.short_path.split("/")[:-1]
        common = 0
        for i in range(min(len(parts), len(directories))):
            if parts[i] != directories[i]:
                break
            common += 1
        parts = parts[:common]
    root = "/".join(parts)
    root = root + "/" if root else ""
    project_dir = ctx.file.project_file.short_path[len(root):].rpartition("/")[0]
    sources = []
    for f in files:
        sources.append({"source": f.path, "destination": f.short_path[len(root):]})
    for target, destination in ctx.attr.generated_srcs.items():
        if destination.startswith("/") or ".." in destination.split("/"):
            fail("generated source destination must be project-relative: " + destination)
        generated = target[DefaultInfo].files.to_list()
        if len(generated) != 1:
            fail("generated_srcs entries must produce one file or TreeArtifact")
        sources.append({"source": generated[0].path, "destination": project_dir + "/" + destination if project_dir else destination})
    outputs = {kind: ctx.actions.declare_directory("%s/%s/%s" % (ctx.label.name, ctx.attr.app_name, kind)) for kind in ["ebin", "priv", "include", "consolidated"]}
    config = {
        "operation": "compile" if manager == "mix" else manager,
        "app": ctx.attr.app_name,
        "environment": environment,
        "root_environment": ctx.attr._mix_env[BuildSettingInfo].value,
        "sources": sources,
        "project_dir": project_dir,
        "is_dependency": ctx.attr.is_dependency,
        "archives": [f.path for f in ctx.files.archives],
        "dependencies": dependency_description(apps),
        "outputs": {k: v.path for k, v in outputs.items()},
    }
    if manager == "rebar3":
        config["rebar3"] = ctx.file._rebar3.path
    config_inputs = depset()
    if ctx.attr.compile_config:
        compile_config = ctx.attr.compile_config[MixConfigInfo]
        config_inputs = compile_config.files
        config["compile_config"] = compile_config.entrypoint.path
        config["config_environment"] = ctx.attr._mix_env[BuildSettingInfo].value
    config_file = ctx.actions.declare_file(ctx.label.name + ".mix.json")
    ctx.actions.write(config_file, json.encode(config))
    inputs = depset(ctx.files.srcs + ctx.files.generated_srcs + [ctx.file.project_file] + ctx.files.archives + dependency_inputs(apps) + ([ctx.file._rebar3] if manager == "rebar3" else []), transitive = [config_inputs])
    tc = toolchain(ctx)
    ctx.actions.run_shell(
        inputs = depset([config_file, ctx.file._runner], transitive = [inputs, tc.files]),
        outputs = outputs.values(),
        command = invocation(ctx, config_file, tc),
        mnemonic = "MixCompile" if manager == "mix" else "RebarCompile",
        progress_message = "%s compiling %s (%s)" % (manager, ctx.attr.app_name, environment),
        execution_requirements = {"block-network": "1"},
    )
    providers = [
        DefaultInfo(files = depset(outputs.values())),
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            extra_apps = [],
            beam = [outputs["ebin"]],
            priv = [outputs["priv"]],
            include = [outputs["include"]],
            srcs = ctx.files.srcs,
            license_files = [],
            deps = apps,
        ),
    ]

    if manager == "mix":
        providers.append(MixProjectInfo(config = config, inputs = inputs, environment = environment, consolidated = outputs["consolidated"]))
    return providers

def _impl(ctx):
    return _compile(ctx, "mix")

def _rebar_impl(ctx):
    return _compile(ctx, "rebar3")

_ATTRS = {
    "app_name": attr.string(mandatory = True),
    "project_file": attr.label(mandatory = True, allow_single_file = True),
    "srcs": attr.label_list(allow_files = True),
    "generated_srcs": attr.label_keyed_string_dict(allow_files = True),
    "compile_config": attr.label(providers = [MixConfigInfo]),
    "is_dependency": attr.bool(default = False),
    "deps": attr.label_list(providers = [ErlangAppInfo]),
    "archives": attr.label_list(allow_files = [".ez"], default = [Label("@hex//:archive")]),
    "environment": attr.string(values = ["", "dev", "test", "prod"]),
    "_mix_env": attr.label(default = Label("//:mix_env")),
    "_runner": attr.label(default = Label("//private:mix_runner.exs"), allow_single_file = True),
}

mix_app = rule(
    implementation = _impl,
    attrs = _ATTRS,
    toolchains = ["//:toolchain_type"],
    provides = [ErlangAppInfo, MixProjectInfo],
)

rebar_app = rule(
    implementation = _rebar_impl,
    attrs = dict(_ATTRS, _rebar3 = attr.label(default = Label("@rebar3//file"), allow_single_file = True, cfg = "exec")),
    toolchains = ["//:toolchain_type"],
    provides = [ErlangAppInfo],
)
