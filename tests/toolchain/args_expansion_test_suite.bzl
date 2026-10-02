"""Unit tests for the `ada_args` template expansion."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//ada/private:args_expansion.bzl", "expand_args", "parse_arg", "types", "validate_args")

# buildifier: disable=bzl-visibility
load("//ada/private:toolchain_config.bzl", "AdaArgsInfo", "AdaNestedArgsInfo")

def _node(args = [], nested = [], iterate_over = None, requires_true = None, requires_false = None, requires_not_none = None, requires_none = None):
    return AdaNestedArgsInfo(
        args = tuple(args),
        files = depset(),
        iterate_over = iterate_over,
        label = Label("//tests/toolchain:fake"),
        nested = tuple(nested),
        requires_false = requires_false,
        requires_none = requires_none,
        requires_not_none = requires_not_none,
        requires_true = requires_true,
    )

def _args(actions, **kwargs):
    nested = _node(**kwargs)
    return AdaArgsInfo(actions = tuple(actions), files = depset(), label = nested.label, nested = nested)

def _file(path):
    return struct(path = path)

def _recorder():
    """A `fail` stand-in that records messages instead of aborting."""
    errors = []

    def record(message):
        errors.append(message)

    return struct(errors = errors, fail = record)

def _parse_test_impl(ctx):
    env = unittest.begin(ctx)
    segments = parse_arg("-Wl,-rpath,{origin}/{dir}")
    asserts.equals(env, ["-Wl,-rpath,", "origin", "/", "dir"], [getattr(s, "literal", None) or s.variable for s in segments])
    asserts.equals(env, [struct(literal = "{x}")], parse_arg("{{x}}"))
    asserts.equals(env, [struct(variable = "a.b")], parse_arg("{a.b}"))

    rec = _recorder()
    parse_arg("{unclosed", rec.fail)
    parse_arg("stray}", rec.fail)
    parse_arg("{}", rec.fail)
    asserts.equals(env, 3, len(rec.errors), rec.errors)
    return unittest.end(env)

parse_test = unittest.make(_parse_test_impl)

def _expansion_test_impl(ctx):
    env = unittest.begin(ctx)
    variables = {
        "flags": ["-a", "-b"],
        "label": "x",
        "none": None,
        "objects": [_file("a.o"), _file("b.o")],
        "output": _file("bin/main"),
        "truth": True,
    }
    infos = [
        _args(["link_executable"], args = ["{objects}"]),
        _args(["link_shared_library"], args = ["-shared"]),
        _args(["link_executable"], args = ["-o", "{output}", "--name={label}-{label}"]),
        _args(["link_executable"], args = ["{flags}"], requires_not_none = "flags"),
        _args(["link_executable"], args = ["--never"], requires_not_none = "none"),
        _args(["link_executable"], args = ["--empty"], requires_none = "none"),
        _args(["link_executable"], args = ["--yes"], requires_true = "truth"),
        _args(["link_executable"], args = ["--no"], requires_false = "truth"),
    ]
    asserts.equals(
        env,
        ["a.o", "b.o", "-o", "bin/main", "--name=x-x", "-a", "-b", "--empty", "--yes"],
        expand_args(infos, "link_executable", variables),
    )
    asserts.equals(env, ["-shared"], expand_args(infos, "link_shared_library", variables))

    # Empty lists count as unset for requires_not_none and expand to nothing.
    asserts.equals(env, [], expand_args([_args(["compile"], args = ["{flags}"], requires_not_none = "flags")], "compile", {"flags": []}))
    asserts.equals(env, [], expand_args([_args(["compile"], args = ["{flags}"])], "compile", {"flags": []}))
    return unittest.end(env)

expansion_test = unittest.make(_expansion_test_impl)

def _iteration_test_impl(ctx):
    env = unittest.begin(ctx)
    libraries = [
        struct(file = _file("liba.a"), whole_archive = True),
        struct(file = _file("libb.so"), whole_archive = False),
        struct(file = _file("libc.a"), whole_archive = True),
    ]
    wrap = _args(
        ["link_executable"],
        iterate_over = "libraries_to_link",
        nested = [
            _node(args = ["-Wl,--whole-archive"], requires_true = "libraries_to_link.whole_archive"),
            _node(args = ["{libraries_to_link.file}"]),
            _node(args = ["-Wl,--no-whole-archive"], requires_true = "libraries_to_link.whole_archive"),
        ],
    )
    asserts.equals(
        env,
        [
            "-Wl,--whole-archive",
            "liba.a",
            "-Wl,--no-whole-archive",
            "libb.so",
            "-Wl,--whole-archive",
            "libc.a",
            "-Wl,--no-whole-archive",
        ],
        expand_args([wrap], "link_executable", {"libraries_to_link": libraries}),
    )

    rpaths = _args(["link_executable"], args = ["-Wl,-rpath,$ORIGIN/{dirs}"], iterate_over = "dirs")
    asserts.equals(
        env,
        ["-Wl,-rpath,$ORIGIN/lib", "-Wl,-rpath,$ORIGIN/."],
        expand_args([rpaths], "link_executable", {"dirs": ["lib", "."]}),
    )
    asserts.equals(env, [], expand_args([rpaths], "link_executable", {"dirs": None}))
    return unittest.end(env)

iteration_test = unittest.make(_iteration_test_impl)

def _expansion_errors_test_impl(ctx):
    env = unittest.begin(ctx)
    variables = {"flags": ["-a"], "label": "x", "none": None, "truth": True}
    cases = {
        "interpolated list": _args(["compile"], args = ["--flags={flags}"]),
        "iterate over scalar": _args(["compile"], args = ["{label}"], iterate_over = "label"),
        "requires_true on string": _args(["compile"], args = ["x"], requires_true = "label"),
        "unknown field": _args(["compile"], args = ["{label.nope}"]),
        "unknown variable": _args(["compile"], args = ["{missing}"]),
        "unset without guard": _args(["compile"], args = ["{none}"]),
    }
    for name, info in cases.items():
        rec = _recorder()
        expand_args([info], "compile", variables, rec.fail)
        asserts.true(env, len(rec.errors) > 0, "expected an error for %s" % name)
    return unittest.end(env)

expansion_errors_test = unittest.make(_expansion_errors_test_impl)

def _validation_test_impl(ctx):
    env = unittest.begin(ctx)
    link = {
        "libraries_to_link": types.list(types.struct(file = types.file, whole_archive = types.bool)),
        "objects": types.list(types.file),
        "output": types.file,
        "target": types.option(types.string),
    }
    tables = {"compile": {}, "link_executable": link}

    good = [
        _args(["link_executable"], args = ["-o", "{output}", "{objects}"]),
        _args(["link_executable"], args = ["-min={target}"], requires_not_none = "target"),
        _args(
            ["link_executable"],
            iterate_over = "libraries_to_link",
            nested = [_node(args = ["{libraries_to_link.file}"], requires_true = "libraries_to_link.whole_archive")],
        ),
        _args(["compile"], args = ["-O2"]),
    ]
    for info in good:
        rec = _recorder()
        validate_args(info, tables, rec.fail)
        asserts.equals(env, [], rec.errors)

    bad = {
        "bool rendered": _args(["link_executable"], args = ["{libraries_to_link}"], iterate_over = "libraries_to_link", nested = [_node(args = ["{libraries_to_link.whole_archive}"])]),
        "iterate scalar": _args(["link_executable"], args = ["{output}"], iterate_over = "output"),
        "list in string": _args(["link_executable"], args = ["--objs={objects}"]),
        "requires_not_none on file": _args(["link_executable"], args = ["x"], requires_not_none = "output"),
        "requires_true on file": _args(["link_executable"], args = ["x"], requires_true = "output"),
        "unknown action": _args(["assemble"], args = ["x"]),
        "unknown field": _args(["link_executable"], args = ["{output.nope}"]),
        "variable in compile": _args(["compile"], args = ["{output}"]),
    }
    for name, info in bad.items():
        rec = _recorder()
        validate_args(info, tables, rec.fail)
        asserts.true(env, len(rec.errors) > 0, "expected a validation error for %s" % name)
    return unittest.end(env)

validation_test = unittest.make(_validation_test_impl)

def args_expansion_test_suite(name):
    """Instantiate the unit tests.

    Args:
        name: Name of the test suite.
    """
    unittest.suite(
        name,
        parse_test,
        expansion_test,
        iteration_test,
        expansion_errors_test,
        validation_test,
    )
