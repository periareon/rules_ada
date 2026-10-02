"""Common utilities for Ada compilation, binding, and linking."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load(":actions.bzl", "ACTIONS")
load(":args_expansion.bzl", "expand_args")
load(":features.bzl", "STATIC_LIBGCC", "ada_features")
load(":toolchain_config.bzl", "artifact_name")

def _toolchain_args(ada_toolchain, action, variables, extra_args = []):
    """Expand the toolchain's `args` (and any extra ones) for an action."""
    return expand_args(list(ada_toolchain.args) + extra_args, action, variables)

def _new_args(actions):
    """An Args object that spills to a params file on long command lines.

    process_wrapper expands `@file` arguments (one argument per line) before
    parsing its own flags, so the whole command line may live in the file.
    This keeps large bind and link lines under Windows' 32K limit.
    """
    args = actions.args()
    args.use_param_file("@%s", use_always = False)
    args.set_param_file_format("multiline")
    return args

def _compile_interface(
        *,
        actions,
        ada_toolchain,
        stem,
        spec,
        sibling_sources,
        dep_view,
        compile_flags = [],
        name):
    """Spec-only -gnatc compile for body-having units. Emits .ali, no .o.

    This produces an "interface ALI" that downstream libraries use for
    type checking. Because the body ALI is not needed downstream, body-only
    changes don't trigger recompilation of consumers.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        stem: str unit stem (e.g. "foo" for foo.ads).
        spec: File, the .ads spec file.
        sibling_sources: list[File] of other sources in the same target.
        dep_view: struct from merge_ada_infos with transitive_* depsets.
        compile_flags: list[str] of additional compiler flags (copts).
        name: str rule name, used for output directory naming.

    Returns:
        File: the interface .ali file.
    """
    compiler = ada_toolchain.compiler
    process_wrapper = ada_toolchain.process_wrapper

    ali = actions.declare_file(paths.join("_objs", name, "spec", stem + ".ali"))
    phantom_obj_path = paths.join(ali.dirname, stem + ".o")

    sibling_dir_set = {s.dirname: True for s in sibling_sources}
    i_flags = ["-I" + d for d in sorted(sibling_dir_set.keys())]

    args = _new_args(actions)
    args.add("--rename-if-exists")
    args.add(stem + ".ali")
    args.add(ali)
    args.add("--scrub-ali")
    args.add(ali)
    args.add("--")
    args.add(compiler)
    args.add("-c")
    args.add("-gnatc")
    args.add_all(i_flags)
    args.add_all(dep_view.transitive_srcdirs, format_each = "-I%s")
    args.add_all(dep_view.transitive_spec_alidirs, format_each = "-I%s")
    args.add_all(dep_view.transitive_body_alidirs, format_each = "-I%s")
    args.add_all(ada_toolchain.compile_flags)
    args.add_all(_toolchain_args(ada_toolchain, ACTIONS.compile, {}))
    args.add_all(compile_flags)
    args.add(spec)
    args.add("-o")
    args.add(phantom_obj_path)

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            direct = [compiler, spec] + sibling_sources,
            transitive = [
                dep_view.transitive_specs,
                dep_view.transitive_spec_alis,
                dep_view.transitive_exported_bodies,
                ada_toolchain.ada_std,
                ada_toolchain.compiler_lib,
                ada_toolchain.args_files,
            ],
        ),
        outputs = [ali],
        mnemonic = "AdaCompileInterface",
        progress_message = "Compiling Ada interface %s" % stem,
    )
    return ali

def _compile_full(
        *,
        actions,
        ada_toolchain,
        stem,
        spec,
        body,
        sibling_sources,
        dep_view,
        compile_flags = [],
        coverage_enabled = False,
        pic = False,
        name):
    """Full compile. `body` if present (body-having unit) else `spec` (spec-only).

    Produces both .ali and .o.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        stem: str unit stem.
        spec: File or None, the .ads spec file.
        body: File or None, the .adb body file.
        sibling_sources: list[File] of other sources in the same target.
        dep_view: struct from merge_ada_infos with transitive_* depsets.
        compile_flags: list[str] of additional compiler flags (copts).
        coverage_enabled: bool whether to add gcov instrumentation flags.
        pic: bool whether to add -fPIC.
        name: str rule name, used for output directory naming.

    Returns:
        tuple of (ali: File, obj: File, gcno: File or None).
    """
    primary = body if body != None else spec
    if primary == None:
        fail("rules_ada: compile_full needs at least a spec or body for %s" % stem)

    compiler = ada_toolchain.compiler
    process_wrapper = ada_toolchain.process_wrapper

    ali = actions.declare_file(paths.join("_objs", name, "body", stem + ".ali"))
    obj = actions.declare_file(paths.join("_objs", name, "body", stem + ".o"))
    outputs = [ali, obj]

    sibling_dir_set = {s.dirname: True for s in sibling_sources}
    i_flags = ["-I" + d for d in sorted(sibling_dir_set.keys())]

    direct_inputs = [compiler, primary] + sibling_sources
    if body != None and spec != None:
        direct_inputs.append(spec)

    args = _new_args(actions)
    args.add("--rename-if-exists")
    args.add(stem + ".ali")
    args.add(ali)
    args.add("--scrub-ali")
    args.add(ali)
    args.add("--")
    args.add(compiler)
    args.add("-c")
    args.add_all(i_flags)
    args.add_all(dep_view.transitive_srcdirs, format_each = "-I%s")
    args.add_all(dep_view.transitive_spec_alidirs, format_each = "-I%s")
    args.add_all(dep_view.transitive_body_alidirs, format_each = "-I%s")
    args.add_all(ada_toolchain.compile_flags)
    args.add_all(_toolchain_args(ada_toolchain, ACTIONS.compile, {}))
    if pic:
        args.add("-fPIC")
    args.add_all(compile_flags)

    gcno = None
    if coverage_enabled:
        args.add("--coverage")
        gcno = actions.declare_file(paths.join("_objs", name, "body", stem + ".gcno"))
        outputs.append(gcno)

    args.add(primary)
    args.add("-o")
    args.add(obj)

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [
                dep_view.transitive_specs,
                dep_view.transitive_spec_alis,
                dep_view.transitive_exported_bodies,
                ada_toolchain.ada_std,
                ada_toolchain.compiler_lib,
                ada_toolchain.args_files,
            ],
        ),
        outputs = outputs,
        mnemonic = "AdaCompileFull",
        progress_message = "Compiling Ada %s %s" % ("body" if body != None else "spec", stem),
    )
    return ali, obj, gcno

def _bind(
        *,
        actions,
        ada_toolchain,
        main_ali,
        all_ali_files,
        transitive_sources,
        name,
        label_package = ""):
    """Run gnatbind to generate elaboration code, then compile the binder output.

    The binder reads all ALI files to verify consistency across compilation
    units and determines the correct package initialization (elaboration)
    order. It generates a source file that calls each package's elaboration
    procedure in the right sequence, then invokes the main program.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        main_ali: File, the main unit's .ali file.
        all_ali_files: list[File] of all transitive .ali files.
        transitive_sources: list[File] of all transitive .ads source files.
        name: str rule name for output naming.
        label_package: str label package path, used to make binder output
            filenames unique in the exec root CWD (prevents races on Windows
            where actions are not sandboxed).

    Returns:
        File: the compiled binder object file.
    """
    binder = ada_toolchain.binder
    compiler = ada_toolchain.compiler
    process_wrapper = ada_toolchain.process_wrapper

    safe_name = name.replace("-", "_").replace(".", "_")
    if label_package:
        safe_pkg = label_package.replace("/", "_").replace("-", "_").replace(".", "_")
        binder_basename = "b_" + safe_pkg + "_" + safe_name
    else:
        binder_basename = "b_" + safe_name
    binder_adb = actions.declare_file(paths.join("_bind", name, binder_basename + ".adb"))
    binder_ads = actions.declare_file(paths.join("_bind", name, binder_basename + ".ads"))
    binder_obj = actions.declare_file(paths.join("_bind", name, binder_basename + ".o"))

    # The CWD filename must be unique across ALL concurrent actions in the
    # exec root. On Windows (no sandboxing), the same target can be built
    # in multiple configurations simultaneously (e.g., fastbuild + opt-exec).
    # Include a hash of the output path to disambiguate.
    cwd_hash = "%x" % (abs(hash(binder_adb.path)) % 0xFFFFFF)
    binder_cwd_name = binder_basename + "_" + cwd_hash

    search_dirs = {}
    for ali in all_ali_files:
        search_dirs[ali.dirname] = True
    for src in transitive_sources:
        search_dirs[src.dirname] = True

    # gnatbind refuses directory separators in -o, so we run it in the
    # exec root (CWD) with a flat output name and rename afterward.
    args = _new_args(actions)
    args.add("--rename")
    args.add(binder_cwd_name + ".adb")
    args.add(binder_adb)
    args.add("--rename")
    args.add(binder_cwd_name + ".ads")
    args.add(binder_ads)
    args.add("--rename")
    args.add(binder_cwd_name + ".o")
    args.add(binder_obj)
    args.add("--scrub-binder")
    args.add(binder_adb)
    args.add("--")

    # Command 1: gnatbind
    args.add(binder)
    args.add_all(ada_toolchain.bind_flags)
    args.add_all(_toolchain_args(ada_toolchain, ACTIONS.bind, {}))
    for search_dir in sorted(search_dirs.keys()):
        args.add("-I" + search_dir)
    args.add("-o")
    args.add(binder_cwd_name + ".adb")
    args.add(main_ali)

    # Command 2: compile the binder output.
    # GNAT requires the object filename to match the compilation unit name,
    # so we output to the CWD-relative name and let process_wrapper rename.
    args.add("++")
    args.add(compiler)
    args.add("-c")
    args.add("-I.")
    args.add(binder_cwd_name + ".adb")
    args.add("-o")
    args.add(binder_cwd_name + ".o")

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            direct = [binder, compiler] + all_ali_files + transitive_sources,
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib, ada_toolchain.args_files],
        ),
        outputs = [binder_adb, binder_ads, binder_obj],
        mnemonic = "AdaBind",
        progress_message = "Binding Ada program %s" % name,
    )

    return binder_obj

def _bind_library(
        *,
        actions,
        ada_toolchain,
        unit_ali_files,
        dep_view,
        lib_name,
        name,
        label_package = ""):
    """Run gnatbind in library mode, then compile the binder output.

    Library-mode binding (-n -a -L<name>) generates elaboration init/finalize
    entry points so the library can be loaded and initialized correctly as a
    standalone unit (e.g. a shared library consumed by C code).

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        unit_ali_files: list[File] of this library's direct body ALI files.
        dep_view: struct from merge_ada_infos with transitive_* depsets.
        lib_name: str library name for -L flag (unique elaboration namespace).
        name: str rule name for output naming.
        label_package: str label package path for CWD collision avoidance.

    Returns:
        File: the compiled binder object file.
    """
    binder = ada_toolchain.binder
    compiler = ada_toolchain.compiler
    process_wrapper = ada_toolchain.process_wrapper

    safe_name = name.replace("-", "_").replace(".", "_")
    safe_lib = lib_name.replace("-", "_").replace(".", "_")
    if label_package:
        safe_pkg = label_package.replace("/", "_").replace("-", "_").replace(".", "_")
        binder_basename = "b_" + safe_pkg + "_" + safe_lib
    else:
        binder_basename = "b_" + safe_lib
    binder_adb = actions.declare_file(paths.join("_bind", safe_name, binder_basename + ".adb"))
    binder_ads = actions.declare_file(paths.join("_bind", safe_name, binder_basename + ".ads"))
    binder_obj = actions.declare_file(paths.join("_bind", safe_name, binder_basename + ".o"))

    cwd_hash = "%x" % (abs(hash(binder_adb.path)) % 0xFFFFFF)
    binder_cwd_name = binder_basename + "_" + cwd_hash

    args = _new_args(actions)
    args.add("--rename")
    args.add(binder_cwd_name + ".adb")
    args.add(binder_adb)
    args.add("--rename")
    args.add(binder_cwd_name + ".ads")
    args.add(binder_ads)
    args.add("--rename")
    args.add(binder_cwd_name + ".o")
    args.add(binder_obj)
    args.add("--scrub-binder")
    args.add(binder_adb)
    args.add("--")

    # Command 1: gnatbind in library mode
    args.add(binder)
    args.add("-n")
    args.add("-a")
    args.add("-L" + safe_lib)
    args.add_all(ada_toolchain.bind_flags)
    args.add_all(_toolchain_args(ada_toolchain, ACTIONS.bind, {}))
    args.add_all(dep_view.transitive_body_alidirs, format_each = "-I%s")
    args.add_all(dep_view.transitive_srcdirs, format_each = "-I%s")
    for ali in unit_ali_files:
        args.add("-I" + ali.dirname)
    args.add("-o")
    args.add(binder_cwd_name + ".adb")
    args.add_all(unit_ali_files)

    # Command 2: compile the binder output
    args.add("++")
    args.add(compiler)
    args.add("-c")
    args.add("-fPIC")
    args.add("-I.")
    args.add(binder_cwd_name + ".adb")
    args.add("-o")
    args.add(binder_cwd_name + ".o")

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            direct = [binder, compiler] + unit_ali_files,
            transitive = [
                dep_view.transitive_body_alis,
                dep_view.transitive_specs,
                ada_toolchain.ada_std,
                ada_toolchain.compiler_lib,
                ada_toolchain.args_files,
            ],
        ),
        outputs = [binder_adb, binder_ads, binder_obj],
        mnemonic = "AdaBind",
        progress_message = "Binding Ada library %s" % lib_name,
    )

    return binder_obj

def _gcov_link_flags(ada_toolchain):
    """Link flags for libgcov.a from the GNAT toolchain.

    libgcov.a sits next to libgcc.a in the GCC library directory, so its path
    is derived from the libgcc.a entry of `static_runtime_lib`; the file itself
    reaches the action through `compiler_lib`.

    Args:
        ada_toolchain: AdaToolchainInfo provider.

    Returns:
        list[str]: Link flags for gcov, or empty list if libgcc.a is not listed.
    """
    for lib in ada_toolchain.static_runtime_lib:
        if lib.basename == "libgcc.a":
            return [lib.dirname + "/libgcov.a"]
    return []

_DYNAMIC_LIBRARY_EXTENSIONS = ("so", "dylib", "dll")

def _is_dynamic_library(file):
    """Whether a file is a shared library, judged by extension."""
    return file.extension in _DYNAMIC_LIBRARY_EXTENSIONS

def _collect_cc_link_inputs(linking_contexts, prefer_static = True, use_pic = False):
    """Extract library files and link flags from dependency CcLinkingContexts.

    Walks each LinkerInput to collect library artifacts, user link flags,
    and additional inputs so that GNAT gcc can consume them directly on the
    command line.

    Args:
        linking_contexts: list[CcLinkingContext] from dependencies.
        prefer_static: bool, when True prefer .a over .so.
        use_pic: bool, when True prefer pic_static_library (for shared
            library linking).

    Returns:
        struct with fields:
            libs: list[struct(file, dynamic, alwayslink)] library files
                (used as both action inputs and command-line paths), whether
                the shared variant was chosen, and whether the whole archive
                must be linked.
            flags: list[str] link flags (passed as-is).
            extra_inputs: list[File] action inputs only, their paths are
                already encoded in link flags.
    """
    libs = []
    flags = []
    extra_inputs = []
    for lc in linking_contexts:
        for linker_input in lc.linker_inputs.to_list():
            for lib in linker_input.libraries:
                # cc_common may expose a shared library through a symlink in
                # a `_solib_*` directory. Link against the real file so the
                # rpath is computed relative to what actually lands next to
                # the executable and in runfiles.
                dynamic = lib.resolved_symlink_dynamic_library or lib.dynamic_library
                if use_pic:
                    f = lib.pic_static_library or lib.static_library or dynamic
                elif prefer_static:
                    f = lib.static_library or lib.pic_static_library or dynamic
                else:
                    f = dynamic or lib.static_library or lib.pic_static_library
                if f:
                    libs.append(struct(
                        file = f,
                        dynamic = f == dynamic,
                        alwayslink = lib.alwayslink and f != dynamic,
                    ))
            flags.extend(linker_input.user_link_flags)
            extra_inputs.extend(linker_input.additional_inputs)
    return struct(libs = libs, flags = flags, extra_inputs = extra_inputs)

def _relative_dir(from_dir, to_dir):
    """Relative path from one directory to another, or "" when they match.

    Both arguments must be relative to the same root. Leading ".."
    components (as in `File.short_path` for external repositories) are
    handled because they are compared componentwise like any other.
    """
    from_parts = [p for p in from_dir.split("/") if p and p != "."]
    to_parts = [p for p in to_dir.split("/") if p and p != "."]
    common = 0
    for a, b in zip(from_parts, to_parts):
        if a != b:
            break
        common += 1
    return "/".join([".."] * (len(from_parts) - common) + to_parts[common:])

def _runtime_library_search_directories(output, dynamic_libs):
    """Directories, relative to a link output, holding its shared libraries.

    One entry per distinct directory, for both layouts the output runs from:
    bazel-bin (`File.path`) and the runfiles tree (`File.short_path`), which
    differ for files in external repositories. The output's own directory is
    `.` so templates can always append the entry to an origin token.

    Args:
        output: File, the executable or shared library being linked.
        dynamic_libs: list[File] of shared libraries it needs at runtime.

    Returns:
        list[str]: relative directories in first-seen order.
    """
    dirs = {}
    for lib in dynamic_libs:
        dirs[_relative_dir(output.dirname, lib.dirname) or "."] = True
        dirs[_relative_dir(paths.dirname(output.short_path), paths.dirname(lib.short_path)) or "."] = True
    return dirs.keys()

def _normalize_dep_link_flags(link_flags):
    """Convert MSVC-style .lib references to -l flags.

    C/C++ or Rust dependencies may name Windows system libraries in MSVC
    format (e.g. advapi32.lib); the GCC driver needs them as -l flags
    (e.g. -ladvapi32). Only bare names without path separators are
    converted, so the rewrite is safe on every platform.
    """
    result = []
    for flag in link_flags:
        if flag.endswith(".lib") and "/" not in flag and "\\" not in flag:
            result.append("-l" + flag.removesuffix(".lib"))
        else:
            result.append(flag)
    return result

def _archive(
        *,
        actions,
        ada_toolchain,
        objects,
        name,
        cc_toolchain = None,
        env = {}):
    """Create a static library archive from object files.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        objects: list[File] of .o files to archive.
        name: str library name; the file name follows the toolchain's `static_library` pattern.
        cc_toolchain: struct with ar_path (str) and all_files (depset),
            or None. Used as fallback when ada_toolchain.ar is None.
        env: dict[str, str] environment variables for the action.

    Returns:
        File: the static archive.
    """
    archive = actions.declare_file(_artifact_name(ada_toolchain, "static_library", name))
    ar = ada_toolchain.ar
    process_wrapper = ada_toolchain.process_wrapper
    toolchain_args = _toolchain_args(ada_toolchain, ACTIONS.archive, {})

    if ar:
        args = _new_args(actions)
        args.add("--")
        args.add(ar)
        args.add_all(toolchain_args)
        args.add("rcs")
        args.add(archive)
        args.add_all(objects)

        actions.run(
            executable = process_wrapper,
            arguments = [args],
            inputs = depset([ar] + objects, transitive = [ada_toolchain.compiler_lib, ada_toolchain.args_files]),
            outputs = [archive],
            env = env,
            mnemonic = "AdaArchive",
            progress_message = "Archiving Ada library %s" % name,
        )
    elif cc_toolchain:
        is_libtool = cc_toolchain.ar_path.endswith("/libtool") or cc_toolchain.ar_path == "libtool"

        args = _new_args(actions)
        args.add("--")
        args.add(cc_toolchain.ar_path)
        args.add_all(toolchain_args)
        if is_libtool:
            args.add("-static")
            args.add("-o")
        else:
            args.add("rcs")
        args.add(archive)
        args.add_all(objects)

        actions.run(
            executable = process_wrapper,
            arguments = [args],
            tools = cc_toolchain.all_files,
            inputs = depset(objects, transitive = [ada_toolchain.compiler_lib, ada_toolchain.args_files]),
            outputs = [archive],
            env = env,
            mnemonic = "AdaArchive",
            progress_message = "Archiving Ada library %s" % name,
        )
    else:
        fail("No archiver available: GNAT toolchain has no ar and no CC toolchain fallback was provided")

    return archive

def _artifact_name(ada_toolchain, category, name):
    """File name of an output according to the toolchain's name patterns."""
    return artifact_name(ada_toolchain.artifact_name_patterns, category, name)

# Directory beside a linked output that holds its staged runtime libraries.
_DYNAMIC_RUNTIME_DIR_SUFFIX = ".runtime_libs"

def _stage_dynamic_runtime_libs(*, actions, ada_toolchain, features, output_name):
    """Stage the toolchain's shared runtime libraries beside a link output.

    While `static_libgcc` is disabled the compiler driver links the shared
    libgcc from its own installation, so the toolchain's `dynamic_runtime_lib`
    files are symlinked into `<output_name>.runtime_libs/`. The directory is
    exposed to the link line through `runtime_library_search_directories`
    when the staged files are passed as `dynamic_runtime_libs`, and the
    calling rule must put them in its runfiles (and, for a shared library,
    its default outputs) so they travel with the binary.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        features: list[str] enabled feature names for this link.
        output_name: str, the package-relative file name of the link output.

    Returns:
        list[File]: staged libraries; empty when `static_libgcc` is enabled
            or the toolchain declares none.
    """
    if STATIC_LIBGCC in features:
        return []
    staged = []
    for lib in ada_toolchain.dynamic_runtime_lib:
        out = actions.declare_file(output_name + _DYNAMIC_RUNTIME_DIR_SUFFIX + "/" + lib.basename)
        actions.symlink(
            output = out,
            target_file = lib,
            progress_message = "Staging %s for %s" % (lib.basename, output_name),
        )
        staged.append(out)
    return staged

def _link(
        *,
        actions,
        ada_toolchain,
        action,
        output_name,
        objects,
        dep_linking_contexts = [],
        user_link_flags = [],
        link_deps_statically = True,
        coverage_link_flags = [],
        macos_deployment_target = None,
        features = [],
        dynamic_runtime_libs = [],
        env = {},
        name):
    """Link an executable or shared library with the toolchain's args.

    The rules contribute only the compiler and the variables below; which
    flags appear, and in what order, is decided by `ada_toolchain.args` and
    the arguments of the enabled features.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        action: str, `link_executable` or `link_shared_library`.
        output_name: str, package-relative file name of the output (see
            `artifact_name`).
        objects: list[File] of .o files.
        dep_linking_contexts: list[CcLinkingContext] from dependencies.
        user_link_flags: list[str] the target's linkopts.
        link_deps_statically: bool, prefer static dependency libraries
            (executables only; shared libraries always take PIC archives).
        coverage_link_flags: list[str] coverage runtime flags, empty when off.
        macos_deployment_target: str or None from the CC toolchain.
        features: list[str] enabled feature names (see features.bzl).
        dynamic_runtime_libs: list[File] staged beside the output by
            `_stage_dynamic_runtime_libs`.
        env: dict[str, str] environment variables for the action.
        name: str target name, for messages.

    Returns:
        File: the linked output.
    """
    shared = action == ACTIONS.link_shared_library
    output = actions.declare_file(output_name)
    compiler = ada_toolchain.compiler

    if shared:
        dep_inputs = _collect_cc_link_inputs(dep_linking_contexts, use_pic = True)
    else:
        dep_inputs = _collect_cc_link_inputs(dep_linking_contexts, prefer_static = link_deps_statically)

    # An executable must find its shared dependencies at runtime; a shared
    # library resolves them through the executable that loads it. Both need
    # the runtime libraries staged beside them. extra_inputs are checked by
    # extension for the no-CC-toolchain case, where a shared library can only
    # travel as a raw path plus input.
    dynamic_deps = list(dynamic_runtime_libs)
    if not shared:
        dynamic_deps = [lib.file for lib in dep_inputs.libs if lib.dynamic] + \
                       [f for f in dep_inputs.extra_inputs if _is_dynamic_library(f)] + \
                       dynamic_deps

    variables = {
        "coverage_link_flags": coverage_link_flags,
        "dep_link_flags": _normalize_dep_link_flags(dep_inputs.flags),
        "libraries_to_link": [
            struct(file = lib.file, whole_archive = lib.alwayslink, dynamic = lib.dynamic)
            for lib in dep_inputs.libs
        ],
        "macos_deployment_target": macos_deployment_target,
        "objects": objects,
        "output": output,
        "output_basename": output.basename,
        "runtime_libraries": ada_toolchain.static_runtime_lib,
        "runtime_library_search_directories": _runtime_library_search_directories(output, dynamic_deps),
        "user_link_flags": user_link_flags,
    }

    args = _new_args(actions)
    args.add("--")
    args.add(compiler)
    args.add_all(_toolchain_args(
        ada_toolchain,
        action,
        variables,
        ada_features.feature_args(ada_toolchain, features),
    ))

    actions.run(
        executable = ada_toolchain.process_wrapper,
        arguments = [args],
        inputs = depset(
            [compiler] + objects + [lib.file for lib in dep_inputs.libs] +
            dep_inputs.extra_inputs + ada_toolchain.static_runtime_lib,
            transitive = [
                ada_toolchain.ada_std,
                ada_toolchain.compiler_lib,
                ada_toolchain.args_files,
                ada_features.feature_files(ada_toolchain, features),
            ],
        ),
        outputs = [output],
        env = env,
        mnemonic = "AdaLinkShared" if shared else "AdaLink",
        progress_message = "Linking %s %s" % ("shared Ada library" if shared else "Ada executable", name),
    )
    return output

ada_common = struct(
    compile_interface = _compile_interface,
    compile_full = _compile_full,
    bind = _bind,
    bind_library = _bind_library,
    archive = _archive,
    link = _link,
    stage_dynamic_runtime_libs = _stage_dynamic_runtime_libs,
    artifact_name = _artifact_name,
    is_dynamic_library = _is_dynamic_library,
    gcov_link_flags = _gcov_link_flags,
    create_linker_input = cc_common.create_linker_input,
    create_linking_context = cc_common.create_linking_context,
    merge_linking_contexts = cc_common.merge_linking_contexts,
)
