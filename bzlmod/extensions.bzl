load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    "//repositories:elixir_config.bzl",
    "INSTALLATION_TYPE_EXTERNAL",
    "INSTALLATION_TYPE_INTERNAL",
    "INSTALLATION_TYPE_PREBUILT",
    _elixir_config_rule = "elixir_config",
)

DEFAULT_ELIXIR_VERSION = "1.15.0"
DEFAULT_ELIXIR_SHA256 = "0f4df7574a5f300b5c66f54906222cd46dac0df7233ded165bc8e80fd9ffeb7a"

def _elixir_config(ctx):
    types = {}
    versions = {}
    urls = {}
    strip_prefixs = {}
    sha256s = {}
    elixir_homes = {}

    for mod in ctx.modules:
        for elixir in mod.tags.external_elixir_from_path:
            types[elixir.name] = INSTALLATION_TYPE_EXTERNAL
            versions[elixir.name] = elixir.version
            elixir_homes[elixir.name] = elixir.elixir_home

        for elixir in mod.tags.internal_elixir_from_http_archive:
            types[elixir.name] = INSTALLATION_TYPE_INTERNAL
            versions[elixir.name] = elixir.version
            urls[elixir.name] = elixir.url
            strip_prefixs[elixir.name] = elixir.strip_prefix
            sha256s[elixir.name] = elixir.sha256

        for elixir in mod.tags.internal_elixir_from_github_release:
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v{}.tar.gz".format(
                elixir.version,
            )
            strip_prefix = "elixir-{}".format(elixir.version)

            types[elixir.name] = INSTALLATION_TYPE_INTERNAL
            versions[elixir.name] = elixir.version
            urls[elixir.name] = url
            strip_prefixs[elixir.name] = strip_prefix
            sha256s[elixir.name] = elixir.sha256

        for elixir in mod.tags.prebuilt_elixir_from_http_archive:
            types[elixir.name] = INSTALLATION_TYPE_PREBUILT
            versions[elixir.name] = elixir.version
            urls[elixir.name] = elixir.url
            strip_prefixs[elixir.name] = elixir.strip_prefix
            sha256s[elixir.name] = elixir.sha256

        for elixir in mod.tags.prebuilt_elixir_from_hex_builds:
            # Elixir compiles to BEAM bytecode, which is architecture-independent, so unlike the
            # OTP builds hex.pm publishes there is no architecture in this path -- one archive
            # serves every platform. The sha256 is listed alongside the build in builds.txt.
            url = "https://builds.hex.pm/builds/elixir/v{}-otp-{}.zip".format(
                elixir.version,
                elixir.otp_major,
            )

            types[elixir.name] = INSTALLATION_TYPE_PREBUILT
            versions[elixir.name] = elixir.version
            urls[elixir.name] = url

            # The archive has no wrapping directory: bin/ and lib/ are at its root.
            strip_prefixs[elixir.name] = ""
            sha256s[elixir.name] = elixir.sha256

    _elixir_config_rule(
        name = "elixir_config",
        types = types,
        versions = versions,
        urls = urls,
        strip_prefixs = strip_prefixs,
        sha256s = sha256s,
        elixir_homes = elixir_homes,
    )

external_elixir_from_path = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "elixir_home": attr.string(),
})

internal_elixir_from_http_archive = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "url": attr.string(),
    "strip_prefix": attr.string(),
    "sha256": attr.string(),
})

internal_elixir_from_github_release = tag_class(attrs = {
    "name": attr.string(
        default = "internal",
    ),
    "version": attr.string(
        default = DEFAULT_ELIXIR_VERSION,
    ),
    "sha256": attr.string(
        default = DEFAULT_ELIXIR_SHA256,
    ),
})

# Any PRECOMPILED Elixir distribution -- an archive whose root holds bin/ and lib/ -- as
# opposed to an Elixir source archive, which has to be built.
prebuilt_elixir_from_http_archive = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "url": attr.string(),
    "strip_prefix": attr.string(),
    "sha256": attr.string(),
})

# Convenience wrapper over builds.hex.pm. Elixir is architecture-independent bytecode, so a
# single archive serves every platform and only the OTP major it was built against varies.
prebuilt_elixir_from_hex_builds = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "otp_major": attr.string(
        doc = "Major OTP version the build targets, e.g. \"28\" for v1.19.4-otp-28.",
    ),
    "sha256": attr.string(),
})

elixir_config = module_extension(
    implementation = _elixir_config,
    tag_classes = {
        "external_elixir_from_path": external_elixir_from_path,
        "internal_elixir_from_http_archive": internal_elixir_from_http_archive,
        "internal_elixir_from_github_release": internal_elixir_from_github_release,
        "prebuilt_elixir_from_http_archive": prebuilt_elixir_from_http_archive,
        "prebuilt_elixir_from_hex_builds": prebuilt_elixir_from_hex_builds,
    },
)

# Hex, the package manager, built from source as a Mix archive.
#
# Not for fetching anything. Mix needs Hex installed as an archive before it can resolve a
# project at all: without it, `{:dep, "~> x.y"}` in a mix.exs aborts with "Could not find an
# SCM for dependency", even for a dev-only dep that would never be compiled. A build that
# supplies every dependency from Bazel and runs `mix --no-deps-check` still trips over this.
#
# Hex has no dependencies of its own, so it bootstraps through mix_archive_build with an
# empty dep graph -- which is why this can live here rather than in the consuming module.
DEFAULT_HEX_VERSION = "2.5.1"

DEFAULT_HEX_SHA256 = "dabd99ea48ba8064c32bc2e97d59ab1b1055a38a1dd178c5389d95c35e985d2d"

_HEX_BUILD_FILE = """\
load("@rules_elixir//:mix_archive_build.bzl", "mix_archive_build")

# Consumed via `mix archive.install`, not as an ERL_LIBS dependency, so it has to be a .ez.
mix_archive_build(
    name = "archive",
    srcs = ["mix.exs"] + glob(["lib/**/*"]),
    out = "hex.ez",
    visibility = ["//visibility:public"],
)
"""

def _hex(ctx):
    version = DEFAULT_HEX_VERSION
    sha256 = DEFAULT_HEX_SHA256

    # The root module's pin wins. Without one, dependencies may pin Hex only if
    # they agree, so no module in the graph can silently replace another's pin.
    root = [tag for mod in ctx.modules if mod.is_root for tag in mod.tags.from_github_release]
    others = [tag for mod in ctx.modules if not mod.is_root for tag in mod.tags.from_github_release]
    if len(root) > 1:
        fail("the root module pins Hex more than once")
    if not root and len({(tag.version, tag.sha256.lower()): True for tag in others}) > 1:
        fail("modules pin different Hex versions; pin one in the root module")
    pins = root or others
    if pins:
        version = pins[0].version
        sha256 = pins[0].sha256.lower()
        if len(sha256) != 64 or any([c not in "0123456789abcdef" for c in sha256.elems()]):
            fail("hex.from_github_release requires the archive's 64-character sha256")

    http_archive(
        name = "hex",
        build_file_content = _HEX_BUILD_FILE,
        sha256 = sha256,
        strip_prefix = "hex-{}".format(version),
        urls = ["https://github.com/hexpm/hex/archive/refs/tags/v{}.zip".format(version)],
    )

    return ctx.extension_metadata(
        root_module_direct_deps = ["hex"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

from_github_release = tag_class(attrs = {
    "version": attr.string(
        default = DEFAULT_HEX_VERSION,
    ),
    "sha256": attr.string(
        default = DEFAULT_HEX_SHA256,
    ),
})

hex = module_extension(
    implementation = _hex,
    tag_classes = {
        "from_github_release": from_github_release,
    },
)
