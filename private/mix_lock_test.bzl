"""Manifest regeneration is a test, never module-extension evaluation."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load(":mix_app.bzl", "invocation", "toolchain")

def _impl(ctx):
    if ctx.attr.project_dir.startswith("/") or ".." in ctx.attr.project_dir.split("/"):
        fail("project_dir must be relative to the staged sources")
    sources = []
    for target, destination in ctx.attr.sources.items():
        for f in target[DefaultInfo].files.to_list():
            path = f.short_path
            if path.startswith("../"):
                path = path.split("/", 2)[2]
            prefix = target.label.package + "/" if target.label.package else ""
            if not path.startswith(prefix):
                fail("sync sources must be under the supplying target's package")
            path = path[len(prefix):]
            sources.append({"source": f.path, "destination": destination + "/" + path if destination else path})
    tc = toolchain(ctx)
    files = depset(ctx.files.sources + ctx.files.archives + [ctx.file._runner, ctx.file._sync, ctx.file.manifest], transitive = [tc.files])
    config = {"operation": "sync", "sources": sources, "project_dir": ctx.attr.project_dir, "environment": "dev", "archives": [f.path for f in ctx.files.archives], "sync": ctx.file._sync.path, "manifest": ctx.file.manifest.path, "inputs": ctx.attr.inputs}
    config_file = ctx.actions.declare_file(ctx.label.name + ".mix.json")
    encoded = json.encode(config)
    for f in files.to_list():
        encoded = encoded.replace(json.encode(f.path), json.encode(f.short_path))
    ctx.actions.write(config_file, encoded)
    command = invocation(ctx, config_file, tc)
    for f in files.to_list() + [config_file]:
        command = command.replace(shell.quote(f.path), shell.quote(f.short_path))
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(executable, "#!/usr/bin/env bash\ncd \"${RUNFILES_DIR}/" + ctx.workspace_name + "\"\n" + command, is_executable = True)
    return [DefaultInfo(executable = executable, runfiles = ctx.runfiles(files = [config_file], transitive_files = files))]

mix_lock_test = rule(
    implementation = _impl,
    attrs = {
        "manifest": attr.label(mandatory = True, allow_single_file = [".json"]),
        "sources": attr.label_keyed_string_dict(mandatory = True, allow_files = True),
        "inputs": attr.string_list(),
        "project_dir": attr.string(),
        "archives": attr.label_list(allow_files = [".ez"], default = [Label("@hex//:archive")]),
        "_runner": attr.label(default = Label("//private:mix_runner.exs"), allow_single_file = True),
        "_sync": attr.label(default = Label("//tools:dependency_sync.exs"), allow_single_file = True),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
