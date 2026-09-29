"""An override is an adapter boundary: it must provide the application it replaces."""

load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load(":mix_app.bzl", "MixProjectInfo")

def _impl(ctx):
    provided = ctx.attr.actual[ErlangAppInfo].app_name
    if provided != ctx.attr.app_name:
        fail("override %s for application %s provides application %s" % (ctx.attr.actual.label, ctx.attr.app_name, provided))
    providers = [ctx.attr.actual[DefaultInfo], ctx.attr.actual[ErlangAppInfo]]
    if MixProjectInfo in ctx.attr.actual:
        providers.append(ctx.attr.actual[MixProjectInfo])
    return providers

override_app = rule(
    implementation = _impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "actual": attr.label(mandatory = True, providers = [ErlangAppInfo]),
    },
    provides = [ErlangAppInfo],
)
