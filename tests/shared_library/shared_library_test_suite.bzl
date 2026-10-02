"""Analysis tests for the link lines of `ada_shared_library` and its consumers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_RUNTIME_ARCHIVES = ["libgnarl.a", "libgnat.a", "libgcc.a"]

def _link_action(env, mnemonic = "AdaLink"):
    links = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, 1, len(links), "expected exactly one %s action" % mnemonic)
    return links[0] if links else None

def _link_argv(env, mnemonic = "AdaLink"):
    action = _link_action(env, mnemonic)
    return action.argv if action else []

def _shared_dep_not_relinked_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _link_argv(env)

    objects = [a for a in argv if a.endswith("math_ops.o")]
    asserts.equals(
        env,
        [],
        objects,
        "objects of a shared library dep must not be linked into the executable",
    )

    shared = [a for a in argv if a.endswith("libmath_ops.so") or a.endswith("math_ops.dll")]
    asserts.equals(
        env,
        1,
        len(shared),
        "expected the shared library itself on the link line: %s" % argv,
    )
    return analysistest.end(env)

shared_dep_not_relinked_test = analysistest.make(_shared_dep_not_relinked_test_impl)

def _shared_dep_rpath_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _link_argv(env)

    rpaths = [a for a in argv if a.startswith("-Wl,-rpath,")]
    asserts.true(env, len(rpaths) > 0, "expected an rpath for the shared library dep: %s" % argv)

    # The library lives in the `lib` subpackage, not next to the executable.
    asserts.true(
        env,
        any([r.endswith("/lib") for r in rpaths]),
        "expected an rpath pointing into the lib subpackage, got: %s" % rpaths,
    )
    for rpath in rpaths:
        asserts.true(
            env,
            rpath.startswith("-Wl,-rpath,$ORIGIN/") or rpath.startswith("-Wl,-rpath,@loader_path/"),
            "rpaths are relative to the loader: %s" % rpath,
        )
    return analysistest.end(env)

shared_dep_rpath_test = analysistest.make(_shared_dep_rpath_test_impl)

def _elf_link_group_test_impl(ctx):
    """GNU ld needs the dependency libraries wrapped in a group; shared libraries skip it."""
    env = analysistest.begin(ctx)
    argv = _link_argv(env)
    start = argv.index("-Wl,--start-group") if "-Wl,--start-group" in argv else -1
    end = argv.index("-Wl,--end-group") if "-Wl,--end-group" in argv else -1
    lib = _index_of_suffix(argv, "libmath_ops.so")
    asserts.true(env, 0 <= start and start < lib and lib < end, "the group must wrap the libraries: %s" % argv)
    return analysistest.end(env)

elf_link_group_test = analysistest.make(_elf_link_group_test_impl)

def _index_of_suffix(argv, suffix):
    for i, arg in enumerate(argv):
        if arg.endswith(suffix):
            return i
    return -1

def _runtime_archive_order_test_impl(ctx):
    """The toolchain's `static_runtime_lib` follows the deps, in declared order."""
    env = analysistest.begin(ctx)
    action = _link_action(env)
    argv = action.argv if action else []
    inputs = [f.basename for f in action.inputs.to_list()] if action else []

    dep = max(_index_of_suffix(argv, "libmath_ops.so"), _index_of_suffix(argv, "math_ops.dll"))
    asserts.true(env, dep >= 0, "expected the shared library dep on the link line: %s" % argv)

    previous = dep
    for archive in _RUNTIME_ARCHIVES:
        index = _index_of_suffix(argv, "/" + archive)
        asserts.true(env, index > previous, "%s must follow %s on the link line: %s" % (archive, argv[previous] if previous >= 0 else "the deps", argv))
        asserts.true(env, archive in inputs, "%s must be an input of the link action" % archive)
        previous = index
    return analysistest.end(env)

runtime_archive_order_test = analysistest.make(_runtime_archive_order_test_impl)

def _shared_library_link_line_test_impl(ctx):
    """Shared libraries get the toolchain's extra args but, outside Windows, no runtime archives."""
    env = analysistest.begin(ctx)
    argv = _link_argv(env, "AdaLinkShared")

    archives = [a for a in argv if any([a.endswith("/" + r) for r in _RUNTIME_ARCHIVES])]
    asserts.equals(
        env,
        ctx.attr.expect_runtime_archives,
        len(archives) > 0,
        "runtime archives on a shared library link: %s" % argv,
    )
    if ctx.attr.expected_flag:
        asserts.true(
            env,
            ctx.attr.expected_flag in argv,
            "expected the toolchain's %s: %s" % (ctx.attr.expected_flag, argv),
        )
    return analysistest.end(env)

shared_library_link_line_test = analysistest.make(
    _shared_library_link_line_test_impl,
    attrs = {
        "expect_runtime_archives": attr.bool(doc = "Whether the link must carry the runtime archives (Windows)."),
        "expected_flag": attr.string(doc = "A flag from the toolchain's own args that must be present; empty to skip."),
    },
)

def _hermetic_defaults_test_impl(ctx):
    """Every hermetic toolchain enables `static_libgcc`; the darwin ones also pass `-nodefaultrpaths`."""
    env = analysistest.begin(ctx)
    argv = _link_argv(env, ctx.attr.mnemonic)
    asserts.true(env, "-static-libgcc" in argv, "-static-libgcc on the %s line: %s" % (ctx.attr.mnemonic, argv))
    asserts.equals(env, ctx.attr.on_macos, "-nodefaultrpaths" in argv, "-nodefaultrpaths on the %s line: %s" % (ctx.attr.mnemonic, argv))
    return analysistest.end(env)

hermetic_defaults_test = analysistest.make(
    _hermetic_defaults_test_impl,
    attrs = {
        "mnemonic": attr.string(default = "AdaLink"),
        "on_macos": attr.bool(doc = "Whether the target is built with a hermetic darwin toolchain."),
    },
)

def _staged_in(files, staging_dir):
    return [f for f in files if f.dirname.endswith("/" + staging_dir)]

def _dynamic_libgcc_test_impl(ctx):
    """A link with the `static_libgcc` feature disabled.

    No `-static-libgcc` anywhere. Where the toolchain declares a
    `dynamic_runtime_lib` (macOS) it is staged into `<output>.runtime_libs/`
    behind a relative rpath and carried in the runfiles (and default outputs
    for a shared library); elsewhere nothing is staged.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    argv = _link_argv(env, ctx.attr.mnemonic)
    staging_dir = ctx.attr.staging_dir

    # Only the hermetic darwin toolchains declare a dynamic_runtime_lib.
    stages = ctx.attr.on_macos

    asserts.false(env, "-static-libgcc" in argv, "static_libgcc is disabled for this target: %s" % argv)
    asserts.equals(env, ctx.attr.on_macos, "-nodefaultrpaths" in argv, "-nodefaultrpaths: %s" % argv)

    rpath = "-Wl,-rpath,@loader_path/" + staging_dir
    asserts.equals(env, stages, rpath in argv, "rpath %s: %s" % (rpath, argv))

    staged = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "Symlink" and _staged_in(a.outputs.to_list(), staging_dir)
    ]
    asserts.equals(env, 1 if stages else 0, len(staged), "staging actions into %s" % staging_dir)

    # Deps linked the same way stage their own copy; only count this target's.
    runfiles = _staged_in(target[DefaultInfo].default_runfiles.files.to_list(), staging_dir)
    asserts.equals(env, 1 if stages else 0, len(runfiles), "staged runtime libs in runfiles")
    if ctx.attr.in_default_outputs:
        outputs = _staged_in(target[DefaultInfo].files.to_list(), staging_dir)
        asserts.equals(env, 1 if stages else 0, len(outputs), "staged runtime libs in default outputs")
    return analysistest.end(env)

dynamic_libgcc_test = analysistest.make(
    _dynamic_libgcc_test_impl,
    attrs = {
        "in_default_outputs": attr.bool(doc = "Whether staged libs must also be default outputs (shared libraries)."),
        "mnemonic": attr.string(default = "AdaLink"),
        "on_macos": attr.bool(doc = "Whether the target is built with a hermetic darwin toolchain."),
        "staging_dir": attr.string(doc = "Directory, relative to the output, holding the staged libraries."),
    },
)

def _macos_deployment_target_test_impl(ctx):
    """On macOS the GNAT link carries the CC toolchain's deployment target.

    apple_support's `-target <arch>-apple-macosx<v>` is mirrored as a single
    `-mmacosx-version-min=<v>`; other platforms get no such flag.
    """
    env = analysistest.begin(ctx)
    argv = _link_argv(env, ctx.attr.mnemonic)
    flags = [a for a in argv if a.startswith("-mmacosx-version-min=")]
    asserts.equals(
        env,
        1 if ctx.attr.expected else 0,
        len(flags),
        "deployment target flags on the %s line: %s" % (ctx.attr.mnemonic, argv),
    )
    for flag in flags:
        asserts.true(env, flag.split("=", 1)[1] != "", "empty deployment target: %s" % flag)
    return analysistest.end(env)

macos_deployment_target_test = analysistest.make(
    _macos_deployment_target_test_impl,
    attrs = {
        "expected": attr.bool(doc = "Whether the flag must be present (macOS with an Apple CC toolchain)."),
        "mnemonic": attr.string(default = "AdaLink"),
    },
)

def shared_library_test_suite(name):
    """Instantiate the analysis tests.

    Args:
        name: Name of the test suite.
    """
    shared_dep_not_relinked_test(
        name = "shared_dep_not_relinked_test",
        target_under_test = ":main",
    )

    # Windows has no rpath.
    shared_dep_rpath_test(
        name = "shared_dep_rpath_test",
        target_under_test = ":main",
        target_compatible_with = select({
            "@platforms//os:windows": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
    )

    runtime_archive_order_test(
        name = "runtime_archive_order_test",
        target_under_test = ":main",
    )

    elf_link_group_test(
        name = "elf_link_group_test",
        target_under_test = ":main",
        target_compatible_with = select({
            "@platforms//os:linux": [],
            "//conditions:default": ["@platforms//:incompatible"],
        }),
    )

    shared_library_link_line_test(
        name = "shared_library_link_line_test",
        target_under_test = "//tests/shared_library/lib:math_ops",
        expect_runtime_archives = select({
            "@platforms//os:windows": True,
            "//conditions:default": False,
        }),
        expected_flag = select({
            "@platforms//os:linux": "-lm",
            "@platforms//os:macos": "--sysroot=__BAZEL_XCODE_SDKROOT__",
            "//conditions:default": "",
        }),
    )

    # Only the hermetic darwin toolchains pass -nodefaultrpaths and declare a
    # dynamic_runtime_lib.
    on_macos = select({
        "@platforms//os:macos": True,
        "//conditions:default": False,
    })

    hermetic_defaults_test(
        name = "binary_hermetic_defaults_test",
        target_under_test = ":main",
        on_macos = on_macos,
    )
    hermetic_defaults_test(
        name = "shared_library_hermetic_defaults_test",
        mnemonic = "AdaLinkShared",
        target_under_test = "//tests/shared_library/lib:math_ops",
        on_macos = on_macos,
    )

    dynamic_libgcc_test(
        name = "binary_dynamic_libgcc_test",
        target_under_test = ":main_dynamic_libgcc",
        staging_dir = "main_dynamic_libgcc.runtime_libs",
        on_macos = on_macos,
    )
    dynamic_libgcc_test(
        name = "shared_library_dynamic_libgcc_test",
        mnemonic = "AdaLinkShared",
        target_under_test = "//tests/shared_library/lib:math_ops_dynamic_libgcc",
        staging_dir = "libmath_ops_dynamic_libgcc.so.runtime_libs",
        in_default_outputs = True,
        on_macos = on_macos,
    )
    macos_deployment_target_test(
        name = "binary_macos_deployment_target_test",
        target_under_test = ":main",
        expected = on_macos,
    )
    macos_deployment_target_test(
        name = "shared_library_macos_deployment_target_test",
        mnemonic = "AdaLinkShared",
        target_under_test = "//tests/shared_library/lib:math_ops",
        expected = on_macos,
    )

    native.test_suite(
        name = name,
        tests = [
            ":shared_dep_not_relinked_test",
            ":shared_dep_rpath_test",
            ":runtime_archive_order_test",
            ":shared_library_link_line_test",
            ":binary_hermetic_defaults_test",
            ":shared_library_hermetic_defaults_test",
            ":binary_dynamic_libgcc_test",
            ":shared_library_dynamic_libgcc_test",
            ":elf_link_group_test",
            ":binary_macos_deployment_target_test",
            ":shared_library_macos_deployment_target_test",
        ],
    )
