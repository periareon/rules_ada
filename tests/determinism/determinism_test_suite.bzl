"""Analysis tests for output determinism (scrub flags)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _action_counts(actions, mnemonic):
    return [a for a in actions if a.mnemonic == mnemonic]

def _compile_actions_have_scrub_ali_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    for a in _action_counts(actions, "AdaCompileInterface") + _action_counts(actions, "AdaCompileFull"):
        asserts.true(
            env,
            "--scrub-ali" in a.argv,
            "--scrub-ali missing in %s argv" % a.mnemonic,
        )
    return analysistest.end(env)

compile_actions_have_scrub_ali_test = analysistest.make(
    _compile_actions_have_scrub_ali_test_impl,
)

def _bind_action_has_scrub_binder_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bind_actions = _action_counts(actions, "AdaBind")
    asserts.true(env, len(bind_actions) > 0, "expected at least one AdaBind action")
    for a in bind_actions:
        asserts.true(
            env,
            "--scrub-binder" in a.argv,
            "--scrub-binder missing in AdaBind argv",
        )
    return analysistest.end(env)

bind_action_has_scrub_binder_test = analysistest.make(
    _bind_action_has_scrub_binder_test_impl,
)

def determinism_test_suite(name):
    """Analysis tests verifying scrub flags are wired into actions.

    Args:
        name: test suite name.
    """
    compile_actions_have_scrub_ali_test(
        name = "compile_actions_have_scrub_ali_test",
        target_under_test = ":lib",
    )

    bind_action_has_scrub_binder_test(
        name = "binary_bind_has_scrub_binder_test",
        target_under_test = ":bin",
    )

    bind_action_has_scrub_binder_test(
        name = "static_lib_bind_has_scrub_binder_test",
        target_under_test = ":static_lib",
    )

    bind_action_has_scrub_binder_test(
        name = "shared_lib_bind_has_scrub_binder_test",
        target_under_test = ":shared_lib",
    )

    native.test_suite(
        name = name,
        tests = [
            ":compile_actions_have_scrub_ali_test",
            ":binary_bind_has_scrub_binder_test",
            ":static_lib_bind_has_scrub_binder_test",
            ":shared_lib_bind_has_scrub_binder_test",
        ],
    )
