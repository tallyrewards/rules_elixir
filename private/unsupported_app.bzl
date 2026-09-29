"""Fail closed until a build manager has a declared, tested adapter."""

def _impl(ctx):
    fail("%s uses %s; provide a packages.override target with ErlangAppInfo and declared build tools" % (ctx.label.name, ctx.attr.manager))

unsupported_app = rule(implementation = _impl, attrs = {"manager": attr.string()})
