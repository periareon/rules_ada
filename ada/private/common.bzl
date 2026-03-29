"""Common utilities for Ada compilation, binding, and linking."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

def _compile(
        *,
        actions,
        ada_toolchain,
        srcs,
        dep_sources = [],
        compile_data = [],
        compile_flags = [],
        coverage_enabled = False,
        name):
    """Compile Ada source files into object and ALI files.

    For each .adb file (and bodyless .ads files), runs gcc -c to produce
    a .o object file and a .ali Ada Library Information file.

    Ada compilation only requires .ads spec files from dependencies (not
    .ali files). The compiler reads specs for type checking; .ali files
    are only needed later by the binder.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        srcs: list[File] of Ada source files (.ads and .adb).
        dep_sources: list[depset[File]] of .ads spec files from dependencies.
        compile_data: list[File] of additional source files needed during
            compilation but not compiled independently (e.g., subunit bodies).
        compile_flags: list[str] of additional compiler flags (copts).
        coverage_enabled: bool whether to add gcov instrumentation flags.
        name: str rule name, used for output directory naming.

    Returns:
        struct with fields:
            objects: list[File] of .o files.
            ali_files: list[File] of .ali files.
            source_files: list[File] of .ads spec files from this target.
    """
    if not srcs:
        return struct(objects = [], ali_files = [], source_files = [])

    compiler = ada_toolchain.compiler
    process_wrapper = ada_toolchain.process_wrapper

    ads_files = [s for s in srcs if s.extension == "ads"]
    adb_files = [s for s in srcs if s.extension == "adb"]

    adb_stems = {s.basename.rsplit(".", 1)[0]: True for s in adb_files}
    files_to_compile = list(adb_files)
    for ads in ads_files:
        stem = ads.basename.rsplit(".", 1)[0]
        if stem not in adb_stems:
            files_to_compile.append(ads)

    dep_source_files = []
    for ds in dep_sources:
        dep_source_files.extend(ds.to_list())

    include_dirs = {}
    for f in srcs:
        include_dirs[f.dirname] = True
    for f in dep_source_files:
        include_dirs[f.dirname] = True
    for f in compile_data:
        include_dirs[f.dirname] = True

    i_flags = ["-I" + d for d in sorted(include_dirs.keys())]

    objects = []
    ali_files = []
    gcno_files = []

    for src in files_to_compile:
        src_stem = src.basename.rsplit(".", 1)[0]

        obj = actions.declare_file(paths.join("_objs", name, src_stem + ".o"))
        ali = actions.declare_file(paths.join("_objs", name, src_stem + ".ali"))
        objects.append(obj)
        ali_files.append(ali)
        outputs = [obj, ali]

        action_inputs = depset(
            direct = [compiler] + list(srcs) + dep_source_files + compile_data,
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib],
        )

        args = actions.args()

        # GNAT may place .ali in CWD (older versions) or alongside
        # the .o file (modern GNAT). Handle both cases.
        args.add("--rename-if-exists")
        args.add(src_stem + ".ali")
        args.add(ali)
        args.add("--")
        args.add(compiler)
        args.add("-c")
        args.add_all(i_flags)
        args.add_all(ada_toolchain.compile_flags)
        args.add_all(compile_flags)
        if coverage_enabled:
            args.add("--coverage")
            gcno = actions.declare_file(paths.join("_objs", name, src_stem + ".gcno"))
            gcno_files.append(gcno)
            outputs.append(gcno)
        args.add(src)
        args.add("-o")
        args.add(obj)

        actions.run(
            executable = process_wrapper,
            arguments = [args],
            inputs = action_inputs,
            outputs = outputs,
            mnemonic = "AdaCompile",
            progress_message = "Compiling Ada source %s" % src.short_path,
        )

    return struct(
        objects = objects,
        ali_files = ali_files,
        source_files = ads_files,
        gcno_files = gcno_files,
    )

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

    search_dirs = {}
    for ali in all_ali_files:
        search_dirs[ali.dirname] = True
    for src in transitive_sources:
        search_dirs[src.dirname] = True

    # gnatbind refuses directory separators in -o, so we run it in the
    # exec root (CWD) with a flat output name and rename afterward.
    args = actions.args()
    args.add("--rename")
    args.add(binder_basename + ".adb")
    args.add(binder_adb)
    args.add("--rename")
    args.add(binder_basename + ".ads")
    args.add(binder_ads)
    args.add("--")

    # Command 1: gnatbind
    args.add(binder)
    args.add_all(ada_toolchain.bind_flags)
    for search_dir in sorted(search_dirs.keys()):
        args.add("-I" + search_dir)
    args.add("-o")
    args.add(binder_basename + ".adb")
    args.add(main_ali)

    # Command 2: compile the binder output
    args.add("++")
    args.add(compiler)
    args.add("-c")
    args.add("-I.")
    args.add(binder_basename + ".adb")
    args.add("-o")
    args.add(binder_obj)

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

def _collect_cc_link_inputs(linking_contexts, prefer_static = True):
    """Extract library files and link flags from dependency CcLinkingContexts.

    Walks each LinkerInput to collect library artifacts, user link flags,
    and additional inputs so that GNAT gcc can consume them directly on the
    command line.

    Args:
        linking_contexts: list[CcLinkingContext] from dependencies.
        prefer_static: bool, when True prefer .a over .so.

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
                if prefer_static:
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
        name):
    """Create a static library archive from object files.

    Uses the toolchain's ar/gcc-ar if available, falling back to the
    system ar. Sets PATH so that gcc-ar (a thin wrapper) can locate
    the underlying ar binary in the sandbox.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        objects: list[File] of .o files to archive.
        name: str library name (output will be lib{name}.a).

    Returns:
        File: the static archive.
    """
    archive = actions.declare_file("lib" + name + ".a")
    ar = ada_toolchain.ar

    args = actions.args()
    args.add("rcs")
    args.add(archive)
    args.add_all(objects)

    if _is_windows(ada_toolchain):
        path_env = ar.dirname
    else:
        path_env = ar.dirname + ":/usr/bin:/bin"

    actions.run(
        executable = ar,
        arguments = [args],
        inputs = depset(objects, transitive = [ada_toolchain.compiler_lib]),
        outputs = [archive],
        env = {"PATH": path_env},
        mnemonic = "AdaArchive",
        progress_message = "Archiving Ada library %s" % name,
    )
    return archive

def _is_macos(ada_toolchain):
    """Detect macOS from the toolchain's compiler path."""
    return "darwin" in ada_toolchain.compiler.path

def _is_windows(ada_toolchain):
    """Detect Windows from the toolchain's compiler path."""
    return ada_toolchain.compiler.path.endswith(".exe")

def _link_shared(
        *,
        actions,
        ada_toolchain,
        objects,
        dep_linking_contexts = [],
        user_link_flags = [],
        name):
    """Create a shared library using GNAT gcc -shared.

    On Linux, the static GNAT runtime (libgnat.a, libgnarl.a) is excluded
    because it is not built with -fPIC. Runtime symbols are resolved at
    load time from the executable. On macOS, the same applies with
    -Wl,-undefined,dynamic_lookup. On Windows, PIC is not required, so
    the GNAT runtime is linked directly into the DLL.

    Args:
        actions: ctx.actions object.
        ada_toolchain: AdaToolchainInfo provider.
        objects: list[File] of .o files.
        dep_linking_contexts: list[CcLinkingContext] from dependencies.
        user_link_flags: list[str] user linker flags.
        name: str library name (output will be lib{name}.so, .dylib, or .dll).

    Returns:
        File: the shared library.
    """
    if _is_windows(ada_toolchain):
        shared_lib = actions.declare_file(name + ".dll")
    else:
        shared_lib = actions.declare_file("lib" + name + ".so")
    compiler = ada_toolchain.compiler

    dep_libs, dep_flags, dep_extra_inputs = _collect_cc_link_inputs(dep_linking_contexts, prefer_static = False)
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

    args = actions.args()
    args.add("-shared")
    args.add_all(objects)
    args.add_all(dep_libs)
    args.add_all(dep_flags)
    args.add_all(all_link_flags)
    args.add("-o")
    args.add(shared_lib)

    actions.run(
        executable = compiler,
        arguments = [args],
        inputs = depset(
            objects + dep_libs + dep_extra_inputs,
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib],
        ),
        outputs = [shared_lib],
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

    args = actions.args()
    args.add_all(objects)
    args.add_all(dep_libs)
    args.add_all(dep_flags)
    args.add_all(all_link_flags)
    args.add("-o")
    args.add(executable)

    actions.run(
        executable = compiler,
        arguments = [args],
        inputs = depset(
            objects + all_dep_files,
            transitive = [ada_toolchain.ada_std, ada_toolchain.compiler_lib],
        ),
        outputs = [executable],
        mnemonic = "AdaLink",
        progress_message = "Linking Ada executable %s" % name,
    )
    return executable

ada_common = struct(
    compile = _compile,
    bind = _bind,
    archive = _archive,
    link_shared = _link_shared,
    link_executable = _link_executable,
    resolve_link_flags = _resolve_link_flags,
    gcov_link_flags = _gcov_link_flags,
    create_linker_input = cc_common.create_linker_input,
    create_linking_context = cc_common.create_linking_context,
    merge_linking_contexts = cc_common.merge_linking_contexts,
)
