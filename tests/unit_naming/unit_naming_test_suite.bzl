"""Pure Starlark unit tests for ada/private/unit_naming.bzl#collect_units."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ada:unit_naming.bzl", "collect_units")

def _f(basename, path = None):
    """File-like stand-in. collect_units only reads .basename and .path."""
    return struct(basename = basename, path = path or basename)

def _basic_pairing_test(ctx):
    env = unittest.begin(ctx)
    units, subunits = collect_units([_f("foo.ads"), _f("foo.adb")])
    asserts.equals(env, 1, len(units))
    asserts.equals(env, 0, len(subunits))
    asserts.true(env, "foo" in units)
    asserts.equals(env, "foo.ads", units["foo"].spec.basename)
    asserts.equals(env, "foo.adb", units["foo"].body.basename)
    return unittest.end(env)

basic_pairing_test = unittest.make(_basic_pairing_test)

def _spec_only_test(ctx):
    env = unittest.begin(ctx)
    units, subunits = collect_units([_f("types.ads")])
    asserts.equals(env, 1, len(units))
    asserts.equals(env, 0, len(subunits))
    asserts.equals(env, None, units["types"].body)
    return unittest.end(env)

spec_only_test = unittest.make(_spec_only_test)

def _body_only_main_test(ctx):
    env = unittest.begin(ctx)
    units, subunits = collect_units([_f("main.adb")])
    asserts.equals(env, 1, len(units))
    asserts.equals(env, 0, len(subunits))
    asserts.equals(env, None, units["main"].spec)
    asserts.equals(env, "main.adb", units["main"].body.basename)
    return unittest.end(env)

body_only_main_test = unittest.make(_body_only_main_test)

def _subunit_detection_test(ctx):
    env = unittest.begin(ctx)
    units, subunits = collect_units([
        _f("parent.ads"),
        _f("parent.adb"),
        _f("parent-child.adb"),
    ])
    asserts.equals(env, 1, len(units))
    asserts.true(env, "parent" in units)
    asserts.false(env, "parent-child" in units)
    asserts.equals(env, 1, len(subunits))
    asserts.equals(env, "parent-child.adb", subunits[0].basename)
    return unittest.end(env)

subunit_detection_test = unittest.make(_subunit_detection_test)

def _hyphenated_with_spec_is_unit_test(ctx):
    env = unittest.begin(ctx)
    units, subunits = collect_units([
        _f("a-b.ads"),
        _f("a-b.adb"),
    ])
    asserts.equals(env, 1, len(units))
    asserts.equals(env, 0, len(subunits))
    asserts.true(env, "a-b" in units)
    return unittest.end(env)

hyphenated_with_spec_is_unit_test = unittest.make(_hyphenated_with_spec_is_unit_test)

def unit_naming_test_suite(name):
    """Unit tests for collect_units().

    Args:
        name: test suite name.
    """
    basic_pairing_test(
        name = "basic_pairing_test",
    )

    spec_only_test(
        name = "spec_only_test",
    )

    body_only_main_test(
        name = "body_only_main_test",
    )

    subunit_detection_test(
        name = "subunit_detection_test",
    )

    hyphenated_with_spec_is_unit_test(
        name = "hyphenated_with_spec_is_unit_test",
    )

    native.test_suite(
        name = name,
        tests = [
            ":basic_pairing_test",
            ":spec_only_test",
            ":body_only_main_test",
            ":subunit_detection_test",
            ":hyphenated_with_spec_is_unit_test",
        ],
    )
