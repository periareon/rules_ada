"""Analysis tests for executables that depend on an `ada_shared_library`."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _link_argv(env, mnemonic = "AdaLink"):
    links = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, 1, len(links), "expected exactly one %s action" % mnemonic)
    return links[0].argv if links else []

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
    asserts.false(
        env,
        "-Wl,-rpath,@loader_path" in rpaths,
        "a bare @loader_path rpath duplicates the one GCC's Darwin driver adds",
    )
    return analysistest.end(env)

shared_dep_rpath_test = analysistest.make(_shared_dep_rpath_test_impl)

# macOS-only flags that keep a binary from depending on the output base that
# linked it (see "Linking on macOS" in docs/src/toolchains.md).
_MACOS_LINK_FLAGS = ["-static-libgcc", "-nodefaultrpaths"]

def _macos_link_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _link_argv(env, ctx.attr.mnemonic)
    for flag in _MACOS_LINK_FLAGS:
        asserts.equals(
            env,
            ctx.attr.expected,
            flag in argv,
            "%s on the %s line should be a macOS-only flag: %s" % (flag, ctx.attr.mnemonic, argv),
        )
    return analysistest.end(env)

macos_link_flags_test = analysistest.make(
    _macos_link_flags_test_impl,
    attrs = {
        "expected": attr.bool(doc = "Whether the macOS link flags must be present."),
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

    on_macos = select({
        "@platforms//os:macos": True,
        "//conditions:default": False,
    })
    macos_link_flags_test(
        name = "binary_macos_link_flags_test",
        target_under_test = ":main",
        expected = on_macos,
    )
    macos_link_flags_test(
        name = "shared_library_macos_link_flags_test",
        mnemonic = "AdaLinkShared",
        target_under_test = "//tests/shared_library/lib:math_ops",
        expected = on_macos,
    )

    native.test_suite(
        name = name,
        tests = [
            ":shared_dep_not_relinked_test",
            ":shared_dep_rpath_test",
            ":binary_macos_link_flags_test",
            ":shared_library_macos_link_flags_test",
        ],
    )
