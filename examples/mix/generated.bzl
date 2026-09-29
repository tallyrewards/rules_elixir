"""Exercise generated TreeArtifact staging without a language-specific adapter."""

def _impl(ctx):
    tree = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        outputs = [tree],
        arguments = [tree.path],
        command = "mkdir -p \"$1\"; printf 'defmodule Sample.Generated do\\n  def answer, do: 42\\nend\\n' > \"$1/generated.ex\"",
    )
    return [DefaultInfo(files = depset([tree]))]

generated_sources = rule(implementation = _impl)

def _bad_native_impl(ctx):
    artifact = ctx.actions.declare_file(ctx.label.name + ".so")

    # ELF64 header with an unsupported machine, independent of the host CPU.
    ctx.actions.run_shell(
        outputs = [artifact],
        arguments = [artifact.path],
        command = "printf '%b' '" + "\\177ELF\\002\\001\\001" + "\\000" * 57 + "' > \"$1\"",
    )
    return [DefaultInfo(files = depset([artifact]))]

bad_native_library = rule(implementation = _bad_native_impl)
