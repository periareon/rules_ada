"""Ada toolchain rules."""

load(":providers.bzl", "AdaToolchainInfo")
load(
    ":toolchain_config.bzl",
    "ARTIFACT_CATEGORIES",
    "AdaArgsListInfo",
    "AdaFeatureInfo",
    "DEFAULT_ARTIFACT_NAME_PATTERNS",
)

TOOLCHAIN_TYPE = str(Label("//ada:toolchain_type"))

def _ada_toolchain_impl(ctx):
    make_variable_info = platform_common.TemplateVariableInfo({
        "ADA": ctx.file.compiler.path,
        "GNATBIND": ctx.file.binder.path,
    })

    known_features = tuple([t[AdaFeatureInfo] for t in ctx.attr.known_features])
    known_labels = [f.label for f in known_features]
    seen = {}
    for feature in known_features:
        if feature.name in seen:
            fail("{}: known_features declares feature `{}` twice ({} and {})".format(
                ctx.label,
                feature.name,
                seen[feature.name],
                feature.label,
            ))
        seen[feature.name] = feature.label
    enabled_features = tuple([t[AdaFeatureInfo] for t in ctx.attr.enabled_features])
    for feature in enabled_features:
        if feature.label not in known_labels:
            fail("{}: enabled feature {} must also be listed in known_features".format(ctx.label, feature.label))

    artifact_name_patterns = dict(DEFAULT_ARTIFACT_NAME_PATTERNS)
    for category, pattern in ctx.attr.artifact_name_patterns.items():
        if category not in ARTIFACT_CATEGORIES:
            fail("{}: unknown artifact_name_patterns category `{}` (expected one of {})".format(
                ctx.label,
                category,
                ", ".join(ARTIFACT_CATEGORIES),
            ))
        if "%{name}" not in pattern:
            fail("{}: artifact_name_patterns[{}] = `{}` must contain `%{{name}}`".format(ctx.label, category, pattern))
        artifact_name_patterns[category] = pattern

    ada_toolchain_info = AdaToolchainInfo(
        label = ctx.label,
        compiler_id = ctx.attr.compiler_id,
        compiler = ctx.file.compiler,
        binder = ctx.file.binder,
        ar = ctx.file.ar,
        gcov = ctx.file.gcov,
        compile_flags = ctx.attr.compile_flags,
        bind_flags = ctx.attr.bind_flags,
        ada_std = ctx.attr.ada_std.files if ctx.attr.ada_std else depset(),
        compiler_lib = ctx.attr.compiler_lib.files if ctx.attr.compiler_lib else depset(),
        static_runtime_lib = ctx.files.static_runtime_lib,
        dynamic_runtime_lib = ctx.files.dynamic_runtime_lib,
        args = tuple([a for t in ctx.attr.args for a in t[AdaArgsListInfo].args]),
        args_files = depset(transitive = [t[AdaArgsListInfo].files for t in ctx.attr.args]),
        known_features = known_features,
        enabled_features = enabled_features,
        artifact_name_patterns = artifact_name_patterns,
        process_wrapper = ctx.executable._process_wrapper,
        target_triple = ctx.attr.target_triple,
    )

    return [
        platform_common.ToolchainInfo(
            ada_toolchain = ada_toolchain_info,
        ),
        ada_toolchain_info,
        make_variable_info,
    ]

ada_toolchain = rule(
    doc = """\
Defines an Ada toolchain: the GNAT compiler (gcc), binder (gnatbind) and
archiver (ar), the runtime libraries, and the arguments every action is
built from.

The hermetic-gnat toolchains shipped with `rules_ada` are created and
registered by its module extension; this rule is only needed to define a custom
toolchain around a GNAT installation that `rules_ada` does not ship.

How the toolchain builds its command lines is declared with
[`ada_args`](./ada_args.md) targets listed in `args`; `rules_ada` ships
complete link lines per platform family under
`@rules_ada//ada/toolchains/args/...` that can be reused, extended or
replaced. The GNAT runtime archives are listed in `static_runtime_lib`,
tasking runtime first:

```python
load("@rules_ada//ada:ada_toolchain.bzl", "ada_toolchain")
load("@rules_ada//ada/toolchains:defs.bzl", "LINK_ACTIONS", "ada_args")

ada_args(
    name = "system_libs",
    actions = LINK_ACTIONS,
    args = ["-lm", "-lpthread", "-ldl", "-lrt"],
)

ada_toolchain(
    name = "gnat_toolchain",
    compiler = "@gnat//:bin/gcc",
    binder = "@gnat//:bin/gnatbind",
    ar = "@gnat//:bin/ar",
    ada_std = "@gnat//:ada_std",
    compiler_lib = "@gnat//:compiler_lib",
    gcov = "@gnat//:bin/gcov",
    compile_flags = ["-O2"],
    static_runtime_lib = [
        "@gnat//:lib/gcc/x86_64-pc-linux-gnu/16.1.0/adalib/libgnarl.a",
        "@gnat//:lib/gcc/x86_64-pc-linux-gnu/16.1.0/adalib/libgnat.a",
        "@gnat//:lib/gcc/x86_64-pc-linux-gnu/16.1.0/libgcc.a",
    ],
    args = [
        "@rules_ada//ada/toolchains/args/elf:link_line",
        ":system_libs",
    ],
    known_features = ["@rules_ada//ada/toolchains/features:static_libgcc"],
    target_triple = "x86_64-pc-linux-gnu",
)
```

See the toolchains documentation for the variables available to `ada_args`,
the shipped link lines, features and `dynamic_runtime_lib`.
""",
    implementation = _ada_toolchain_impl,
    attrs = {
        "ada_std": attr.label(
            doc = "The Ada standard library (`adalib` and `adainclude`).",
            cfg = "target",
        ),
        "ar": attr.label(
            doc = "The archiver executable (`ar` or `gcc-ar`). If not set, the CC toolchain's archiver is used.",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "args": attr.label_list(
            doc = "`ada_args` and `ada_args_list` targets expanded, in this order, into every action " +
                  "they apply to. A link line is built entirely from these; see " +
                  "`@rules_ada//ada/toolchains/args/...` for the shipped ones.",
            providers = [AdaArgsListInfo],
        ),
        "artifact_name_patterns": attr.string_dict(
            doc = "Output file name per category with `%{name}` standing for the target name. " +
                  "Categories: `executable` (default `%{name}`), `shared_library` (`lib%{name}.so`), " +
                  "`static_library` (`lib%{name}.a`).",
        ),
        "bind_flags": attr.string_list(
            doc = "Additional flags for `gnatbind`.",
        ),
        "binder": attr.label(
            doc = "The `gnatbind` executable for elaboration ordering and consistency checking.",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "compile_flags": attr.string_list(
            doc = "Additional compiler flags for Ada compilation.",
        ),
        "compiler": attr.label(
            doc = "The Ada compiler executable (gcc with GNAT support).",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "compiler_id": attr.string(
            default = "gnat",
            doc = "Identifier for the Ada compiler. Currently only 'gnat' is supported.",
        ),
        "compiler_lib": attr.label(
            doc = "GCC support files (backends, shared libs, runtime libs like `libgcc.a`, `libatomic.a`).",
            cfg = "exec",
        ),
        "dynamic_runtime_lib": attr.label_list(
            doc = "Shared runtime libraries the compiler driver links implicitly when the `static_libgcc` " +
                  "feature is disabled (e.g. macOS `libgcc_s.1.1.dylib`). They are staged next to each " +
                  "linked output with a relative rpath and carried in its runfiles. Leave empty where the " +
                  "system provides them, as on Linux.",
            allow_files = True,
        ),
        "enabled_features": attr.label_list(
            doc = "`ada_feature` targets on by default for every target using this toolchain; each must " +
                  "also be in `known_features`. A target turns one off with `features = [\"-name\"]`.",
            providers = [AdaFeatureInfo],
        ),
        "gcov": attr.label(
            doc = "The gcov executable for coverage support.",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "known_features": attr.label_list(
            doc = "`ada_feature` targets the toolchain understands. The arguments of enabled ones are " +
                  "emitted after `args`, in this order. `@rules_ada//ada/toolchains/features:static_libgcc` " +
                  "is the one the rules themselves know.",
            providers = [AdaFeatureInfo],
        ),
        "static_runtime_lib": attr.label_list(
            doc = "Runtime archives linked, in this order, after the dependency libraries into every " +
                  "executable and (on Windows) shared library: `libgnarl.a` first, then `libgnat.a`, " +
                  "`libgcc.a`, and `libatomic.a` where needed. GNU ld scans archives once, so the order matters.",
            allow_files = True,
        ),
        "target_triple": attr.string(
            doc = "GCC target triple (e.g., 'aarch64-apple-darwin24.6.0', 'x86_64-pc-linux-gnu').",
        ),
        "_process_wrapper": attr.label(
            default = Label("//ada/private/process_wrapper"),
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
)

def _ada_toolchain_alias_impl(ctx):
    toolchain_info = ctx.toolchains[TOOLCHAIN_TYPE]
    ada_toolchain = toolchain_info.ada_toolchain
    return [toolchain_info, ada_toolchain]

ada_toolchain_alias = rule(
    doc = "Provides access to the currently selected Ada toolchain.",
    implementation = _ada_toolchain_alias_impl,
    toolchains = [TOOLCHAIN_TYPE],
)
