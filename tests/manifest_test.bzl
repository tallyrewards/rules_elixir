"""Graph admission tests: ambiguous or incomplete graphs must never build."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//bzlmod:mix_deps.bzl", "validate_manifest")

def _validate_impl(ctx):
    validate_manifest(json.decode(ctx.attr.manifest))
    return []

_validate = rule(implementation = _validate_impl, attrs = {"manifest": attr.string()})

def _reject_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_reject_test = analysistest.make(_reject_impl, expect_failure = True, attrs = {"message": attr.string()})

def _edge(app):
    return dict(app = app, compile = True, runtime = False, optional = False, override = False, environment = "prod")

def _manifest():
    return {
        "schema_version": 1,
        "environments": {env: {
            "root": {"app": "sample", "dependencies": [_edge("leaf")]},
            "packages": {"leaf": {
                "source": {"type": "hex", "sha256": "a" * 64, "package": "leaf", "version": "1.0.0", "repository": "hexpm"},
                "manager": "mix",
                "environment": "prod",
                "dependencies": [],
            }},
        } for env in ["dev", "test", "prod"]},
    }

def manifest_tests():
    cases = []
    source_conflict = _manifest()
    source_conflict["environments"]["test"]["packages"]["leaf"]["source"]["sha256"] = "b" * 64
    cases.append(("source_conflict", source_conflict, "conflicting immutable source identities"))

    unresolved = _manifest()
    unresolved["environments"]["dev"]["packages"]["leaf"]["dependencies"] = [_edge("missing")]
    cases.append(("unresolved", unresolved, "unresolved edge"))

    cycle = _manifest()
    cycle["environments"]["dev"]["packages"]["leaf"]["dependencies"] = [_edge("leaf")]
    cases.append(("cycle", cycle, "dependency cycle"))

    checksum = _manifest()
    checksum["environments"]["dev"]["packages"]["leaf"]["source"]["sha256"] = "not-a-checksum"
    cases.append(("checksum", checksum, "immutable lowercase hex digest"))

    environment = _manifest()
    environment["environments"]["dev"]["root"]["dependencies"][0]["environment"] = "test"
    cases.append(("environment", environment, "edge environment differs"))

    for name, manifest, message in cases:
        _validate(name = name + "_graph", manifest = json.encode(manifest), tags = ["manual"])
        _reject_test(name = name + "_test", target_under_test = ":" + name + "_graph", message = message)
