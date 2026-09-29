"""ERL_LIBS views for the legacy rules, using the public OTP application provider."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load("@rules_erlang//:util.bzl", "path_join")

def additional_file_dest_relative_path(dep_label, source):
    root = dep_label.workspace_root.replace("external/", "../")
    base = path_join(root, dep_label.package)
    return source.short_path.removeprefix(base + "/") if base else source.short_path

def _link(ctx, source, destination):
    output = ctx.actions.declare_directory(destination) if source.is_directory else ctx.actions.declare_file(destination)
    ctx.actions.symlink(output = output, target_file = source)
    return output

def erl_libs_contents(ctx, deps, dir, headers = False, ez_deps = [], expand_ezs = False):
    files = []
    for dep in deps:
        app = dep[ErlangAppInfo]
        destination = path_join(dir, app.app_name)
        for beam in app.beam:
            if beam.is_directory and len(app.beam) != 1:
                fail("ErlangAppInfo.beam must contain files or one ebin directory: " + app.app_name)
            path = "ebin" if beam.is_directory else path_join("ebin", beam.basename)
            files.append(_link(ctx, beam, path_join(destination, path)))
        for field in ["priv", "include"] if headers else ["priv"]:
            for source in getattr(app, field):
                path = field if source.is_directory else additional_file_dest_relative_path(dep.label, source)
                files.append(_link(ctx, source, path_join(destination, path)))
    for archive in ez_deps:
        if expand_ezs:
            # OTP archives contain an application directory, usually app-version/.
            # Preserve that directory name so Erlang can discover its ebin/.
            output = ctx.actions.declare_directory(path_join(dir, archive.basename.removesuffix(".ez")))
            ctx.actions.run_shell(
                inputs = [archive],
                outputs = [output],
                command = "unzip -q {} -d {}".format(shell.quote(archive.path), shell.quote(output.dirname)),
                mnemonic = "ElixirExpandArchive",
            )
            files.append(output)
        else:
            files.append(_link(ctx, archive, path_join(dir, archive.basename)))
    return files
