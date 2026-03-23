"""Incrementality invariant tests.

These assert directly on compile action inputs to lock in the spec/body split
contract: downstream compiles see deps' SPEC ALIs and SPEC sources, but NOT
body ALIs nor body sources (unless the dep opted in with exports_bodies=True).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _input_paths(action):
    return [f.path for f in action.inputs.to_list()]

def _find_full_compile(actions, stem):
    matches = [
        a
        for a in actions
        if a.mnemonic == "AdaCompileFull" and any([
            o.path.endswith("/body/%s.ali" % stem)
            for o in a.outputs.to_list()
        ])
    ]
    return matches[0] if matches else None

def _no_body_ali_from_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bar_full = _find_full_compile(actions, "bar")
    asserts.true(env, bar_full != None, "expected an AdaCompileFull for stem 'bar'")
    paths = _input_paths(bar_full)
    leaks = [p for p in paths if "/body/foo.ali" in p]
    asserts.equals(
        env,
        [],
        leaks,
        "downstream body compile must not have dep's body ALI as input; got: %s" % leaks,
    )
    return analysistest.end(env)

no_body_ali_from_deps_test = analysistest.make(_no_body_ali_from_deps_test_impl)

def _spec_ali_from_deps_present_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bar_full = _find_full_compile(actions, "bar")
    paths = _input_paths(bar_full)
    has_spec_ali = any(["/spec/foo.ali" in p for p in paths])
    asserts.true(
        env,
        has_spec_ali,
        "downstream body compile must see dep's spec/foo.ali; inputs=%s" %
        [p for p in paths if "foo" in p],
    )
    return analysistest.end(env)

spec_ali_from_deps_present_test = analysistest.make(_spec_ali_from_deps_present_test_impl)

def _no_body_source_from_default_dep_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bar_full = _find_full_compile(actions, "bar")
    paths = _input_paths(bar_full)
    leaks = [p for p in paths if p.endswith("/srcs/foo.adb")]
    asserts.equals(
        env,
        [],
        leaks,
        "default dep's body source must NOT leak into downstream compile inputs; got: %s" %
        leaks,
    )
    return analysistest.end(env)

no_body_source_from_default_dep_test = analysistest.make(_no_body_source_from_default_dep_test_impl)

def _body_source_flows_when_exports_bodies_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bar_full = _find_full_compile(actions, "bar")
    paths = _input_paths(bar_full)
    has_body = any([p.endswith("/srcs/foo.adb") for p in paths])
    asserts.true(
        env,
        has_body,
        "exports_bodies=True dep's body source must flow into downstream compile inputs",
    )
    return analysistest.end(env)

body_source_flows_when_exports_bodies_test = analysistest.make(
    _body_source_flows_when_exports_bodies_test_impl,
)

def _binder_does_not_see_spec_alidirs_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bind_actions = [a for a in actions if a.mnemonic == "AdaBind"]
    asserts.equals(env, 1, len(bind_actions))
    args = bind_actions[0].argv
    spec_args = [a for a in args if a.startswith("-I") and "/spec/" in a]
    asserts.equals(
        env,
        [],
        spec_args,
        "gnatbind must not be passed -I pointing at spec/ dirs; got: %s" % spec_args,
    )
    return analysistest.end(env)

binder_does_not_see_spec_alidirs_test = analysistest.make(_binder_does_not_see_spec_alidirs_test_impl)

def incrementality_test_suite(name):
    """Incrementality analysis test suite.

    Args:
        name: test suite name.
    """
    no_body_ali_from_deps_test(
        name = "no_body_ali_from_deps_test",
        target_under_test = ":bar_using_default",
    )

    spec_ali_from_deps_present_test(
        name = "spec_ali_from_deps_present_test",
        target_under_test = ":bar_using_default",
    )

    no_body_source_from_default_dep_test(
        name = "no_body_source_from_default_dep_test",
        target_under_test = ":bar_using_default",
    )

    body_source_flows_when_exports_bodies_test(
        name = "body_source_flows_when_exports_bodies_test",
        target_under_test = ":bar_using_exports",
    )

    binder_does_not_see_spec_alidirs_test(
        name = "binder_does_not_see_spec_alidirs_test",
        target_under_test = ":main_using_default",
    )

    native.test_suite(
        name = name,
        tests = [
            ":no_body_ali_from_deps_test",
            ":spec_ali_from_deps_present_test",
            ":no_body_source_from_default_dep_test",
            ":body_source_flows_when_exports_bodies_test",
            ":binder_does_not_see_spec_alidirs_test",
        ],
    )
