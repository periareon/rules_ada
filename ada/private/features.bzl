"""Feature names understood by the Ada rules.

Features follow the `cc_*` rules' conventions: a toolchain enables some by
default (`ada_toolchain.enabled_features`), a target adds or removes them
through the common `features` attribute (`features = ["-static_libgcc"]`),
and `--features` applies to every target. A toolchain's `known_features`
give the arguments of each name; the rules themselves only interpret
`static_libgcc`, and forward the whole set to the CC toolchain.
"""

# The one feature the rules read themselves: while it is disabled the
# toolchain's `dynamic_runtime_lib` is staged beside each linked output. Its
# arguments (`-static-libgcc`) come from the `ada_feature` target
# `@rules_ada//ada/toolchains/features:static_libgcc` like any other feature.
STATIC_LIBGCC = "static_libgcc"

# Linking mode of an executable or shared library, derived like `cc_binary`
# does from `linkstatic` and `--dynamic_mode`. Requested for forward
# compatibility and forwarded to the CC toolchain; no Ada link flag depends
# on them yet because the hermetic GNAT runtime is static only.
STATIC_LINKING_MODE = "static_linking_mode"
DYNAMIC_LINKING_MODE = "dynamic_linking_mode"

def _linking_mode(ctx, linkstatic):
    """The linking-mode feature for a link, mirroring `cc_binary`.

    Args:
        ctx: rule context with the `cpp` fragment.
        linkstatic: bool, the target's `linkstatic` (True for shared
            libraries, like `cc_binary(linkshared = True)`).

    Returns:
        str: `static_linking_mode` or `dynamic_linking_mode`.
    """
    dynamic_mode = ctx.fragments.cpp.dynamic_mode()
    if dynamic_mode == "FULLY":
        return DYNAMIC_LINKING_MODE
    if dynamic_mode == "OFF" or linkstatic:
        return STATIC_LINKING_MODE
    return DYNAMIC_LINKING_MODE

def _link_features(ctx, ada_toolchain, linking_mode):
    """Enabled feature names for one link action.

    Toolchain defaults come first, then the target's effective `features`
    (package, target and `--features`; Bazel has already split `-name`
    entries into `ctx.disabled_features`), then the linking mode. Disabled
    names win.

    Args:
        ctx: rule context.
        ada_toolchain: AdaToolchainInfo provider.
        linking_mode: str from `linking_mode()`.

    Returns:
        list[str]: enabled feature names, in order of first mention.
    """
    enabled = {}
    for name in [f.name for f in ada_toolchain.enabled_features] + list(ctx.features) + [linking_mode]:
        enabled[name] = True
    for name in ctx.disabled_features:
        enabled.pop(name, None)
    return enabled.keys()

def _feature_args(ada_toolchain, features):
    """Arguments of the enabled features, in `known_features` order.

    Args:
        ada_toolchain: AdaToolchainInfo provider.
        features: list[str] enabled feature names.

    Returns:
        list[AdaArgsInfo]: to expand after the toolchain's own `args`.
    """
    return [
        info
        for feature in ada_toolchain.known_features
        if feature.name in features
        for info in feature.args.args
    ]

def _feature_files(ada_toolchain, features):
    """Files referenced by the arguments of the enabled features."""
    return depset(transitive = [
        feature.args.files
        for feature in ada_toolchain.known_features
        if feature.name in features
    ])

ada_features = struct(
    linking_mode = _linking_mode,
    link_features = _link_features,
    feature_args = _feature_args,
    feature_files = _feature_files,
)
