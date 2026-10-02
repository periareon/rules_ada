"""Rules and providers that describe how an Ada toolchain builds command lines.

Modelled on rules_cc's `cc_args` / `cc_nested_args` / `cc_args_list` /
`cc_feature`: an `ada_toolchain` lists `ada_args` targets whose templates are
expanded with per-action variables, and `ada_feature` targets bundle args
that a toolchain or a target can switch on or off by name.
"""

load(":actions.bzl", "ACTIONS")
load(":args_expansion.bzl", "types", "validate_args")

AdaNestedArgsInfo = provider(
    doc = "One node of an `ada_args` template tree.",
    fields = {
        "args": "tuple[str]: argument templates emitted when the conditions hold.",
        "files": "depset[File]: files referenced by `data` here and below.",
        "iterate_over": "str or None: list variable to expand the node once per element.",
        "label": "Label: the defining target.",
        "nested": "tuple[AdaNestedArgsInfo]: child nodes, expanded after `args`.",
        "requires_false": "str or None: bool variable that must be False.",
        "requires_none": "str or None: variable that must be unset or empty.",
        "requires_not_none": "str or None: variable that must be set and non-empty.",
        "requires_true": "str or None: bool variable that must be True.",
    },
)

AdaArgsInfo = provider(
    doc = "Arguments an Ada toolchain adds to some actions.",
    fields = {
        "actions": "tuple[str]: action names this applies to (see actions.bzl).",
        "files": "depset[File]: files the arguments reference.",
        "label": "Label: the defining target.",
        "nested": "AdaNestedArgsInfo: the template tree.",
    },
)

AdaArgsListInfo = provider(
    doc = "An ordered collection of `AdaArgsInfo`.",
    fields = {
        "args": "tuple[AdaArgsInfo]: in command-line order.",
        "files": "depset[File]: union of the members' files.",
        "label": "Label: the defining target.",
    },
)

AdaFeatureInfo = provider(
    doc = "A named, toggleable set of arguments.",
    fields = {
        "args": "AdaArgsListInfo: arguments emitted while the feature is enabled.",
        "label": "Label: the defining target.",
        "name": "str: the feature name used in `features` attributes and `--features`.",
    },
)

_LIBRARY_TO_LINK = types.struct(
    file = types.file,
    whole_archive = types.bool,
    dynamic = types.bool,
)

# Variables the rules provide to the link actions, by name.
LINK_VARIABLES = {
    "coverage_link_flags": types.list(types.string),
    "dep_link_flags": types.list(types.string),
    "libraries_to_link": types.list(_LIBRARY_TO_LINK),
    "macos_deployment_target": types.option(types.string),
    "objects": types.list(types.file),
    "output": types.file,
    "output_basename": types.string,
    "runtime_libraries": types.list(types.file),
    "runtime_library_search_directories": types.list(types.string),
    "user_link_flags": types.list(types.string),
}

# Variables available per action. Compile, bind and archive accept literal
# arguments only.
ACTION_VARIABLES = {
    ACTIONS.archive: {},
    ACTIONS.bind: {},
    ACTIONS.compile: {},
    ACTIONS.link_executable: LINK_VARIABLES,
    ACTIONS.link_shared_library: LINK_VARIABLES,
}

ARTIFACT_CATEGORIES = ("executable", "shared_library", "static_library")

DEFAULT_ARTIFACT_NAME_PATTERNS = {
    "executable": "%{name}",
    "shared_library": "lib%{name}.so",
    "static_library": "lib%{name}.a",
}

def artifact_name(patterns, category, name):
    """File name of an output according to a toolchain's name patterns.

    Args:
        patterns: dict[str, str] as stored in `AdaToolchainInfo`.
        category: one of `ARTIFACT_CATEGORIES`.
        name: str, the target name.

    Returns:
        str: the package-relative output file name.
    """
    return patterns[category].replace("%{name}", name)

_REQUIRES = ("requires_true", "requires_false", "requires_not_none", "requires_none")

_NESTED_ARGS_ATTRS = {
    "args": attr.string_list(
        doc = "Argument templates. `{name}` and `{name.field}` expand variables of the action; " +
              "an argument that is exactly `{name}` for a list variable expands to one argument " +
              "per element. `{{` and `}}` are literal braces. Mutually exclusive with `nested`.",
    ),
    "data": attr.label_list(
        doc = "Files the arguments refer to; added as inputs of every action the arguments apply to.",
        allow_files = True,
    ),
    "iterate_over": attr.string(
        doc = "A list variable; the node is expanded once per element, with the element bound " +
              "to the same name.",
    ),
    "nested": attr.label_list(
        doc = "`ada_nested_args` expanded in order after `args`, for per-element conditions.",
        providers = [AdaNestedArgsInfo],
    ),
    "requires_false": attr.string(doc = "Expand only if this bool variable is False."),
    "requires_none": attr.string(doc = "Expand only if this variable is unset or an empty list."),
    "requires_not_none": attr.string(doc = "Expand only if this variable is set and, for lists, non-empty."),
    "requires_true": attr.string(doc = "Expand only if this bool variable is True."),
}

def _nested_args_info(ctx):
    requires = [name for name in _REQUIRES if getattr(ctx.attr, name)]
    if len(requires) > 1:
        fail("%s: only one of %s may be set" % (ctx.label, ", ".join(_REQUIRES)))
    if ctx.attr.args and ctx.attr.nested:
        fail("%s: `args` and `nested` are mutually exclusive; put the arguments in their own node" % ctx.label)
    nested = tuple([n[AdaNestedArgsInfo] for n in ctx.attr.nested])
    return AdaNestedArgsInfo(
        args = tuple(ctx.attr.args),
        files = depset(ctx.files.data, transitive = [n.files for n in nested]),
        iterate_over = ctx.attr.iterate_over or None,
        label = ctx.label,
        nested = nested,
        requires_false = ctx.attr.requires_false or None,
        requires_none = ctx.attr.requires_none or None,
        requires_not_none = ctx.attr.requires_not_none or None,
        requires_true = ctx.attr.requires_true or None,
    )

def _ada_nested_args_impl(ctx):
    return [_nested_args_info(ctx)]

ada_nested_args = rule(
    doc = """\
A node inside an [`ada_args`](./ada_args.md) template tree.

Nested args exist for conditions that must be evaluated per element of an
iterated list, such as wrapping only `alwayslink` libraries:

```python
ada_args(
    name = "libraries_to_link",
    actions = LINK_ACTIONS,
    iterate_over = "libraries_to_link",
    nested = [":whole_archive_library", ":plain_library"],
)

ada_nested_args(
    name = "whole_archive_library",
    args = ["-Wl,-force_load,{libraries_to_link.file}"],
    requires_true = "libraries_to_link.whole_archive",
)

ada_nested_args(
    name = "plain_library",
    args = ["{libraries_to_link.file}"],
    requires_false = "libraries_to_link.whole_archive",
)
```
""",
    implementation = _ada_nested_args_impl,
    attrs = _NESTED_ARGS_ATTRS,
    provides = [AdaNestedArgsInfo],
)

def _ada_args_impl(ctx):
    if not ctx.attr.actions:
        fail("%s: `actions` must name at least one action" % ctx.label)
    nested = _nested_args_info(ctx)
    info = AdaArgsInfo(
        actions = tuple(ctx.attr.actions),
        files = nested.files,
        label = ctx.label,
        nested = nested,
    )
    validate_args(info, ACTION_VARIABLES)
    return [
        info,
        AdaArgsListInfo(args = (info,), files = info.files, label = ctx.label),
    ]

ada_args = rule(
    doc = """\
Arguments an Ada toolchain passes to some of its actions.

Templates expand variables of the action (`{output}`, `{objects}`, ...) and
can be conditional on them; the toolchains documentation lists the variables
of each action. Order matters: an `ada_toolchain` emits its `args` in the
order given, after the tool and before the arguments of enabled features.

```python
load("@rules_ada//ada/toolchains:defs.bzl", "LINK_ACTIONS", "ada_args")

ada_args(
    name = "soname",
    actions = ["link_shared_library"],
    args = ["-Wl,-soname,{output_basename}"],
)

ada_args(
    name = "rpaths",
    actions = LINK_ACTIONS,
    args = ["-Wl,-rpath,$ORIGIN/{runtime_library_search_directories}"],
    iterate_over = "runtime_library_search_directories",
)
```

An `ada_args` target can be listed directly in `ada_toolchain.args` or
bundled with [`ada_args_list`](./ada_args_list.md).
""",
    implementation = _ada_args_impl,
    attrs = _NESTED_ARGS_ATTRS | {
        "actions": attr.string_list(
            doc = "Actions the arguments apply to: `compile`, `bind`, `archive`, " +
                  "`link_executable`, `link_shared_library`.",
            mandatory = True,
        ),
    },
    provides = [AdaArgsInfo, AdaArgsListInfo],
)

def _collect_args(targets):
    args = tuple([a for t in targets for a in t[AdaArgsListInfo].args])
    files = depset(transitive = [t[AdaArgsListInfo].files for t in targets])
    return args, files

def _ada_args_list_impl(ctx):
    args, files = _collect_args(ctx.attr.args)
    return [AdaArgsListInfo(args = args, files = files, label = ctx.label)]

ada_args_list = rule(
    doc = """\
An ordered bundle of [`ada_args`](./ada_args.md) (or other lists).

The default link lines shipped under `@rules_ada//ada/toolchains/args/...`
are `ada_args_list` targets; a custom toolchain can list one of them next to
its own `ada_args`.
""",
    implementation = _ada_args_list_impl,
    attrs = {
        "args": attr.label_list(
            doc = "`ada_args` and `ada_args_list` targets, in command-line order.",
            providers = [AdaArgsListInfo],
        ),
    },
    provides = [AdaArgsListInfo],
)

def _ada_feature_impl(ctx):
    name = ctx.attr.feature_name
    if not name or "-" in name or " " in name:
        fail("%s: `feature_name` must be a non-empty name without `-` or spaces (`-name` is how a target disables a feature)" % ctx.label)
    args, files = _collect_args(ctx.attr.args)
    return [AdaFeatureInfo(
        args = AdaArgsListInfo(args = args, files = files, label = ctx.label),
        label = ctx.label,
        name = name,
    )]

ada_feature = rule(
    doc = """\
A named set of arguments that can be toggled per target.

A toolchain lists the features it understands in `known_features` and the
ones on by default in `enabled_features`. Targets add or remove them with
the common `features` attribute (`features = ["-static_libgcc"]`), and
`--features` applies globally. The arguments of enabled features are emitted
after the toolchain's own `args`, in `known_features` order.

```python
ada_feature(
    name = "static_libgcc",
    feature_name = "static_libgcc",
    args = [":static_libgcc_flags"],
)
```
""",
    implementation = _ada_feature_impl,
    attrs = {
        "args": attr.label_list(
            doc = "`ada_args` emitted while the feature is enabled.",
            providers = [AdaArgsListInfo],
        ),
        "feature_name": attr.string(
            doc = "The name used in `features` attributes and `--features`.",
            mandatory = True,
        ),
    },
    provides = [AdaFeatureInfo],
)
