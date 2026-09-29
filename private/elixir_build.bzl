load(
    "@bazel_skylib//rules:common_settings.bzl",
    "BuildSettingInfo",
)
load(
    "@bazel_tools//tools/build_defs/hash:hash.bzl",
    "sha256",
    "tools",
)
load(
    "@rules_erlang//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

ElixirInfo = provider(
    doc = "A Home directory of a built Elixir",
    fields = [
        "release_dir",
        "elixir_home",
        "version_file",
    ],
)

def _expected_sha256(ctx):
    value = ctx.attr.sha256v.lower()
    if len(value) != 64 or any([c not in "0123456789abcdef" for c in value.elems()]):
        fail("{}: sha256v must be the archive's 64-character SHA-256".format(ctx.label))
    return value

def _impl(ctx):
    (_, _, filename) = ctx.attr.url.rpartition("/")
    downloaded_archive = ctx.actions.declare_file(filename)

    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")

    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    ctx.actions.run_shell(
        inputs = [],
        outputs = [downloaded_archive],
        command = """set -euo pipefail

curl -L "{archive_url}" -o {archive_path}
""".format(
            archive_url = ctx.attr.url,
            archive_path = downloaded_archive.path,
        ),
        mnemonic = "CURL",
        progress_message = "Downloading {}".format(ctx.attr.url),
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    sha256file = sha256(ctx, downloaded_archive)

    inputs = depset(
        direct = [downloaded_archive, sha256file],
        transitive = [runfiles.files],
    )

    # See //third_party/rules_erlang/VENDORING.md, "portable tar extract" -- same bug, same fix.
    # GNU tar's --transform does not exist in the bsdtar macOS ships. The Elixir source archive
    # wraps everything in one top-level directory, so --strip-components=1 is equivalent and is
    # supported by both tar implementations.
    strip_components = "--strip-components=1" if ctx.attr.strip_prefix != "" else ""

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [release_dir],
        command = """set -euo pipefail

if [ "{sha256}" != "$(cat "{sha256file}")" ]; then
    echo "ERROR: Checksum mismatch. $(basename "{archive_path}") $(cat "{sha256file}") != {sha256}"
    exit 1
fi

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

ABS_BUILD_DIR="$(mktemp -d)"
ABS_RELEASE_DIR=$PWD/{release_path}

tar --extract \\
    {strip_components} \\
    --file {archive_path} \\
    --directory $ABS_BUILD_DIR

echo "Building ELIXIR in $ABS_BUILD_DIR"

cd $ABS_BUILD_DIR

export HOME=$PWD

make

cp -r bin $ABS_RELEASE_DIR/
cp -r lib $ABS_RELEASE_DIR/
""".format(
            sha256 = _expected_sha256(ctx),
            sha256file = sha256file.path,
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
            archive_path = downloaded_archive.path,
            strip_components = strip_components,
            release_path = release_dir.path,
        ),
        use_default_shell_env = True,
        mnemonic = "ELIXIR",
        progress_message = "Compiling elixir from source",
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    ctx.actions.run_shell(
        inputs = depset(
            direct = [release_dir],
            transitive = [runfiles.files],
        ),
        outputs = [version_file],
        command = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

"{elixir_home}"/bin/iex --version > {version_file}
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
            elixir_home = release_dir.path,
            version_file = version_file.path,
        ),
        mnemonic = "ELIXIR",
        progress_message = "Validating elixir at {}".format(release_dir.path),
    )

    return [
        DefaultInfo(
            files = depset([
                release_dir,
                version_file,
            ]),
        ),
        ctx.toolchains["@rules_erlang//tools:toolchain_type"].otpinfo,
        ElixirInfo(
            release_dir = release_dir,
            elixir_home = None,
            version_file = version_file,
        ),
    ]

elixir_build = rule(
    implementation = _impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "sha256v": attr.string(
            mandatory = True,
            doc = "SHA-256 of the archive. The download is rejected unless it matches.",
        ),
        "sha256": tools["sha256"],
    },
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)

def _elixir_prebuilt_impl(ctx):
    """Stage an already-compiled Elixir instead of building one.

    Same output contract as elixir_build -- a release_dir holding bin/ and lib/, plus a
    version_file -- so the toolchain cannot tell the two apart. What differs is that no `make`
    runs: a precompiled Elixir distribution already contains exactly the bin/ and lib/ trees
    that elixir_build copies out of its build directory.

    Elixir needs no relocation step, unlike OTP. Its launcher scripts resolve their own root
    relative to argv[0], so a precompiled distribution works from wherever it is unpacked.
    """
    (_, _, filename) = ctx.attr.url.rpartition("/")
    downloaded_archive = ctx.actions.declare_file(filename)

    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    ctx.actions.run_shell(
        inputs = [],
        outputs = [downloaded_archive],
        command = """set -euo pipefail

curl -L "{archive_url}" -o {archive_path}
""".format(
            archive_url = ctx.attr.url,
            archive_path = downloaded_archive.path,
        ),
        mnemonic = "CURL",
        progress_message = "Downloading {}".format(ctx.attr.url),
    )

    sha256file = sha256(ctx, downloaded_archive)

    strip_components = "--strip-components=1" if ctx.attr.strip_prefix != "" else ""

    ctx.actions.run_shell(
        inputs = [downloaded_archive, sha256file],
        outputs = [release_dir],
        command = """set -euo pipefail

if [ "{sha256}" != "$(cat "{sha256file}")" ]; then
    echo "ERROR: Checksum mismatch. $(basename "{archive_path}") $(cat "{sha256file}") != {sha256}"
    exit 1
fi

ABS_ARCHIVE=$PWD/{archive_path}
ABS_RELEASE_DIR=$PWD/{release_path}
ABS_STAGE_DIR="$(mktemp -d)"

cd "$ABS_STAGE_DIR"

# hex.pm publishes Elixir as a zip; a tarball is accepted too so this rule is not tied to one
# publisher. GNU tar cannot read zip archives, so the two cases cannot share a command.
case "$ABS_ARCHIVE" in
    *.zip)
        if ! command -v unzip >/dev/null 2>&1; then
            echo "ERROR: unzip is required to stage a zipped Elixir distribution but is not"
            echo "       on PATH. Install it in the execution environment, or point this rule"
            echo "       at a .tar.gz distribution instead."
            exit 1
        fi
        unzip -q "$ABS_ARCHIVE"
        ;;
    *)
        tar --extract {strip_components} --file "$ABS_ARCHIVE"
        ;;
esac

if [ ! -d bin ] || [ ! -d lib ]; then
    echo "ERROR: $(pwd) has no bin/ and lib/ after extraction."
    echo "       elixir_prebuilt expects a PRECOMPILED Elixir distribution (the layout"
    echo "       published at builds.hex.pm), not an Elixir source archive -- a source"
    echo "       archive has to be built, so use elixir_build for that."
    exit 1
fi

# zip does not always carry the executable bit through, and every launcher in bin/ needs it.
chmod +x bin/* 2>/dev/null || true

cp -r bin "$ABS_RELEASE_DIR"/
cp -r lib "$ABS_RELEASE_DIR"/
""".format(
            sha256 = _expected_sha256(ctx),
            sha256file = sha256file.path,
            archive_path = downloaded_archive.path,
            strip_components = strip_components,
            release_path = release_dir.path,
        ),
        use_default_shell_env = True,
        mnemonic = "ELIXIR",
        progress_message = "Staging prebuilt elixir",
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    # Identical validation to elixir_build: run the thing and ask it its version, rather than
    # trusting the archive to be what it claims.
    ctx.actions.run_shell(
        inputs = depset(
            direct = [release_dir],
            transitive = [runfiles.files],
        ),
        outputs = [version_file],
        command = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

"{elixir_home}"/bin/iex --version > {version_file}
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
            elixir_home = release_dir.path,
            version_file = version_file.path,
        ),
        mnemonic = "ELIXIR",
        progress_message = "Validating prebuilt elixir at {}".format(release_dir.path),
    )

    return [
        DefaultInfo(
            files = depset([
                release_dir,
                version_file,
            ]),
        ),
        ctx.toolchains["@rules_erlang//tools:toolchain_type"].otpinfo,
        ElixirInfo(
            release_dir = release_dir,
            elixir_home = None,
            version_file = version_file,
        ),
    ]

elixir_prebuilt = rule(
    implementation = _elixir_prebuilt_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "sha256v": attr.string(
            mandatory = True,
            doc = "SHA-256 of the archive. The download is rejected unless it matches.",
        ),
        "sha256": tools["sha256"],
    },
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)

def _elixir_external_impl(ctx):
    elixir_home = ctx.attr.elixir_home
    if elixir_home == "":
        elixir_home = ctx.attr._elixir_home[BuildSettingInfo].value

    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    ctx.actions.run_shell(
        inputs = runfiles.files,
        outputs = [version_file],
        command = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

"{elixir_home}"/bin/iex --version > {version_file}
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
            elixir_home = elixir_home,
            version_file = version_file.path,
        ),
        mnemonic = "ELIXIR",
        progress_message = "Validating elixir at {}".format(elixir_home),
    )

    return [
        DefaultInfo(
            files = depset([version_file]),
        ),
        ctx.toolchains["@rules_erlang//tools:toolchain_type"].otpinfo,
        ElixirInfo(
            release_dir = None,
            elixir_home = elixir_home,
            version_file = version_file,
        ),
    ]

elixir_external = rule(
    implementation = _elixir_external_impl,
    attrs = {
        "_elixir_home": attr.label(default = Label("//:elixir_home")),
        "elixir_home": attr.string(),
    },
    toolchains = ["@rules_erlang//tools:toolchain_type"],
)
