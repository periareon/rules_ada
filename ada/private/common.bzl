"""Common utilities for Ada compilation, binding, and linking."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

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

    args = actions.args()
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

    args = actions.args()
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
    args = actions.args()
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
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib],
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

    args = actions.args()
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
            ],
        ),
        outputs = [binder_adb, binder_ads, binder_obj],
        mnemonic = "AdaBind",
        progress_message = "Binding Ada library %s" % lib_name,
    )

    return binder_obj

def _resolve_link_flags(ada_toolchain):
    """Resolve relative paths in toolchain link flags against the repo root.

    The GNAT toolchain stores library paths (e.g. adalib/libgnat.a) relative
    to its repository root. This resolves them to execroot-relative paths
    using the compiler location as an anchor (always in <repo>/bin/).

    Args:
        ada_toolchain: AdaToolchainInfo provider.

    Returns:
        list[str]: Resolved link flags.
    """
    repo_root = paths.dirname(ada_toolchain.compiler.dirname)
    resolved = []
    for flag in ada_toolchain.link_flags:
        if flag.startswith("-L") and not flag[2:].startswith("/"):
            resolved.append("-L" + repo_root + "/" + flag[2:])
        elif not flag.startswith("-") and not flag.startswith("/"):
            resolved.append(repo_root + "/" + flag)
        else:
            resolved.append(flag)
    return resolved

def _gcov_link_flags(ada_toolchain):
    """Return resolved link flags for libgcov.a from the GNAT toolchain.

    Derives the path from the existing libgcc.a link flag, since libgcov.a
    is always in the same GCC library directory.

    Args:
        ada_toolchain: AdaToolchainInfo provider.

    Returns:
        list[str]: Resolved link flags for gcov, or empty list if not found.
    """
    repo_root = paths.dirname(ada_toolchain.compiler.dirname)
    for flag in ada_toolchain.link_flags:
        if flag.endswith("/libgcc.a"):
            return [repo_root + "/" + flag.rsplit("/", 1)[0] + "/libgcov.a"]
    return []

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
        tuple of (list[File], list[str], list[File]): library files (used
        as both action inputs and command-line paths), link flags (passed
        as-is), and extra input files (action inputs only, their paths
        are already encoded in link flags).
    """
    lib_files = []
    link_flags = []
    extra_inputs = []
    for lc in linking_contexts:
        for linker_input in lc.linker_inputs.to_list():
            for lib in linker_input.libraries:
                if use_pic:
                    f = lib.pic_static_library or lib.static_library or lib.dynamic_library
                elif prefer_static:
                    f = lib.static_library or lib.pic_static_library or lib.dynamic_library
                else:
                    f = lib.dynamic_library or lib.static_library or lib.pic_static_library
                if f:
                    lib_files.append(f)
            link_flags.extend(linker_input.user_link_flags)
            extra_inputs.extend(linker_input.additional_inputs)
    return lib_files, link_flags, extra_inputs

def _msvc_to_mingw_flags(link_flags):
    """Convert MSVC-style .lib references to MinGW -l flags.

    When C/C++ or Rust dependencies provide Windows system library names
    in MSVC format (e.g. advapi32.lib), MinGW gcc needs them as -l flags
    (e.g. -ladvapi32). Only converts bare names without path separators.
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
        name: str library name (output will be lib{name}.a).
        cc_toolchain: struct with ar_path (str) and all_files (depset),
            or None. Used as fallback when ada_toolchain.ar is None.
        env: dict[str, str] environment variables for the action.

    Returns:
        File: the static archive.
    """
    archive = actions.declare_file("lib" + name + ".a")
    ar = ada_toolchain.ar
    process_wrapper = ada_toolchain.process_wrapper

    if ar:
        args = actions.args()
        args.add("--")
        args.add(ar)
        args.add("rcs")
        args.add(archive)
        args.add_all(objects)

        actions.run(
            executable = process_wrapper,
            arguments = [args],
            inputs = depset([ar] + objects, transitive = [ada_toolchain.compiler_lib]),
            outputs = [archive],
            env = env,
            mnemonic = "AdaArchive",
            progress_message = "Archiving Ada library %s" % name,
        )
    elif cc_toolchain:
        is_libtool = cc_toolchain.ar_path.endswith("/libtool") or cc_toolchain.ar_path == "libtool"

        args = actions.args()
        args.add("--")
        args.add(cc_toolchain.ar_path)
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
            inputs = depset(objects, transitive = [ada_toolchain.compiler_lib]),
            outputs = [archive],
            env = env,
            mnemonic = "AdaArchive",
            progress_message = "Archiving Ada library %s" % name,
        )
    else:
        fail("No archiver available: GNAT toolchain has no ar and no CC toolchain fallback was provided")

    return archive

def _is_macos(ada_toolchain):
    """Detect macOS from toolchain target triple."""
    return "darwin" in ada_toolchain.target_triple

def _is_windows(ada_toolchain):
    """Detect Windows from toolchain target triple."""
    triple = ada_toolchain.target_triple
    return "windows" in triple or "mingw" in triple or "msvc" in triple

def _link_shared(
        *,
        actions,
        ada_toolchain,
        objects,
        dep_linking_contexts = [],
        user_link_flags = [],
        coverage_enabled = False,
        cc_coverage_link_flags = [],
        env = {},
        name):
    """Create a shared library using GNAT gcc -shared.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        objects: list[File] of .o files.
        dep_linking_contexts: list[CcLinkingContext] from dependencies.
        user_link_flags: list[str] user linker flags.
        coverage_enabled: bool whether to add gcov link flags.
        cc_coverage_link_flags: list[str] extra coverage link flags from
            the CC toolchain (e.g., LLVM profile runtime on macOS).
        env: dict[str, str] environment variables for the action.
        name: str library name (output will be lib{name}.so, .dylib, or .dll).

    Returns:
        File: the shared library.
    """
    if _is_windows(ada_toolchain):
        shared_lib = actions.declare_file(name + ".dll")
    else:
        shared_lib = actions.declare_file("lib" + name + ".so")
    compiler = ada_toolchain.compiler

    dep_libs, dep_flags, dep_extra_inputs = _collect_cc_link_inputs(dep_linking_contexts, use_pic = True)
    if _is_windows(ada_toolchain):
        dep_flags = _msvc_to_mingw_flags(dep_flags)

    all_link_flags = list(user_link_flags)

    if _is_macos(ada_toolchain):
        all_link_flags.append("-Wl,-undefined,dynamic_lookup")
        all_link_flags.append("-Wl,-install_name,@rpath/lib" + name + ".so")
    elif _is_windows(ada_toolchain):
        all_link_flags.extend(_resolve_link_flags(ada_toolchain))
    else:
        all_link_flags.append("-Wl,-soname,lib" + name + ".so")

    if coverage_enabled:
        all_link_flags.extend(_gcov_link_flags(ada_toolchain))
        all_link_flags.extend(cc_coverage_link_flags)

    process_wrapper = ada_toolchain.process_wrapper

    args = actions.args()
    args.add("--")
    args.add(compiler)
    args.add("-shared")
    args.add_all(objects)
    args.add_all(dep_libs)
    args.add_all(dep_flags)
    args.add_all(all_link_flags)
    args.add("-o")
    args.add(shared_lib)

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            [compiler] + objects + dep_libs + dep_extra_inputs,
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib],
        ),
        outputs = [shared_lib],
        env = env,
        mnemonic = "AdaLinkShared",
        progress_message = "Linking shared Ada library %s" % name,
    )
    return shared_lib

def _link_executable(
        *,
        actions,
        ada_toolchain,
        objects,
        dep_linking_contexts = [],
        user_link_flags = [],
        link_deps_statically = True,
        coverage_enabled = False,
        cc_coverage_link_flags = [],
        env = {},
        name):
    """Link Ada object files into an executable using GNAT gcc.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        objects: list[File] of .o files (including binder output).
        dep_linking_contexts: list[CcLinkingContext] from dependencies.
        user_link_flags: list[str] user linker flags (linkopts).
        link_deps_statically: bool prefer static linking for deps.
        coverage_enabled: bool whether to add gcov link flags.
        cc_coverage_link_flags: list[str] extra coverage link flags from
            the CC toolchain (e.g., LLVM profile runtime on macOS).
        env: dict[str, str] environment variables for the action.
        name: str output executable name.

    Returns:
        File: the linked executable.
    """
    if _is_windows(ada_toolchain):
        executable = actions.declare_file(name + ".exe")
    else:
        executable = actions.declare_file(name)
    compiler = ada_toolchain.compiler

    dep_libs, dep_flags, dep_extra_inputs = _collect_cc_link_inputs(
        dep_linking_contexts,
        prefer_static = link_deps_statically,
    )
    if _is_windows(ada_toolchain):
        dep_flags = _msvc_to_mingw_flags(dep_flags)

    all_link_flags = list(user_link_flags) + _resolve_link_flags(ada_toolchain)
    if coverage_enabled:
        all_link_flags.extend(_gcov_link_flags(ada_toolchain))
        all_link_flags.extend(cc_coverage_link_flags)

    all_dep_files = dep_libs + dep_extra_inputs
    has_dynamic_deps = any([f.extension in ("so", "dylib", "dll") for f in all_dep_files])
    if has_dynamic_deps:
        if _is_macos(ada_toolchain):
            all_link_flags.append("-Wl,-rpath,@loader_path")
        elif not _is_windows(ada_toolchain):
            all_link_flags.append("-Wl,-rpath,$ORIGIN")

    process_wrapper = ada_toolchain.process_wrapper

    args = actions.args()
    args.add("--")
    args.add(compiler)
    args.add_all(objects)
    use_group = (dep_libs or dep_flags) and not _is_macos(ada_toolchain) and not _is_windows(ada_toolchain)
    if use_group:
        args.add("-Wl,--start-group")
    args.add_all(dep_libs)
    args.add_all(dep_flags)
    if use_group:
        args.add("-Wl,--end-group")
    args.add_all(all_link_flags)
    args.add("-o")
    args.add(executable)

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            [compiler] + objects + all_dep_files,
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib],
        ),
        outputs = [executable],
        env = env,
        mnemonic = "AdaLink",
        progress_message = "Linking Ada executable %s" % name,
    )
    return executable

ada_common = struct(
    compile_interface = _compile_interface,
    compile_full = _compile_full,
    bind = _bind,
    bind_library = _bind_library,
    archive = _archive,
    link_shared = _link_shared,
    link_executable = _link_executable,
    resolve_link_flags = _resolve_link_flags,
    gcov_link_flags = _gcov_link_flags,
    create_linker_input = cc_common.create_linker_input,
    create_linking_context = cc_common.create_linking_context,
    merge_linking_contexts = cc_common.merge_linking_contexts,
)
