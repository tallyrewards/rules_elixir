#!/usr/bin/env bash
# Installation names come from every module in the graph. A dependency must not
# be able to redefine the root module's installation, and without host discovery
# the default toolchain must come from the root module.
set -euo pipefail

bazel=${BAZEL:-bazelisk}
rules=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/dep"
touch "$work/BUILD.bazel" "$work/dep/BUILD.bazel"

root_module() {
  cat > "$work/MODULE.bazel" <<MODULE
module(name = "installation_names")
bazel_dep(name = "rules_elixir", version = "0.0.0")
local_path_override(module_name = "rules_elixir", path = "$rules")
$(sed -n '/^git_override(/,/^)/p' "$rules/MODULE.bazel")
bazel_dep(name = "dep", version = "0.0.0")
local_path_override(module_name = "dep", path = "dep")
elixir_config = use_extension("@rules_elixir//bzlmod:extensions.bzl", "elixir_config")
$1
use_repo(elixir_config, "elixir_config")
MODULE
}

dependency_declares() {
  cat > "$work/dep/MODULE.bazel" <<MODULE
module(name = "dep", version = "0.0.0")
bazel_dep(name = "rules_elixir", version = "0.0.0")
elixir_config = use_extension("@rules_elixir//bzlmod:extensions.bzl", "elixir_config")
elixir_config.internal_elixir_from_http_archive(
    name = "$1",
    version = "1.0.0",
    url = "https://dependency.invalid/elixir.tar.gz",
    sha256 = "$(printf '0%.0s' {1..64})",
)
MODULE
}

query() {
  (cd "$work" && "$bazel" query --noshow_progress --repo_env=RULES_ELIXIR_SKIP_SYSTEM=1 \
    --output=build @elixir_config//external:elixir_build 2>&1) || true
}

pinned='elixir_config.internal_elixir_from_github_release(name = "pinned", version = "1.20.3", sha256 = "ff22a894b130631443db1a193b4e8cb4762f697128566e43da848fd16c3777bd")'

root_module "$pinned"
dependency_declares pinned
query | grep -qF "Elixir installation 'pinned' is declared by both installation_names and dep"

dependency_declares other
query | grep -qF 'url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v1.20.3.tar.gz"'

root_module ""
query | grep -qF "declare an Elixir installation in the root module"

(cd "$work" && "$bazel" shutdown)
echo "installation names: ok"
