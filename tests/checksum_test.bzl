"""Downloaded Elixir archives must be pinned."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//private:elixir_build.bzl", "elixir_build", "elixir_prebuilt")

def _rejected_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "sha256v must be the archive's 64-character SHA-256")
    return analysistest.end(env)

_rejected_test = analysistest.make(_rejected_impl, expect_failure = True)

def checksum_tests():
    for rule, kind in [(elixir_build, "source"), (elixir_prebuilt, "prebuilt")]:
        for case, value in [("empty", ""), ("malformed", "not-a-sha256")]:
            name = "{}_{}_sha256".format(case, kind)
            rule(
                name = name + "_target",
                url = "https://example.invalid/elixir.tar.gz",
                sha256v = value,
                tags = ["manual"],
            )
            _rejected_test(name = name + "_test", target_under_test = ":" + name + "_target")
