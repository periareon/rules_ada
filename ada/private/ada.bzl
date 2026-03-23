"""Ada rules."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(":common.bzl", "ada_common")
load(":providers.bzl", "AdaInfo", "merge_ada_infos")
load(":toolchain.bzl", "TOOLCHAIN_TYPE")
load(":unit_naming.bzl", "collect_units")

_SRC_EXTENSIONS = [".ads", ".adb"]

_CC_TOOLCHAIN_TYPE = "@rules_cc//cc:toolchain_type"

def _cc_action_env(ctx):
    """Get environment variables from the CC toolchain's features.

    Extracts env vars like DEVELOPER_DIR and SDKROOT that the CC toolchain
    (e.g., apple_support) configures via env_set features.
    """
    cc_toolchain_info = ctx.toolchains[_CC_TOOLCHAIN_TYPE]
    if not cc_toolchain_info or not hasattr(cc_toolchain_info, "cc"):
        return {}
    cc_toolchain = cc_toolchain_info.cc
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )
    return cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_static_library,
        variables = cc_common.empty_variables(),
    )

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

def _cc_toolchain_ar(ctx):
    """Get the archiver path and files from the CC toolchain, if available.

    Returns a struct with ar_path (str) and all_files (depset), or None.
    """
    cc_toolchain_info = ctx.toolchains[_CC_TOOLCHAIN_TYPE]
    if not cc_toolchain_info or not hasattr(cc_toolchain_info, "cc"):
        return None
    cc_toolchain = cc_toolchain_info.cc
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )
    ar_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = "c++-link-static-library",
    )
    return struct(ar_path = ar_path, all_files = cc_toolchain.all_files)

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
        doc = "Additional compiler flags for Ada compilation (e.g., `-gnatwa`, `-O2`).",
    ),
    "data": attr.label_list(
        doc = "Additional files needed at runtime.",
        allow_files = True,
    ),
    "deps": attr.label_list(
        doc = "Dependencies. Can be Ada targets (`AdaInfo`) or C/C++ targets (CcInfo).",
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

    Returns a struct with dep_view (merged AdaInfo fields), linking_contexts,
    and compilation_contexts collected from AdaInfo and CcInfo providers.
    """
    linking_contexts = []
    compilation_contexts = []
    for dep in deps:
        if AdaInfo in dep:
            info = dep[AdaInfo]
            linking_contexts.append(info.cc_info.linking_context)
            compilation_contexts.append(info.cc_info.compilation_context)
        elif CcInfo in dep:
            linking_contexts.append(dep[CcInfo].linking_context)
            compilation_contexts.append(dep[CcInfo].compilation_context)

    dep_view = merge_ada_infos(deps)

    return struct(
        dep_view = dep_view,
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

def _compile_units(ctx, ada_toolchain, dep_view, units_by_stem, subunits, compile_data, coverage_enabled, pic):
    """Compile all units with spec/body split. Returns per-unit results."""
    all_specs = [u.spec for u in units_by_stem.values() if u.spec != None]
    all_bodies = [u.body for u in units_by_stem.values() if u.body != None]

    direct_spec_alis = []
    direct_body_alis = []
    direct_objects = []
    gcno_files = []
    units_out = []

    for stem in sorted(units_by_stem.keys()):
        u = units_by_stem[stem]
        sibling_sources = (
            [s for s in all_specs if s != u.spec] +
            [b for b in all_bodies if b != u.body] +
            subunits + compile_data
        )

        spec_ali = None
        body_ali = None
        obj = None

        if u.spec != None and u.body != None:
            spec_ali = ada_common.compile_interface(
                actions = ctx.actions,
                ada_toolchain = ada_toolchain,
                stem = stem,
                spec = u.spec,
                sibling_sources = sibling_sources,
                dep_view = dep_view,
                compile_flags = ctx.attr.copts,
                name = ctx.label.name,
            )
            direct_spec_alis.append(spec_ali)

        if u.body != None or u.spec != None:
            body_ali, obj, gcno = ada_common.compile_full(
                actions = ctx.actions,
                ada_toolchain = ada_toolchain,
                stem = stem,
                spec = u.spec,
                body = u.body,
                sibling_sources = sibling_sources,
                dep_view = dep_view,
                compile_flags = ctx.attr.copts,
                coverage_enabled = coverage_enabled,
                pic = pic,
                name = ctx.label.name,
            )
            direct_body_alis.append(body_ali)
            direct_objects.append(obj)
            if gcno:
                gcno_files.append(gcno)

        units_out.append(struct(
            stem = stem,
            spec = u.spec,
            body = u.body,
            spec_ali = spec_ali,
            body_ali = body_ali,
            object = obj,
        ))

    return struct(
        all_specs = all_specs,
        all_bodies = all_bodies,
        direct_spec_alis = direct_spec_alis,
        direct_body_alis = direct_body_alis,
        direct_objects = direct_objects,
        gcno_files = gcno_files,
        units_out = units_out,
        subunits = subunits,
    )

def _make_ada_info(result, dep_view, cc_info, exports_bodies = False):
    """Construct the AdaInfo provider from compilation results."""
    direct_srcdirs = sorted({s.dirname: None for s in result.all_specs}.keys())
    direct_spec_alidirs = sorted({a.dirname: None for a in result.direct_spec_alis}.keys())
    direct_body_alidirs = sorted({a.dirname: None for a in result.direct_body_alis}.keys())

    direct_exported_bodies = (result.all_bodies + result.subunits) if exports_bodies else []

    return AdaInfo(
        cc_info = cc_info,
        direct_spec_alis = depset(result.direct_spec_alis),
        direct_body_alis = depset(result.direct_body_alis),
        direct_objects = depset(result.direct_objects),
        transitive_spec_alis = depset(result.direct_spec_alis, transitive = [dep_view.transitive_spec_alis]),
        transitive_body_alis = depset(result.direct_body_alis, transitive = [dep_view.transitive_body_alis]),
        transitive_objects = depset(result.direct_objects, transitive = [dep_view.transitive_objects]),
        transitive_specs = depset(result.all_specs, transitive = [dep_view.transitive_specs]),
        transitive_exported_bodies = depset(direct_exported_bodies, transitive = [dep_view.transitive_exported_bodies]),
        transitive_srcdirs = depset(direct_srcdirs, transitive = [dep_view.transitive_srcdirs]),
        transitive_spec_alidirs = depset(direct_spec_alidirs, transitive = [dep_view.transitive_spec_alidirs]),
        transitive_body_alidirs = depset(direct_body_alidirs, transitive = [dep_view.transitive_body_alidirs]),
        units = result.units_out,
    )

# --------------------------------------------------------------------------- #
# ada_library
# --------------------------------------------------------------------------- #

def _ada_library_impl(ctx):
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)
    dep_view = dep_info.dep_view

    explicit_subunits = ctx.files.subunits if hasattr(ctx.files, "subunits") else []
    explicit_subunit_set = {f.path: True for f in explicit_subunits}
    auto_srcs = [s for s in ctx.files.srcs if s.path not in explicit_subunit_set]
    units_by_stem, heuristic_subunits = collect_units(auto_srcs)
    subunits = heuristic_subunits + explicit_subunits

    compile_data = ctx.files.compile_data if hasattr(ctx.files, "compile_data") else []
    result = _compile_units(
        ctx,
        ada_toolchain,
        dep_view,
        units_by_stem,
        subunits,
        compile_data,
        coverage_enabled = ctx.configuration.coverage_enabled,
        pic = False,
    )

    has_objects = len(result.direct_objects) > 0
    if has_objects:
        archive = ada_common.archive(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            objects = result.direct_objects,
            name = ctx.label.name,
            cc_toolchain = _cc_toolchain_ar(ctx) if not ada_toolchain.ar else None,
            env = _cc_action_env(ctx),
        )
        lib_to_link = cc_common.create_library_to_link(
            actions = ctx.actions,
            static_library = archive,
            pic_static_library = archive,
        )
        linker_input = ada_common.create_linker_input(
            owner = ctx.label,
            libraries = depset([lib_to_link]),
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

    exports_bodies = ctx.attr.exports_bodies if hasattr(ctx.attr, "exports_bodies") else False
    ada_info = _make_ada_info(result, dep_view, cc_info, exports_bodies = exports_bodies)

    return [
        DefaultInfo(
            files = depset(files),
            default_runfiles = _build_runfiles(ctx),
        ),
        cc_info,
        ada_info,
        _create_instrumented_files_info(ctx, metadata_files = result.gcno_files),
    ]

_LIBRARY_ATTRS = _COMMON_ATTRS | {
    "exports_bodies": attr.bool(
        default = False,
        doc = "If True, this library's body sources flow into downstream compile inputs. " +
              "Set this on libraries whose public API exposes generics, since cross-unit " +
              "generic instantiation requires the generic body at the instantiation site's " +
              "compile time.",
    ),
    "subunits": attr.label_list(
        allow_files = [".adb"],
        doc = "Body files that are `separate` subunits, listed explicitly to bypass " +
              "the hyphen-stem heuristic. Files listed here MUST also appear in `srcs`. " +
              "They flow as inputs to their parent unit's compile but get no standalone " +
              "compile action.",
    ),
}

ada_library = rule(
    doc = "Compiles Ada source files into a library. " +
          "This is the primary rule for Ada-to-Ada dependencies and cross-language " +
          "interop via CcInfo. Use `ada_static_library` or `ada_shared_library` " +
          "when you need to produce a specific artifact type for external consumption.",
    implementation = _ada_library_impl,
    attrs = _LIBRARY_ATTRS,
    toolchains = [
        TOOLCHAIN_TYPE,
        config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    fragments = ["cpp", "apple"],
    provides = [CcInfo, AdaInfo],
)

# --------------------------------------------------------------------------- #
# ada_static_library
# --------------------------------------------------------------------------- #

_ARTIFACT_LIBRARY_ATTRS = _COMMON_ATTRS | {
    "lib_name": attr.string(
        doc = "Library name for gnatbind -L (unique elaboration namespace). " +
              "Defaults to the target name.",
    ),
}

def _ada_static_library_impl(ctx):
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)
    dep_view = dep_info.dep_view

    units_by_stem, subunits = collect_units(ctx.files.srcs)
    compile_data = ctx.files.compile_data if hasattr(ctx.files, "compile_data") else []

    coverage_enabled = ctx.configuration.coverage_enabled
    result = _compile_units(
        ctx,
        ada_toolchain,
        dep_view,
        units_by_stem,
        subunits,
        compile_data,
        coverage_enabled = coverage_enabled,
        pic = True,
    )

    lib_name = ctx.attr.lib_name if ctx.attr.lib_name else ctx.label.name

    has_objects = len(result.direct_objects) > 0

    if has_objects:
        binder_obj = ada_common.bind_library(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            unit_ali_files = result.direct_body_alis,
            dep_view = dep_view,
            lib_name = lib_name,
            name = ctx.label.name,
            label_package = ctx.label.package,
        )

        all_objects = result.direct_objects + [binder_obj]

        archive = ada_common.archive(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            objects = all_objects,
            name = ctx.label.name,
            cc_toolchain = _cc_toolchain_ar(ctx) if not ada_toolchain.ar else None,
            env = _cc_action_env(ctx),
        )

        lib_to_link = cc_common.create_library_to_link(
            actions = ctx.actions,
            static_library = archive,
            pic_static_library = archive,
        )
        linker_input = ada_common.create_linker_input(
            owner = ctx.label,
            libraries = depset([lib_to_link]),
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

    ada_info = _make_ada_info(result, dep_view, cc_info)

    return [
        DefaultInfo(
            files = depset(files),
            default_runfiles = _build_runfiles(ctx),
        ),
        cc_info,
        ada_info,
        _create_instrumented_files_info(ctx, metadata_files = result.gcno_files),
    ]

ada_static_library = rule(
    doc = "Compiles Ada source files into a static archive (.a) for external consumption.",
    implementation = _ada_static_library_impl,
    attrs = _ARTIFACT_LIBRARY_ATTRS,
    toolchains = [
        TOOLCHAIN_TYPE,
        config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    fragments = ["cpp", "apple"],
    provides = [CcInfo, AdaInfo],
)

# --------------------------------------------------------------------------- #
# ada_shared_library
# --------------------------------------------------------------------------- #

def _ada_shared_library_impl(ctx):
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)
    dep_view = dep_info.dep_view

    units_by_stem, subunits = collect_units(ctx.files.srcs)
    compile_data = ctx.files.compile_data if hasattr(ctx.files, "compile_data") else []

    coverage_enabled = ctx.configuration.coverage_enabled
    result = _compile_units(
        ctx,
        ada_toolchain,
        dep_view,
        units_by_stem,
        subunits,
        compile_data,
        coverage_enabled = coverage_enabled,
        pic = True,
    )

    lib_name = ctx.attr.lib_name if ctx.attr.lib_name else ctx.label.name

    has_objects = len(result.direct_objects) > 0

    if has_objects:
        binder_obj = ada_common.bind_library(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            unit_ali_files = result.direct_body_alis,
            dep_view = dep_view,
            lib_name = lib_name,
            name = ctx.label.name,
            label_package = ctx.label.package,
        )

        all_objects = result.direct_objects + [binder_obj]

        shared_lib = ada_common.link_shared(
            actions = ctx.actions,
            ada_toolchain = ada_toolchain,
            objects = all_objects,
            dep_linking_contexts = dep_info.linking_contexts,
            user_link_flags = ctx.attr.linkopts,
            coverage_enabled = coverage_enabled,
            cc_coverage_link_flags = _cc_coverage_link_flags(ctx) if coverage_enabled else [],
            name = ctx.label.name,
            env = _cc_action_env(ctx),
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

    ada_info = _make_ada_info(result, dep_view, cc_info)

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
    attrs = _ARTIFACT_LIBRARY_ATTRS,
    toolchains = [
        TOOLCHAIN_TYPE,
        config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    fragments = ["cpp", "apple"],
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

def _find_main_ali(ctx, direct_body_alis):
    """Determine which ALI file corresponds to the main program unit."""
    main_ali = None

    if ctx.attr.main:
        main_stem = ctx.file.main.basename.rsplit(".", 1)[0]
        for ali in direct_body_alis:
            if ali.basename == main_stem + ".ali":
                main_ali = ali
                break

    if not main_ali and direct_body_alis:
        adb_files = [s for s in ctx.files.srcs if s.extension == "adb"]
        if adb_files:
            first_stem = adb_files[0].basename.rsplit(".", 1)[0]
            for ali in direct_body_alis:
                if ali.basename == first_stem + ".ali":
                    main_ali = ali
                    break
        if not main_ali:
            main_ali = direct_body_alis[0]

    if not main_ali:
        fail("No main unit found for %s. Provide at least one .adb source file." % ctx.label)

    return main_ali

def _build_executable(ctx, is_test):
    """Shared implementation for ada_binary and ada_test."""
    ada_toolchain = ctx.toolchains[TOOLCHAIN_TYPE].ada_toolchain

    dep_info = _collect_deps(ctx.attr.deps)
    dep_view = dep_info.dep_view

    coverage_enabled = ctx.configuration.coverage_enabled

    units_by_stem, subunits = collect_units(ctx.files.srcs)
    compile_data = ctx.files.compile_data if hasattr(ctx.files, "compile_data") else []

    result = _compile_units(
        ctx,
        ada_toolchain,
        dep_view,
        units_by_stem,
        subunits,
        compile_data,
        coverage_enabled = coverage_enabled,
        pic = False,
    )

    main_ali = _find_main_ali(ctx, result.direct_body_alis)

    all_ali = depset(
        direct = result.direct_body_alis,
        transitive = [dep_view.transitive_body_alis],
    )

    all_sources = depset(
        direct = result.all_specs,
        transitive = [dep_view.transitive_specs],
    )

    binder_obj = ada_common.bind(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        main_ali = main_ali,
        all_ali_files = all_ali.to_list(),
        transitive_sources = all_sources.to_list(),
        name = ctx.label.name,
        label_package = ctx.label.package,
    )

    all_objects = result.direct_objects + [binder_obj]

    dep_objects = dep_view.transitive_objects.to_list()

    executable = ada_common.link_executable(
        actions = ctx.actions,
        ada_toolchain = ada_toolchain,
        objects = all_objects + dep_objects,
        dep_linking_contexts = dep_info.linking_contexts,
        user_link_flags = ctx.attr.linkopts,
        link_deps_statically = ctx.attr.linkstatic,
        coverage_enabled = coverage_enabled,
        cc_coverage_link_flags = _cc_coverage_link_flags(ctx) if coverage_enabled else [],
        name = ctx.label.name,
        env = _cc_action_env(ctx),
    )
    runfiles = _build_runfiles(ctx)
    env = {}
    env_inherit = []

    if is_test:
        env = dict(ctx.attr.env) if hasattr(ctx.attr, "env") and ctx.attr.env else {}
        env_inherit = ctx.attr.env_inherit if hasattr(ctx.attr, "env_inherit") else []
        if coverage_enabled:
            gcov_file = _get_gcov(ada_toolchain)
            coverage_executable = ctx.executable._collect_cc_coverage
            env.setdefault("GCOV_PREFIX_STRIP", "0")
            env["GENERATE_LLVM_LCOV"] = "1"
            env["CC_CODE_COVERAGE_SCRIPT"] = coverage_executable.path
            coverage_runfiles = [coverage_executable]
            if gcov_file:
                env["ADA_GCOV_PATH"] = gcov_file.short_path
                env["COVERAGE_GCOV_PATH"] = gcov_file.short_path
                coverage_runfiles.append(gcov_file)
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
    fragments = ["cpp", "apple"],
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
        "_collect_cc_coverage": attr.label(
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
    fragments = ["coverage", "cpp", "apple"],
    test = True,
)
