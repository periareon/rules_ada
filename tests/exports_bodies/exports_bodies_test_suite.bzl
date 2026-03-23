"""Analysis tests for exports_bodies attribute."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//ada:ada_info.bzl", "AdaInfo")

def _exports_bodies_true_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[AdaInfo]
    bodies = info.transitive_exported_bodies.to_list()
    asserts.true(
        env,
        len(bodies) > 0,
        "transitive_exported_bodies should be non-empty when exports_bodies=True",
    )
    return analysistest.end(env)

exports_bodies_true_test = analysistest.make(_exports_bodies_true_test_impl)

def _exports_bodies_default_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[AdaInfo]
    bodies = info.transitive_exported_bodies.to_list()
    asserts.equals(
        env,
        0,
        len(bodies),
        "transitive_exported_bodies should be empty when exports_bodies is default",
    )
    return analysistest.end(env)

exports_bodies_default_test = analysistest.make(_exports_bodies_default_test_impl)

def exports_bodies_test_suite(name):
    """Analysis tests for exports_bodies attribute."""
    exports_bodies_true_test(
        name = "exports_bodies_true_test",
        target_under_test = ":exports_lib",
    )

    exports_bodies_default_test(
        name = "exports_bodies_default_test",
        target_under_test = ":default_lib",
    )

    native.test_suite(
        name = name,
        tests = [
            ":exports_bodies_true_test",
            ":exports_bodies_default_test",
        ],
    )
