"""One Mix compilation action per OTP application, using precompiled inputs."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load(":elixir_toolchain.bzl", "elixir_dirs", "erlang_dirs", "maybe_install_erlang")
load(":native.bzl", "NATIVE_CONSTRAINTS", "native_configuration", "target_platform")

MixConfigInfo = provider(fields = {
    "entrypoint": "Config entrypoint",
    "files": "All imported config/data inputs",
    "evaluated": "Configuration evaluated for the root environment, one application key per line",
})

MixProjectInfo = provider(fields = {
    "config": "Source and dependency description for assembly/test consumers",
    "project_sources": "Staged files that define the project: mix.exs, the lockfile and config/",
    "project_files": "Depset of those files and the Mix archives",
    "root": "Short-path prefix that project-relative destinations are taken from",
    "environment": "Effective project compilation environment",
    "consolidated": "Consolidated protocols",
})

def closure(deps):
    """Upstream flat_deps silently picks one app on conflict. Never do that."""
    apps = {}
    for dep in deps:
        for candidate in [dep] + dep[ErlangAppInfo].deps:
            name = candidate[ErlangAppInfo].app_name

            # Compare compiled outputs, not targets: an override and the target it
            # forwards are the same application instance.
            if name in apps and apps[name][ErlangAppInfo].beam != candidate[ErlangAppInfo].beam:
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

def _invoke(ctx, config, status = None):
    command = """
WORK=$(mktemp -d "${{TMPDIR:-/tmp}}/rules-elixir.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
"$ELIXIR/bin/elixir" {runner} {config} "$WORK" "$@"
""".format(runner = shell.quote(ctx.file._runner.path), config = shell.quote(config.path))
    if status:
        # A failure recorded in the status file is expected; only a successful
        # compilation's diagnostics are worth showing.
        command = command.replace('"$@"\n', '"$@" > "$WORK.log" 2>&1 || {{ cat "$WORK.log"; exit 1; }}\n'.format())
        command += """if [[ "$(cat {status})" == ok ]]; then cat "$WORK.log"; fi
rm -f "$WORK.log"
""".format(status = shell.quote(status.path))
    return command

def invocation(ctx, config, tc):
    return _environment(tc) + _invoke(ctx, config)

def _config_impl(ctx):
    files = depset(ctx.files.srcs + [ctx.file.config])
    environment = ctx.attr._mix_env[BuildSettingInfo].value
    evaluated = ctx.actions.declare_file(ctx.label.name + ".config")
    config_file = ctx.actions.declare_file(ctx.label.name + ".config.json")
    ctx.actions.write(config_file, json.encode({
        "operation": "config",
        "environment": environment,
        "entrypoint": ctx.file.config.path,
        "output": evaluated.path,
        "sources": [],
        "archives": [],
    }))
    tc = toolchain(ctx)
    ctx.actions.run_shell(
        inputs = depset([config_file, ctx.file._runner], transitive = [files, tc.files]),
        outputs = [evaluated],
        command = invocation(ctx, config_file, tc),
        mnemonic = "MixConfig",
        progress_message = "Evaluating %%{label} (%s)" % environment,
        execution_requirements = {"block-network": "1"},
    )
    return [DefaultInfo(files = files), MixConfigInfo(entrypoint = ctx.file.config, files = files, evaluated = evaluated)]

mix_config = rule(
    implementation = _config_impl,
    doc = "Root configuration read by dependencies while they compile.",
    attrs = {
        "config": attr.label(mandatory = True, allow_single_file = True),
        "srcs": attr.label_list(allow_files = True),
        "_mix_env": attr.label(default = Label("//:mix_env")),
        "_runner": attr.label(default = Label("//private:mix_runner.exs"), allow_single_file = True),
    },
    toolchains = ["//:toolchain_type"],
)

def _declare_app(ctx, prefix):
    return {kind: ctx.actions.declare_directory("%s/%s/%s" % (prefix, ctx.attr.app_name, kind)) for kind in ["ebin", "priv", "include", "consolidated"]}

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
    outputs = _declare_app(ctx, ctx.label.name)
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
        "native_validator": ctx.file._native_validator.path,
        "beam_metadata": ctx.file._beam_metadata.path,
        "target_platform": target_platform(ctx),
    }
    if manager == "rebar3":
        config["rebar3"] = ctx.file._rebar3.path
    (native, native_inputs, native_tools) = native_configuration(ctx)
    config["native"] = native
    if ctx.attr.compile_config and (manager != "mix" or not ctx.attr.is_dependency):
        fail("compile_config applies to Mix dependencies; a root application loads its own configuration, and Rebar applications compile without it")
    inputs = depset(ctx.files.srcs + ctx.files.generated_srcs + [ctx.file.project_file, ctx.file._native_validator, ctx.file._beam_metadata] + ctx.files.archives + dependency_inputs(apps) + ([ctx.file._rebar3] if manager == "rebar3" else []), transitive = [native_inputs])
    tc = toolchain(ctx)
    validations = []
    if ctx.attr.compile_config:
        (config, validations) = _configured_compile(ctx, config, inputs, outputs, tc, environment, native_tools)
    else:
        _run(ctx, config, inputs, outputs.values(), tc, "MixCompile" if manager == "mix" else "RebarCompile", "%s compiling %s (%s)" % (manager, ctx.attr.app_name, environment), tools = native_tools)
    providers = [
        DefaultInfo(files = depset(outputs.values())),
        OutputGroupInfo(_validation = depset(validations)),
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
        # Consumers run Mix with compilation disabled. They evaluate the project
        # and load its configuration, but read compiled code from the outputs,
        # so they depend on these files rather than on the compiler's inputs.
        prefix = project_dir + "/" if project_dir else ""
        project_sources = [
            source
            for source in sources
            if source["source"] == ctx.file.project_file.path or
               source["destination"] == prefix + "mix.lock" or
               source["destination"].startswith(prefix + "config/")
        ]
        selected = {source["source"]: True for source in project_sources}
        providers.append(MixProjectInfo(
            config = config,
            project_sources = project_sources,
            # Hex must be installed for Mix to evaluate a project with Hex dependencies.
            project_files = depset([f for f in files if f.path in selected] + ctx.files.archives),
            root = root,
            environment = environment,
            consolidated = outputs["consolidated"],
        ))
    return providers

def _run(ctx, config, inputs, outputs, tc, mnemonic, progress_message, prelude = "", status = None, tools = []):
    config_file = ctx.actions.declare_file("%s.%s.mix.json" % (ctx.label.name, mnemonic.lower()))
    ctx.actions.write(config_file, json.encode(config))
    ctx.actions.run_shell(
        inputs = depset([config_file, ctx.file._runner], transitive = [inputs, tc.files]),
        tools = tools,
        outputs = outputs,
        command = _environment(tc) + prelude + _invoke(ctx, config_file, status),
        mnemonic = mnemonic,
        progress_message = progress_message,
        execution_requirements = {"block-network": "1"},
    )

def _configured_compile(ctx, config, inputs, outputs, tc, environment, tools):
    """Compile a dependency against only the root configuration it reads.

    The first compilation sees no root configuration and records every
    application environment key it reads. Those keys select the configured
    values, and only a non-empty selection compiles again. A configuration
    edit therefore reaches just the dependencies that read the edited keys.
    """
    app = ctx.attr.app_name
    evaluated = ctx.attr.compile_config[MixConfigInfo].evaluated
    unconfigured = _declare_app(ctx, ctx.label.name + "/unconfigured")
    first_reads = ctx.actions.declare_file("%s/unconfigured/%s.reads" % (ctx.label.name, app))
    status = ctx.actions.declare_file("%s/unconfigured/%s.status" % (ctx.label.name, app))
    _run(
        ctx,
        dict(config, outputs = {k: v.path for k, v in unconfigured.items()}, reads = first_reads.path, status = status.path),
        inputs,
        unconfigured.values() + [first_reads, status],
        tc,
        "MixCompile",
        "Mix compiling %s (%s)" % (app, environment),
        status = status,
        tools = tools,
    )

    projection = ctx.actions.declare_file("%s/%s.config" % (ctx.label.name, app))
    ctx.actions.run_shell(
        inputs = [first_reads, evaluated],
        outputs = [projection],
        command = """awk -F '\\t' 'FILENAME == ARGV[1] {{ read[$1 FS $2] = 1; next }} (($1 FS $2) in read) || (($1 FS) in read)' {reads} {config} > {out}""".format(
            reads = shell.quote(first_reads.path),
            config = shell.quote(evaluated.path),
            out = shell.quote(projection.path),
        ),
        mnemonic = "MixConfigSelect",
        progress_message = "Selecting configuration read by %s" % app,
    )

    reads = ctx.actions.declare_file("%s/%s.reads" % (ctx.label.name, app))
    copy = ["if [[ ! -s {} && \"$(cat {})\" == ok ]]; then".format(shell.quote(projection.path), shell.quote(status.path))]
    for kind in outputs:
        copy.append("  mkdir -p {out} && cp -R {src}/. {out}/".format(src = shell.quote(unconfigured[kind].path), out = shell.quote(outputs[kind].path)))
    copy += ["  cp {} {}".format(shell.quote(first_reads.path), shell.quote(reads.path)), "  exit 0", "fi", ""]
    configured = dict(config, outputs = {k: v.path for k, v in outputs.items()}, reads = reads.path, projection = projection.path)
    _run(
        ctx,
        configured,
        depset([projection, status, first_reads] + unconfigured.values(), transitive = [inputs]),
        outputs.values() + [reads],
        tc,
        "MixConfigure",
        "Mix configuring %s (%s)" % (app, environment),
        prelude = "\n".join(copy),
        tools = tools,
    )

    # Compiling with configured values can take branches the unconfigured
    # compilation did not. Reject a configured key read only on such a branch
    # rather than compiling without its value.
    validation = ctx.actions.declare_file("%s/%s.config_checked" % (ctx.label.name, app))
    ctx.actions.run_shell(
        inputs = [projection, evaluated, reads],
        outputs = [validation],
        command = """awk -F '\\t' -v app={app} '
FILENAME == ARGV[1] {{ projected[$1 FS $2] = 1; next }}
FILENAME == ARGV[2] {{ configured[$1 FS $2] = $1; next }}
$2 == "" {{ whole[$1] = 1; next }}
(($1 FS $2) in configured) && !(($1 FS $2) in projected) {{ missing[$1 FS $2] = 1 }}
END {{
  for (key in configured) if ((configured[key] in whole) && !(key in projected)) missing[key] = 1
  for (key in missing) {{
    split(key, part, FS)
    printf "%s read configured %s %s only when compiled with its configuration; that value was not supplied\\n", app, part[1], part[2] > "/dev/stderr"
    failed = 1
  }}
  exit failed
}}' {projection} {config} {reads} && touch {out}""".format(
            app = shell.quote(app),
            projection = shell.quote(projection.path),
            config = shell.quote(evaluated.path),
            reads = shell.quote(reads.path),
            out = shell.quote(validation.path),
        ),
        mnemonic = "MixConfigCheck",
        progress_message = "Checking configuration read by %s" % app,
    )
    return (configured, [validation])

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
    "native": attr.bool(doc = "Require native tools for generated native sources that cannot be detected during analysis."),
    "native_deps": attr.label_list(providers = [CcInfo], doc = "Declared C/C++ headers and static libraries used by the native compiler."),
    "deps": attr.label_list(providers = [ErlangAppInfo]),
    "archives": attr.label_list(allow_files = [".ez"], default = [Label("@hex//:archive")]),
    "environment": attr.string(values = ["", "dev", "test", "prod"]),
    "_mix_env": attr.label(default = Label("//:mix_env")),
    "_runner": attr.label(default = Label("//private:mix_runner.exs"), allow_single_file = True),
    "_native_validator": attr.label(default = Label("//private:native_artifacts.ex"), allow_single_file = True),
    "_beam_metadata": attr.label(default = Label("//private:beam_metadata.ex"), allow_single_file = True),
    "_native_constraints": attr.label_list(default = NATIVE_CONSTRAINTS),
    "_native_exec_platform": attr.label(default = Label("//:native_exec_platform"), cfg = "exec"),
}

mix_app = rule(
    implementation = _impl,
    fragments = ["cpp"],
    attrs = _ATTRS,
    toolchains = ["//:toolchain_type", config_common.toolchain_type("//:mix_payloads_toolchain_type", mandatory = False)] + use_cc_toolchain(),
    provides = [ErlangAppInfo, MixProjectInfo],
)

rebar_app = rule(
    implementation = _rebar_impl,
    fragments = ["cpp"],
    attrs = dict(_ATTRS, _rebar3 = attr.label(default = Label("@rebar3//file"), allow_single_file = True, cfg = "exec")),
    toolchains = ["//:toolchain_type", config_common.toolchain_type("//:mix_payloads_toolchain_type", mandatory = False)] + use_cc_toolchain(),
    provides = [ErlangAppInfo],
)
