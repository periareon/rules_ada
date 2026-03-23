"""Analysis tests for library-mode binding."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _action_counts(actions, mnemonic):
    return [a for a in actions if a.mnemonic == mnemonic]

def _static_action_graph_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)

    # spec+body unit: 1 interface compile + 1 full compile
    asserts.equals(env, 1, len(_action_counts(actions, "AdaCompileInterface")))
    asserts.equals(env, 1, len(_action_counts(actions, "AdaCompileFull")))

    # library-mode bind (produces binder .o in same action)
    asserts.equals(env, 1, len(_action_counts(actions, "AdaBind")))
    asserts.equals(env, 1, len(_action_counts(actions, "AdaArchive")))
    asserts.equals(env, 0, len(_action_counts(actions, "AdaLinkShared")))
    asserts.equals(env, 0, len(_action_counts(actions, "AdaLink")))
    return analysistest.end(env)

static_action_graph_test = analysistest.make(_static_action_graph_test_impl)

def _static_compiles_are_pic_test_impl(ctx):
    env = analysistest.begin(ctx)
    for a in _action_counts(analysistest.target_actions(env), "AdaCompileFull"):
        asserts.true(
            env,
            "-fPIC" in a.argv,
            "expected -fPIC in compile argv: %s" % a.argv,
        )
    return analysistest.end(env)

static_compiles_are_pic_test = analysistest.make(_static_compiles_are_pic_test_impl)

def _static_bind_is_library_mode_test_impl(ctx):
    env = analysistest.begin(ctx)
    bind_actions = _action_counts(analysistest.target_actions(env), "AdaBind")
    asserts.equals(env, 1, len(bind_actions))
    argv = bind_actions[0].argv
    asserts.true(env, "-n" in argv, "missing -n")
    asserts.true(env, "-a" in argv, "missing -a")
    return analysistest.end(env)

static_bind_is_library_mode_test = analysistest.make(_static_bind_is_library_mode_test_impl)

def _archive_includes_binder_test_impl(ctx):
    env = analysistest.begin(ctx)
    arch = _action_counts(analysistest.target_actions(env), "AdaArchive")
    asserts.equals(env, 1, len(arch))
    inputs = [f.path for f in arch[0].inputs.to_list()]
    binder_objs = [p for p in inputs if "/b_" in p and p.endswith(".o")]
    asserts.true(
        env,
        len(binder_objs) > 0,
        "binder object must be archived alongside unit objects",
    )
    return analysistest.end(env)

archive_includes_binder_test = analysistest.make(_archive_includes_binder_test_impl)

def _static_exposes_cc_info_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, CcInfo in target, "ada_static_library must provide CcInfo")
    libs = []
    for li in target[CcInfo].linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            if lib.pic_static_library != None:
                libs.append(lib.pic_static_library)
    asserts.equals(
        env,
        1,
        len(libs),
        "CcInfo should expose one pic_static_library, got %d" % len(libs),
    )
    asserts.true(
        env,
        libs[0].path.endswith(".a"),
        "expected .a suffix, got: %s" % libs[0].path,
    )
    return analysistest.end(env)

static_exposes_cc_info_test = analysistest.make(_static_exposes_cc_info_test_impl)

def _shared_action_graph_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)

    # spec+body unit: 1 interface compile + 1 full compile
    asserts.equals(env, 1, len(_action_counts(actions, "AdaCompileInterface")))
    asserts.equals(env, 1, len(_action_counts(actions, "AdaCompileFull")))

    # library-mode bind (produces binder .o in same action)
    asserts.equals(env, 1, len(_action_counts(actions, "AdaBind")))
    asserts.equals(env, 1, len(_action_counts(actions, "AdaLinkShared")))
    return analysistest.end(env)

shared_action_graph_test = analysistest.make(_shared_action_graph_test_impl)

def _shared_compiles_are_pic_test_impl(ctx):
    env = analysistest.begin(ctx)
    compiles = _action_counts(analysistest.target_actions(env), "AdaCompileFull")
    for a in compiles:
        asserts.true(
            env,
            "-fPIC" in a.argv,
            "expected -fPIC in compile argv: %s" % a.argv,
        )
    return analysistest.end(env)

shared_compiles_are_pic_test = analysistest.make(_shared_compiles_are_pic_test_impl)

def _shared_bind_is_library_mode_test_impl(ctx):
    env = analysistest.begin(ctx)
    bind_actions = _action_counts(analysistest.target_actions(env), "AdaBind")
    asserts.equals(env, 1, len(bind_actions))
    argv = bind_actions[0].argv
    asserts.true(env, "-n" in argv, "missing -n in gnatbind argv: %s" % argv)
    asserts.true(env, "-a" in argv, "missing -a in gnatbind argv: %s" % argv)
    has_l_name = any([a.startswith("-L") and not a.startswith("-Lib") for a in argv])
    asserts.true(env, has_l_name, "missing -L<name> in gnatbind argv: %s" % argv)
    return analysistest.end(env)

shared_bind_is_library_mode_test = analysistest.make(_shared_bind_is_library_mode_test_impl)

def _shared_link_uses_shared_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    link = _action_counts(analysistest.target_actions(env), "AdaLinkShared")
    asserts.equals(env, 1, len(link))
    argv = link[0].argv
    asserts.true(env, "-shared" in argv, "missing -shared")
    return analysistest.end(env)

shared_link_uses_shared_flags_test = analysistest.make(_shared_link_uses_shared_flags_test_impl)

def _shared_exposes_cc_info_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, CcInfo in target, "ada_shared_library must provide CcInfo")
    return analysistest.end(env)

shared_exposes_cc_info_test = analysistest.make(_shared_exposes_cc_info_test_impl)

def library_binding_test_suite(name):
    """Analysis tests for library-mode binding.

    Args:
        name: test suite name.
    """
    static_action_graph_test(
        name = "static_action_graph_test",
        target_under_test = ":static_lib",
    )

    static_compiles_are_pic_test(
        name = "static_compiles_are_pic_test",
        target_under_test = ":static_lib",
    )

    static_bind_is_library_mode_test(
        name = "static_bind_is_library_mode_test",
        target_under_test = ":static_lib",
    )

    archive_includes_binder_test(
        name = "archive_includes_binder_test",
        target_under_test = ":static_lib",
    )

    static_exposes_cc_info_test(
        name = "static_exposes_cc_info_test",
        target_under_test = ":static_lib",
    )

    shared_action_graph_test(
        name = "shared_action_graph_test",
        target_under_test = ":shared_lib",
    )

    shared_compiles_are_pic_test(
        name = "shared_compiles_are_pic_test",
        target_under_test = ":shared_lib",
    )

    shared_bind_is_library_mode_test(
        name = "shared_bind_is_library_mode_test",
        target_under_test = ":shared_lib",
    )

    shared_link_uses_shared_flags_test(
        name = "shared_link_uses_shared_flags_test",
        target_under_test = ":shared_lib",
    )

    shared_exposes_cc_info_test(
        name = "shared_exposes_cc_info_test",
        target_under_test = ":shared_lib",
    )

    native.test_suite(
        name = name,
        tests = [
            ":static_action_graph_test",
            ":static_compiles_are_pic_test",
            ":static_bind_is_library_mode_test",
            ":archive_includes_binder_test",
            ":static_exposes_cc_info_test",
            ":shared_action_graph_test",
            ":shared_compiles_are_pic_test",
            ":shared_bind_is_library_mode_test",
            ":shared_link_uses_shared_flags_test",
            ":shared_exposes_cc_info_test",
        ],
    )
