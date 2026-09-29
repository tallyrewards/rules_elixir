"""Declared native build tools and payloads, independent of package names."""

def _impl(ctx):
    executables = {}
    inputs = []
    files_to_run = []
    for target, name in ctx.attr.tools.items():
        files = target[DefaultInfo].files.to_list()
        executable = target[DefaultInfo].files_to_run
        if not executable.executable and len(files) != 1:
            fail("native build tool must provide an executable or one file")
        if "/" in name or name in ["", ".", "..", "cc", "cxx"]:
            fail("native build tool name must be a basename")
        if name in executables:
            fail("duplicate native build tool name: " + name)
        executables[name] = executable.executable or files[0]
        if executable.executable:
            files_to_run.append(executable)
        inputs.append(target[DefaultInfo].default_runfiles.files)
    return [platform_common.ToolchainInfo(
        executables = executables,
        files_to_run = files_to_run,
        inputs = depset(executables.values(), transitive = inputs),
    )]

mix_payloads = rule(
    implementation = _impl,
    attrs = {"tools": attr.label_keyed_string_dict(cfg = "exec", allow_files = True)},
)
