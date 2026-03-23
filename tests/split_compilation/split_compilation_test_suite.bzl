"""Analysis tests for spec/body split compilation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//ada:ada_info.bzl", "AdaInfo")

def _action_counts(actions, mnemonic):
    return [a for a in actions if a.mnemonic == mnemonic]

def _two_unit_actions_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(env, 2, len(_action_counts(actions, "AdaCompileInterface")))
    asserts.equals(env, 2, len(_action_counts(actions, "AdaCompileFull")))
    asserts.equals(env, 0, len(_action_counts(actions, "AdaBind")))
    asserts.equals(env, 0, len(_action_counts(actions, "AdaLink")))
    return analysistest.end(env)

two_unit_actions_test = analysistest.make(_two_unit_actions_test_impl)

def _spec_only_actions_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(env, 0, len(_action_counts(actions, "AdaCompileInterface")))
    asserts.equals(env, 1, len(_action_counts(actions, "AdaCompileFull")))
    return analysistest.end(env)

spec_only_actions_test = analysistest.make(_spec_only_actions_test_impl)

def _direct_ali_counts_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[AdaInfo]
    asserts.equals(env, 2, len(info.direct_spec_alis.to_list()))
    asserts.equals(env, 2, len(info.direct_body_alis.to_list()))
    asserts.equals(env, 2, len(info.direct_objects.to_list()))
    return analysistest.end(env)

direct_ali_counts_test = analysistest.make(_direct_ali_counts_test_impl)

def _transitive_aggregation_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[AdaInfo]
    asserts.equals(env, 2, len(info.transitive_spec_alis.to_list()))
    asserts.equals(env, 3, len(info.transitive_body_alis.to_list()))
    return analysistest.end(env)

transitive_aggregation_test = analysistest.make(_transitive_aggregation_test_impl)

def _copts_propagated_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    interface = _action_counts(actions, "AdaCompileInterface")
    full = _action_counts(actions, "AdaCompileFull")
    asserts.true(env, len(interface) > 0, "expected at least one interface compile")
    asserts.true(env, len(full) > 0, "expected at least one full compile")
    for action in interface + full:
        asserts.true(
            env,
            "-gnatwa" in action.argv,
            "copts -gnatwa missing in %s argv" % action.mnemonic,
        )
        asserts.true(
            env,
            "-O2" in action.argv,
            "copts -O2 missing in %s argv" % action.mnemonic,
        )
    return analysistest.end(env)

copts_propagated_test = analysistest.make(_copts_propagated_test_impl)

def _subunit_no_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    full = _action_counts(actions, "AdaCompileFull")
    asserts.equals(env, 1, len(full))
    asserts.equals(env, 1, len(_action_counts(actions, "AdaCompileInterface")))
    return analysistest.end(env)

subunit_no_action_test = analysistest.make(_subunit_no_action_test_impl)

def _subunit_is_input_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    parent_full = [
        a
        for a in actions
        if a.mnemonic == "AdaCompileFull" and any([
            o.path.endswith("/parent.ali")
            for o in a.outputs.to_list()
        ])
    ]
    asserts.equals(env, 1, len(parent_full))
    input_paths = [f.path for f in parent_full[0].inputs.to_list()]
    asserts.true(
        env,
        any([p.endswith("parent-child.adb") for p in input_paths]),
        "parent-child.adb should appear among parent's compile inputs",
    )
    return analysistest.end(env)

subunit_is_input_test = analysistest.make(_subunit_is_input_test_impl)

def _explicit_subunits_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    full = _action_counts(actions, "AdaCompileFull")
    asserts.equals(
        env,
        1,
        len(full),
        "expected only the parent's full compile, got %d" % len(full),
    )
    parent_full = full[0]
    asserts.true(
        env,
        parent_full.outputs.to_list()[0].path.endswith("parent.ali"),
        "expected parent.ali, got %s" % parent_full.outputs.to_list()[0].path,
    )
    input_paths = [f.path for f in parent_full.inputs.to_list()]
    asserts.true(
        env,
        any([p.endswith("/parent_oddly_named.adb") for p in input_paths]),
        "explicit subunit must flow as input to parent compile",
    )
    return analysistest.end(env)

explicit_subunits_test = analysistest.make(_explicit_subunits_test_impl)

def split_compilation_test_suite(name):
    """Analysis tests for spec/body split compilation.

    Args:
        name: test suite name.
    """
    two_unit_actions_test(
        name = "two_unit_actions_test",
        target_under_test = ":two_unit_lib",
    )

    spec_only_actions_test(
        name = "spec_only_actions_test",
        target_under_test = ":spec_only_lib",
    )

    direct_ali_counts_test(
        name = "direct_ali_counts_test",
        target_under_test = ":two_unit_lib",
    )

    transitive_aggregation_test(
        name = "transitive_aggregation_test",
        target_under_test = ":downstream_lib",
    )

    copts_propagated_test(
        name = "copts_propagated_test",
        target_under_test = ":copts_lib",
    )

    subunit_no_action_test(
        name = "subunit_no_action_test",
        target_under_test = ":parent_with_subunit",
    )

    subunit_is_input_test(
        name = "subunit_is_input_test",
        target_under_test = ":parent_with_subunit",
    )

    explicit_subunits_test(
        name = "explicit_subunits_test",
        target_under_test = ":explicit_subunit_lib",
    )

    native.test_suite(
        name = name,
        tests = [
            ":two_unit_actions_test",
            ":spec_only_actions_test",
            ":direct_ali_counts_test",
            ":transitive_aggregation_test",
            ":copts_propagated_test",
            ":subunit_no_action_test",
            ":subunit_is_input_test",
            ":explicit_subunits_test",
        ],
    )
