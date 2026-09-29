"""Tests and named releases consume one configured, precompiled project graph."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load(":mix_app.bzl", "MixProjectInfo", "closure", "dependency_description", "dependency_inputs", "invocation", "toolchain")
load(":mix_config.bzl", "test_transition")

def _app(ctx):
    # Attribute transitions produce a list even for a single label.
    return ctx.attr.app[0]

def _config(ctx, operation):
    """Stage the project definition, compiled closure and the consumer's own files."""
    app = _app(ctx)
    project = app[MixProjectInfo]
    config = dict(project.config)
    apps = closure([app])
    sources = list(project.project_sources)
    for f in ctx.files.srcs:
        if f.owner.workspace_name != app.label.workspace_name or not f.short_path.startswith(project.root):
            fail("%s: srcs must be inside the application's project: %s" % (ctx.label, f.short_path))
        sources.append({"source": f.path, "destination": f.short_path[len(project.root):]})
    config.update({"operation": operation, "dependencies": dependency_description(apps), "sources": sources})
    for dep in config["dependencies"]:
        if dep["app"] == config["app"]:
            dep["files"]["consolidated"] = [project.consolidated.path]
    return (config, depset(ctx.files.srcs + dependency_inputs(apps) + [project.consolidated], transitive = [project.project_files]))

def _test_impl(ctx):
    (config, inputs) = _config(ctx, "test")

    # Bazel's standard args are delivered by the launcher, not interpolated in a
    # shell command. Environment is provided via RunEnvironmentInfo.
    config["args"] = ctx.attr.mix_args
    config_file = ctx.actions.declare_file(ctx.label.name + ".mix.json")
    tc = toolchain(ctx)
    files = depset([ctx.file._runner] + ctx.files.data, transitive = [inputs, tc.files])
    encoded = json.encode(config)
    for f in files.to_list():
        encoded = encoded.replace(json.encode(f.path), json.encode(f.short_path))
    ctx.actions.write(config_file, encoded)
    command = invocation(ctx, config_file, tc)
    for f in files.to_list() + [config_file]:
        command = command.replace(shell.quote(f.path), shell.quote(f.short_path))
    if ctx.attr.test_outputs:
        collect = ["collect_outputs() {", "  status=$?", "  set +e"]
        for path in ctx.attr.test_outputs:
            if not path or path.startswith("/") or ".." in path.split("/"):
                fail("test_outputs paths must be project-relative")
            source = "/".join(["project", config["project_dir"], path])
            collect.append("  if [[ -e \"$WORK/\"%s ]]; then mkdir -p \"$TEST_UNDECLARED_OUTPUTS_DIR/\"%s; cp -RL \"$WORK/\"%s \"$TEST_UNDECLARED_OUTPUTS_DIR/\"%s; fi" % (shell.quote(source), shell.quote(path.rpartition("/")[0]), shell.quote(source), shell.quote(path)))
        collect += ["  rm -rf \"$WORK\"", "  exit \"$status\"", "}", "trap collect_outputs EXIT"]
        command = command.replace("trap 'rm -rf \"$WORK\"' EXIT", "\n".join(collect))
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, "#!/usr/bin/env bash\ncd \"${RUNFILES_DIR}/" + ctx.workspace_name + "\"\n" + command, is_executable = True)
    return [
        DefaultInfo(executable = script, runfiles = ctx.runfiles(files = [config_file], transitive_files = files)),
        RunEnvironmentInfo(environment = ctx.attr.env),
    ]

_COMMON = {
    "_runner": attr.label(default = Label("//private:mix_runner.exs"), allow_single_file = True),
    "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
}

elixir_test = rule(
    implementation = _test_impl,
    attrs = dict(
        _COMMON,
        app = attr.label(mandatory = True, providers = [MixProjectInfo], cfg = test_transition),
        srcs = attr.label_list(allow_files = True, doc = "Files staged into the project for the test run: test_helper.exs, tests and fixtures. They are not compiled into the application."),
        mix_args = attr.string_list(),
        env = attr.string_dict(),
        data = attr.label_list(allow_files = True),
        test_outputs = attr.string_list(doc = "Project-relative files/directories retained in Bazel test undeclared outputs, including on failure."),
    ),
    toolchains = ["//:toolchain_type"],
    test = True,
)
