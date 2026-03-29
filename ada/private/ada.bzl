"""Ada rules."""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(":common.bzl", "ada_common")
load(":providers.bzl", "AdaInfo")
load(":toolchain.bzl", "TOOLCHAIN_TYPE")

_SRC_EXTENSIONS = [".ads", ".adb"]

_CC_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:toolchain_type"

def _cc_coverage_link_flags(ctx):
    """Derive LLVM profile runtime link flags from the CC toolchain.

    On macOS, C dependencies compiled by Apple clang get LLVM profile
    instrumentation during coverage builds. The GNAT gcc linker needs
    the LLVM profile runtime library to resolve those symbols.

    This derives the library path from the CC toolchain's built-in
    include directories (already discovered by rules_cc's cc_configure
    extension) rather than executing any commands.
    """
    cc_toolchain_info = ctx.toolchains[_CC_TOOLCHAIN_TYPE]
    if not cc_toolchain_info or not hasattr(cc_toolchain_info, "cc"):
        return []
    cc_toolchain = cc_toolchain_info.cc
    if cc_toolchain.compiler != "clang":
        return []
    for d in cc_toolchain.built_in_include_directories:
        if "/lib/clang/" in d and d.endswith("/include"):
            return [d.removesuffix("/include") + "/lib/darwin/libclang_rt.profile_osx.a"]
    return []

def _create_instrumented_files_info(ctx, metadata_files = []):
    """Create an InstrumentedFilesInfo provider for code coverage support."""
    source_files = [f for f in ctx.files.srcs if f.extension in ("ads", "adb")]
    return coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs"],
        dependency_attributes = ["deps", "data"],
        extensions = [ext.lstrip(".") for ext in _SRC_EXTENSIONS],
        metadata_files = source_files + metadata_files,
    )

_COMMON_ATTRS = {
    "compile_data": attr.label_list(
        doc = "Additional Ada source files needed during compilation but not compiled " +
              "independently (e.g., subunit bodies referenced via 'separate').",
        allow_files = _SRC_EXTENSIONS,
    ),
    "copts": attr.string_list(
        doc = "Additional compiler flags for Ada compilation (e.g., -gnatwa, -O2).",
    ),
    "data": attr.label_list(
        doc = "Additional files needed at runtime.",
        allow_files = True,
    ),
    "deps": attr.label_list(
        doc = "Dependencies. Can be Ada targets (AdaInfo) or C/C++ targets (CcInfo).",
        providers = [
            [CcInfo],
            [AdaInfo],
        ],
    ),
    "linkopts": attr.string_list(
        doc = "Additional linker flags.",
    ),
    "srcs": attr.label_list(
        doc = "Ada source files (.ads specs and .adb bodies).",
        allow_files = _SRC_EXTENSIONS,
    ),
}

def _collect_deps(deps):
    """Extract dependency info from a list of dep targets.

    Returns a struct with ali_files, sources, linking_contexts, and
    compilation_contexts collected from AdaInfo and CcInfo providers.
    """
    dep_ali_files = []
    dep_sources = []
    linking_contexts = []
    compilation_contexts = []
    for dep in deps:
        if AdaInfo in dep:
            info = dep[AdaInfo]
            dep_ali_files.append(info.ali_files)
            dep_sources.append(info.transitive_sources)
            linking_contexts.append(info.cc_info.linking_context)
            compilation_contexts.append(info.cc_info.compilation_context)
        elif CcInfo in dep:
            linking_contexts.append(dep[CcInfo].linking_context)
            compilation_contexts.append(dep[CcInfo].compilation_context)
    return struct(
        ali_files = dep_ali_files,
        sources = dep_sources,
        linking_contexts = linking_contexts,
        compilation_contexts = compilation_contexts,
    )

def _build_runfiles(ctx):
    """Merge runfiles from data deps and library deps."""
    runfiles = ctx.runfiles()
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(ctx.runfiles(transitive_files = data_dep[DefaultInfo].files))
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)
    for dep in ctx.attr.deps:
        if DefaultInfo in dep:
            runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    return runfiles

# --------------------------------------------------------------------------- #
# ada_static_library
# --------------------------------------------------------------------------- #

def _ada_static_library_impl(ctx):
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)

    result = ada_common.compile(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        srcs = ctx.files.srcs,
        dep_sources = dep_info.sources,
        compile_data = ctx.files.compile_data,
        compile_flags = ctx.attr.copts,
        coverage_enabled = ctx.configuration.coverage_enabled,
        name = ctx.label.name,
    )

    has_objects = len(result.objects) > 0

    if has_objects:
        archive = ada_common.archive(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            objects = result.objects,
            name = ctx.label.name,
        )

        linker_input = ada_common.create_linker_input(
            owner = ctx.label,
            user_link_flags = depset([archive.path]),
            additional_inputs = depset([archive]),
        )
        own_linking_context = ada_common.create_linking_context(
            linker_inputs = depset([linker_input]),
        )

        merged_linking_context = ada_common.merge_linking_contexts(
            linking_contexts = [own_linking_context] + dep_info.linking_contexts,
        )
        files = [archive]
    else:
        merged_linking_context = ada_common.merge_linking_contexts(
            linking_contexts = dep_info.linking_contexts,
        )
        files = []

    cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(),
        linking_context = merged_linking_context,
    )

    ada_info = AdaInfo(
        cc_info = cc_info,
        ali_files = depset(
            direct = result.ali_files,
            transitive = dep_info.ali_files,
        ),
        transitive_sources = depset(
            direct = result.source_files,
            transitive = dep_info.sources,
        ),
        objects = depset(result.objects),
    )

    return [
        DefaultInfo(
            files = depset(files),
            default_runfiles = _build_runfiles(ctx),
        ),
        cc_info,
        ada_info,
        _create_instrumented_files_info(ctx, metadata_files = result.gcno_files),
    ]

ada_library = rule(
    doc = "Compiles Ada source files into a library. " +
          "This is the primary rule for Ada-to-Ada dependencies and cross-language " +
          "interop via CcInfo. Use `ada_static_library` or `ada_shared_library` " +
          "when you need to produce a specific artifact type for external consumption.",
    implementation = _ada_static_library_impl,
    attrs = _COMMON_ATTRS,
    toolchains = [TOOLCHAIN_TYPE],
    provides = [CcInfo, AdaInfo],
)

ada_static_library = rule(
    doc = "Compiles Ada source files into a static archive (.a) for external consumption.",
    implementation = _ada_static_library_impl,
    attrs = _COMMON_ATTRS,
    toolchains = [TOOLCHAIN_TYPE],
    provides = [CcInfo, AdaInfo],
)

# --------------------------------------------------------------------------- #
# ada_shared_library
# --------------------------------------------------------------------------- #

def _ada_shared_library_impl(ctx):
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)

    coverage_enabled = ctx.configuration.coverage_enabled

    result = ada_common.compile(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        srcs = ctx.files.srcs,
        dep_sources = dep_info.sources,
        compile_data = ctx.files.compile_data,
        compile_flags = ctx.attr.copts,
        coverage_enabled = coverage_enabled,
        name = ctx.label.name,
    )

    has_objects = len(result.objects) > 0

    if has_objects:
        shared_lib = ada_common.link_shared(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            objects = result.objects,
            dep_linking_contexts = dep_info.linking_contexts,
            user_link_flags = ctx.attr.linkopts,
            name = ctx.label.name,
        )

        linker_input = ada_common.create_linker_input(
            owner = ctx.label,
            user_link_flags = depset([shared_lib.path]),
            additional_inputs = depset([shared_lib]),
        )
        own_linking_context = ada_common.create_linking_context(
            linker_inputs = depset([linker_input]),
        )

        merged_linking_context = ada_common.merge_linking_contexts(
            linking_contexts = [own_linking_context] + dep_info.linking_contexts,
        )
        files = [shared_lib]
    else:
        merged_linking_context = ada_common.merge_linking_contexts(
            linking_contexts = dep_info.linking_contexts,
        )
        files = []

    cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(),
        linking_context = merged_linking_context,
    )

    ada_info = AdaInfo(
        cc_info = cc_info,
        ali_files = depset(
            direct = result.ali_files,
            transitive = dep_info.ali_files,
        ),
        transitive_sources = depset(
            direct = result.source_files,
            transitive = dep_info.sources,
        ),
        objects = depset(result.objects),
    )

    runfiles = _build_runfiles(ctx).merge(ctx.runfiles(files = files))

    return [
        DefaultInfo(
            files = depset(files),
            default_runfiles = runfiles,
        ),
        cc_info,
        ada_info,
        _create_instrumented_files_info(ctx, metadata_files = result.gcno_files),
    ]

ada_shared_library = rule(
    doc = "Compiles Ada source files into a shared (dynamic) library.",
    implementation = _ada_shared_library_impl,
    attrs = _COMMON_ATTRS,
    toolchains = [
        TOOLCHAIN_TYPE,
        config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    provides = [CcInfo, AdaInfo],
)

# --------------------------------------------------------------------------- #
# ada_binary / ada_test (shared implementation)
# --------------------------------------------------------------------------- #

_EXECUTABLE_ATTRS = _COMMON_ATTRS | {
    "linkstatic": attr.bool(
        default = True,
        doc = "Prefer static linking for dependencies.",
    ),
    "main": attr.label(
        doc = "Main Ada source file containing the entry point procedure. " +
              "If not set, the first .adb file in srcs is used.",
        allow_single_file = [".adb"],
    ),
}

def _get_gcov(ada_toolchain):
    """Get the gcov binary from the Ada toolchain."""
    return ada_toolchain.gcov

def _find_main_ali(ctx, result):
    """Determine which ALI file corresponds to the main program unit."""
    main_ali = None

    if ctx.attr.main:
        main_stem = ctx.file.main.basename.rsplit(".", 1)[0]
        for ali in result.ali_files:
            if ali.basename == main_stem + ".ali":
                main_ali = ali
                break

    if not main_ali and result.ali_files:
        adb_files = [s for s in ctx.files.srcs if s.extension == "adb"]
        if adb_files:
            first_stem = adb_files[0].basename.rsplit(".", 1)[0]
            for ali in result.ali_files:
                if ali.basename == first_stem + ".ali":
                    main_ali = ali
                    break
        if not main_ali:
            main_ali = result.ali_files[0]

    if not main_ali:
        fail("No main unit found for %s. Provide at least one .adb source file." % ctx.label)

    return main_ali

def _build_executable(ctx, is_test):
    """Shared implementation for ada_binary and ada_test."""
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)

    coverage_enabled = ctx.configuration.coverage_enabled

    compile_data = ctx.files.compile_data if hasattr(ctx.files, "compile_data") else []
    result = ada_common.compile(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        srcs = ctx.files.srcs,
        dep_sources = dep_info.sources,
        compile_data = compile_data,
        compile_flags = ctx.attr.copts,
        coverage_enabled = coverage_enabled,
        name = ctx.label.name,
    )

    main_ali = _find_main_ali(ctx, result)

    all_ali = depset(
        direct = result.ali_files,
        transitive = dep_info.ali_files,
    ).to_list()

    all_sources = depset(
        direct = result.source_files,
        transitive = dep_info.sources,
    ).to_list()

    binder_obj = ada_common.bind(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        main_ali = main_ali,
        all_ali_files = all_ali,
        transitive_sources = all_sources,
        name = ctx.label.name,
        label_package = ctx.label.package,
    )

    all_objects = result.objects + [binder_obj]

    executable = ada_common.link_executable(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        objects = all_objects,
        dep_linking_contexts = dep_info.linking_contexts,
        user_link_flags = ctx.attr.linkopts,
        link_deps_statically = ctx.attr.linkstatic,
        coverage_enabled = coverage_enabled,
        cc_coverage_link_flags = _cc_coverage_link_flags(ctx) if coverage_enabled else [],
        name = ctx.label.name,
    )
    runfiles = _build_runfiles(ctx)
    env = {}
    env_inherit = []

    if is_test:
        env = dict(ctx.attr.env) if hasattr(ctx.attr, "env") and ctx.attr.env else {}
        env_inherit = ctx.attr.env_inherit if hasattr(ctx.attr, "env_inherit") else []
        if coverage_enabled:
            gcov_file = _get_gcov(ada_toolchain)
            coverage_script_info = ctx.attr._coverage_tool[DefaultInfo]
            coverage_executable = coverage_script_info.files_to_run.executable
            env.setdefault("GCOV_PREFIX_STRIP", "0")
            env["GENERATE_LLVM_LCOV"] = "1"
            env["CC_CODE_COVERAGE_SCRIPT"] = "$TEST_SRCDIR/$TEST_WORKSPACE/" + coverage_executable.short_path
            coverage_runfiles = [coverage_executable]
            if gcov_file:
                env["ADA_GCOV_PATH"] = gcov_file.short_path
                env["COVERAGE_GCOV_PATH"] = gcov_file.short_path
                coverage_runfiles.append(gcov_file)
            runfiles = runfiles.merge(coverage_script_info.default_runfiles)
            runfiles = runfiles.merge(ctx.runfiles(files = coverage_runfiles))

    providers = [
        DefaultInfo(
            files = depset([executable]),
            runfiles = runfiles,
            executable = executable,
        ),
        _create_instrumented_files_info(ctx, metadata_files = result.gcno_files),
    ]

    if is_test:
        providers.append(RunEnvironmentInfo(
            environment = env,
            inherited_environment = env_inherit,
        ))

    return providers

def _ada_binary_impl(ctx):
    return _build_executable(ctx, is_test = False)

ada_binary = rule(
    doc = "Compiles Ada source files, binds them, and links into an executable.",
    implementation = _ada_binary_impl,
    attrs = _EXECUTABLE_ATTRS,
    toolchains = [
        TOOLCHAIN_TYPE,
        config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    executable = True,
)

def _ada_test_impl(ctx):
    return _build_executable(ctx, is_test = True)

ada_test = rule(
    doc = "Compiles Ada source files, binds them, and links into a test executable. Run with `bazel test`.",
    implementation = _ada_test_impl,
    attrs = _EXECUTABLE_ATTRS | {
        "env": attr.string_dict(
            doc = "Environment variables to set when running the test.",
        ),
        "env_inherit": attr.string_list(
            doc = "Environment variables to inherit from the host environment.",
        ),
        "_coverage_tool": attr.label(
            default = Label("//ada/private/coverage:collect_ada_coverage"),
            executable = True,
            cfg = "exec",
        ),
        "_lcov_merger": attr.label(
            cfg = "exec",
            default = configuration_field(fragment = "coverage", name = "output_generator"),
        ),
    },
    toolchains = [
        TOOLCHAIN_TYPE,
        config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    fragments = ["coverage"],
    test = True,
)
