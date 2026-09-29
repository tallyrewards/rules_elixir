"""Root compile configuration inherited by independently built dependencies."""

MixConfigInfo = provider(fields = {"entrypoint": "Config entrypoint", "files": "All imported config/data inputs"})

def _impl(ctx):
    files = depset(ctx.files.srcs + [ctx.file.config])
    return [DefaultInfo(files = files), MixConfigInfo(entrypoint = ctx.file.config, files = files)]

mix_config = rule(
    implementation = _impl,
    attrs = {
        "config": attr.label(mandatory = True, allow_single_file = True),
        "srcs": attr.label_list(allow_files = True),
    },
)
