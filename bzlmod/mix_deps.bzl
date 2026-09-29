"""Materialize a checked-in semantic graph. No Mix execution at repository time."""

load("@bazel_tools//tools/build_defs/repo:git.bzl", "new_git_repository")
load("@rules_erlang//:hex_archive.bzl", "hex_archive")

_ENVS = ["dev", "test", "prod"]
_SOURCE_BUILD = """package(default_visibility = ["//visibility:public"])
exports_files(["mix.exs", "BUILD.bazel"], visibility = ["//visibility:public"])
filegroup(name = "sources", srcs = glob(["**"], exclude = ["BUILD", "BUILD.bazel", "**/BUILD", "**/BUILD.bazel", "**/_build/**", "**/deps/**"], allow_empty = False))
"""

def _name(value):
    if not value or value[0] not in "abcdefghijklmnopqrstuvwxyz" or any([c not in "abcdefghijklmnopqrstuvwxyz0123456789_" for c in value.elems()]):
        fail("invalid application/repository name: " + value)

def _digest(value, size):
    if type(value) != "string" or len(value) != size or any([c not in "0123456789abcdef" for c in value.elems()]):
        fail("expected an immutable lowercase hex digest of length %s, got %r" % (size, value))

def validate_manifest(manifest):
    """Fail before creating any repositories when a graph cannot be represented."""
    if manifest.get("schema_version") != 1:
        fail("unsupported rules_elixir manifest schema_version")
    if sorted(manifest.get("environments", {})) != sorted(_ENVS):
        fail("manifest must describe dev, test and prod")
    packages = {}
    root_app = None
    for env, graph in manifest["environments"].items():
        root = graph["root"]["app"]
        _name(root)
        if root_app and root_app != root:
            fail("root application identity changes across environments")
        root_app = root
        for app, package in graph["packages"].items():
            _name(app)
            source = package["source"]
            if app == root:
                fail("root application also appears as a dependency: " + app)
            if app in packages and packages[app]["manager"] != package["manager"]:
                fail("dependency build manager changes across environments: " + app)
            if app in packages and packages[app]["source"] != source:
                fail("conflicting immutable source identities for %s; analyse independent roots separately" % app)
            if source["type"] == "hex":
                _digest(source["sha256"], 64)
                _name(source["package"])
                if source["repository"] != "hexpm":
                    fail("custom Hex repositories require an explicit source adapter")
            elif source["type"] == "git":
                _digest(source["revision"], 40)
                if source.get("sparse"):
                    fail("sparse Git packages require an explicit source adapter")
            elif source["type"] != "path":
                fail("unsupported source type " + source["type"])
            if package["environment"] not in _ENVS:
                fail("unsupported dependency environment for " + app)
            packages[app] = package
        for node in [graph["root"]] + graph["packages"].values():
            seen = {}
            for edge in node["dependencies"]:
                if edge["app"] not in graph["packages"]:
                    fail("%s has an unresolved edge to %s" % (env, edge["app"]))
                if edge["app"] in seen:
                    fail("duplicate dependency edge to " + edge["app"])
                if edge["environment"] != graph["packages"][edge["app"]]["environment"]:
                    fail("dependency edge environment differs from resolved application: " + edge["app"])
                seen[edge["app"]] = True
                for field in ["compile", "runtime", "optional", "override"]:
                    if type(edge[field]) != "bool":
                        fail("dependency %s must be boolean" % field)

        # Bounded topological elimination; Starlark deliberately has no while.
        pending = dict(graph["packages"])
        for _ in range(len(pending)):
            ready = [app for app, package in pending.items() if not any([e["app"] in pending for e in package["dependencies"] if e["compile"]])]
            for app in ready:
                pending.pop(app)
        if pending:
            fail("dependency cycle in %s: %s" % (env, sorted(pending)))
    return packages

def _select(values):
    return "select(%s)" % repr({"@rules_elixir//:mix_" + env: values[env] for env in _ENVS})

def _graph_impl(ctx):
    manifest = json.decode(ctx.attr.manifest)
    packages = validate_manifest(manifest)
    build = [
        'load("@rules_elixir//:mix_app.bzl", "mix_app")',
        'load("@rules_elixir//private:mix_app.bzl", "rebar_app")',
        'load("@rules_elixir//private:unsupported_app.bzl", "unsupported_app")',
        'package(default_visibility = ["//visibility:public"])',
    ]
    for app in sorted(packages):
        if app in ctx.attr.overrides:
            build.append("alias(name = %r, actual = %r)" % (app, ctx.attr.overrides[app]))
            continue
        package = packages[app]
        if package["source"]["type"] == "path":
            fail("path dependency %s requires a packages.override tag naming its Bazel target" % app)
        if package["manager"] not in ["mix", "rebar3"]:
            build.append("unsupported_app(name = %r, manager = %r)" % (app, package["manager"]))
            continue
        deps = {}
        environments = {}
        for env in _ENVS:
            configured = manifest["environments"][env]["packages"].get(app, package)
            deps[env] = [":" + edge["app"] for edge in configured["dependencies"] if edge["compile"]]
            environments[env] = configured["environment"]
        source = "@%s_%s//:" % (ctx.attr.prefix, app)
        rule_name = "mix_app" if package["manager"] == "mix" else "rebar_app"
        project_attr = "mix_exs" if package["manager"] == "mix" else "project_file"
        marker = "mix.exs" if package["manager"] == "mix" else "BUILD.bazel"
        build.append("%s(name = %r, app_name = %r, %s = %r, srcs = [%r], deps = %s, environment = %s, is_dependency = True, compile_config = %s)" % (
            rule_name,
            app,
            app,
            project_attr,
            source + marker,
            source + "sources",
            _select(deps),
            _select(environments),
            repr(ctx.attr.compile_config) if ctx.attr.compile_config else "None",
        ))
    ctx.file("BUILD.bazel", "\n\n".join(build) + "\n")

    # Label construction binds these names in the generated repository's mapping,
    # rather than requiring consumers to use_repo every transitive package.
    root_deps = {env: [":" + e["app"] for e in manifest["environments"][env]["root"]["dependencies"] if e["compile"]] for env in _ENVS}
    entries = ["    Label(%r): [%s]," % ("@rules_elixir//:mix_" + env, ", ".join(["Label(%r)" % label for label in root_deps[env]])) for env in _ENVS]
    ctx.file("defs.bzl", "def mix_dependencies():\n    return select({\n" + "\n".join(entries) + "\n    })\n")
    source_entries = ["        Label(%r): %r," % ("@%s_%s//:sources" % (ctx.attr.prefix, app), "deps/" + app) for app in sorted(packages) if packages[app]["source"]["type"] != "path"]
    ctx.file("sources.bzl", "def mix_dependency_sources():\n    return {\n" + "\n".join(source_entries) + "\n    }\n")

_graph = repository_rule(implementation = _graph_impl, attrs = {
    "manifest": attr.string(mandatory = True),
    "prefix": attr.string(mandatory = True),
    "overrides": attr.string_dict(),
    "compile_config": attr.string(),
})

def _impl(ctx):
    names = {}
    for module in ctx.modules:
        overrides = {}
        for tag in module.tags.override:
            key = tag.graph + ":" + tag.app
            if key in overrides:
                fail("duplicate dependency override " + key)
            overrides[key] = str(tag.target)
        used_overrides = {}
        for tag in module.tags.from_file:
            _name(tag.name)
            if tag.name in names:
                fail("duplicate Mix graph name %s; give independent roots distinct names" % tag.name)
            names[tag.name] = True
            manifest = json.decode(ctx.read(tag.manifest))
            packages = validate_manifest(manifest)
            graph_overrides = {app: overrides[tag.name + ":" + app] for app in packages if tag.name + ":" + app in overrides}
            for app in graph_overrides:
                used_overrides[tag.name + ":" + app] = True
            for app, package in packages.items():
                source = package["source"]
                if source["type"] == "hex":
                    hex_archive(name = tag.name + "_" + app, package_name = source["package"], version = source["version"], sha256 = source["sha256"], build_file_content = _SOURCE_BUILD)
                elif source["type"] == "git":
                    new_git_repository(name = tag.name + "_" + app, remote = source["url"], commit = source["revision"], recursive_init_submodules = source["submodules"], build_file_content = _SOURCE_BUILD)
            _graph(name = tag.name, prefix = tag.name, manifest = json.encode(manifest), overrides = graph_overrides, compile_config = str(tag.compile_config) if tag.compile_config else "")

        for key in overrides:
            if key not in used_overrides:
                fail("override does not match a resolved dependency: " + key)

mix_deps = module_extension(
    implementation = _impl,
    tag_classes = {
        "from_file": tag_class(attrs = {"name": attr.string(mandatory = True), "manifest": attr.label(mandatory = True), "compile_config": attr.label()}),
        "override": tag_class(attrs = {"graph": attr.string(mandatory = True), "app": attr.string(mandatory = True), "target": attr.label(mandatory = True)}),
    },
)
