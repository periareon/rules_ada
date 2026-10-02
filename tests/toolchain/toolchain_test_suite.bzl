"""Analysis tests for `ada_toolchain`, `ada_args` and `ada_feature`."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//ada:ada_toolchain.bzl", "AdaToolchainInfo")

def _provider_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[AdaToolchainInfo]

    asserts.equals(
        env,
        ["fake_objects", "fake_libraries", "fake_rpaths", "fake_output", "fake_runtime"],
        [a.label.name for a in info.args],
        "args are flattened in toolchain order",
    )
    asserts.equals(env, ["fake_feature", "static_libgcc"], [f.name for f in info.known_features])
    asserts.equals(env, ["fake_feature"], [f.name for f in info.enabled_features])
    asserts.equals(env, "%{name}.fake", info.artifact_name_patterns["executable"])
    asserts.equals(env, "lib%{name}.so", info.artifact_name_patterns["shared_library"], "defaults fill the gaps")
    asserts.equals(
        env,
        ["libgnarl.a", "libgnat.a", "libgcc.a"],
        [f.basename for f in info.static_runtime_lib],
        "static_runtime_lib keeps the declared link order",
    )
    asserts.equals(env, ["libgcc_s.1.1.dylib"], [f.basename for f in info.dynamic_runtime_lib])
    asserts.equals(env, ["extra.txt"], [f.basename for f in info.args_files.to_list()])
    return analysistest.end(env)

provider_test = analysistest.make(_provider_test_impl)

def _link_action(env, mnemonic):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, 1, len(actions), "expected exactly one %s action" % mnemonic)
    return actions[0] if actions else None

def _after_compiler(argv):
    """The arguments the toolchain's args produced: everything after `-- <compiler>`."""
    if "--" not in argv:
        return []
    return argv[argv.index("--") + 2:]

def _fake_link_test_impl(ctx):
    """The whole link line is the expansion of the fake toolchain's args and features."""
    env = analysistest.begin(ctx)
    action = _link_action(env, "AdaLink")
    if not action:
        return analysistest.end(env)
    args = _after_compiler(action.argv)
    output = action.outputs.to_list()[0]

    asserts.equals(env, "fake_main.fake", output.basename, "artifact_name_patterns names the executable")
    asserts.equals(env, 12, len(args), "unexpected link line: %s" % args)
    if len(args) == 12:
        asserts.true(env, args[0].endswith("main.o") and args[1].endswith(".o"), "objects first: %s" % args)
        asserts.true(env, args[2].startswith("--whole=") and "fake_alwayslink" in args[2], "alwayslink wrapped per element: %s" % args)
        asserts.equals(env, "--rpath=ORIGIN/fake_main.fake.runtime_libs", args[3], "staged runtime libs get a search directory")
        asserts.equals(env, "--out", args[4])
        asserts.true(env, args[5].endswith("/fake_main.fake"), "output path: %s" % args[5])
        asserts.equals(env, ["--basename", "fake_main.fake"], args[6:8])
        asserts.equals(env, ["libgnarl.a", "libgnat.a", "libgcc.a"], [a.rsplit("/", 1)[-1] for a in args[8:11]])
        asserts.equals(env, "--fake-feature", args[11], "enabled feature args come last")

    inputs = [f.basename for f in action.inputs.to_list()]
    asserts.true(env, "extra.txt" in inputs, "args data files are action inputs")
    asserts.true(env, "libgnat.a" in inputs, "runtime archives are action inputs")

    staged = [f for f in analysistest.target_under_test(env)[DefaultInfo].default_runfiles.files.to_list() if f.basename == "libgcc_s.1.1.dylib"]
    asserts.equals(env, 1, len(staged), "static_libgcc is known but not enabled, so the dylib is staged")
    return analysistest.end(env)

fake_link_test = analysistest.make(
    _fake_link_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": ["//tests/toolchain:fake"],
    },
)

def _windows_executable_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _link_action(env, "AdaLink")
    if not action:
        return analysistest.end(env)
    asserts.equals(env, "fake_windows_main.exe", action.outputs.to_list()[0].basename)
    args = _after_compiler(action.argv)
    asserts.false(env, any([a.startswith("-Wl,-rpath") for a in args]), "no rpaths on Windows: %s" % args)
    asserts.true(env, any([a.endswith("/libgnat.a") for a in args]), "runtime archives linked: %s" % args)
    asserts.equals(env, "-o", args[-2], "output flag last: %s" % args)
    return analysistest.end(env)

windows_executable_test = analysistest.make(
    _windows_executable_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": ["//tests/toolchain:fake_windows"],
    },
)

def _windows_shared_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _link_action(env, "AdaLinkShared")
    if not action:
        return analysistest.end(env)
    asserts.equals(env, "fake_lib.dll", action.outputs.to_list()[0].basename)
    args = _after_compiler(action.argv)
    asserts.equals(env, "-shared", args[0], "shared flag first: %s" % args)
    asserts.true(env, any([a.endswith("/libgnat.a") for a in args]), "a DLL carries the runtime: %s" % args)
    asserts.false(env, any([a.startswith("-Wl,-soname") for a in args]), "no soname on Windows: %s" % args)
    return analysistest.end(env)

windows_shared_library_test = analysistest.make(
    _windows_shared_library_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": ["//tests/toolchain:fake_windows"],
    },
)

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected)
    return analysistest.end(env)

failure_test = analysistest.make(
    _failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected": attr.string(doc = "Substring the failure message must contain."),
    },
)

_FAILURES = {
    "bad_action": "unknown action",
    "bad_args_and_nested": "mutually exclusive",
    "bad_compile_variable": "unknown variable",
    "bad_duplicate_feature": "twice",
    "bad_enabled_unknown": "known_features",
    "bad_feature_name": "feature_name",
    "bad_list_in_string": "cannot be interpolated",
    "bad_pattern": "%{name}",
    "bad_pattern_category": "unknown artifact_name_patterns category",
    "bad_requires_true": "needs a bool variable",
    "bad_two_requires": "only one of",
    "bad_variable": "unknown variable",
}

def toolchain_test_suite(name):
    """Instantiate the analysis tests.

    Args:
        name: Name of the test suite.
    """
    provider_test(
        name = "provider_test",
        target_under_test = ":fake_toolchain",
    )
    fake_link_test(
        name = "fake_link_test",
        target_under_test = ":fake_main",
    )
    windows_executable_test(
        name = "windows_executable_test",
        target_under_test = ":fake_windows_main",
    )
    windows_shared_library_test(
        name = "windows_shared_library_test",
        target_under_test = ":fake_lib",
    )
    for target, expected in _FAILURES.items():
        failure_test(
            name = target + "_test",
            target_under_test = ":" + target,
            expected = expected,
        )

    native.test_suite(
        name = name,
        tests = [
            ":provider_test",
            ":fake_link_test",
            ":windows_executable_test",
            ":windows_shared_library_test",
        ] + [":" + target + "_test" for target in _FAILURES.keys()],
    )
