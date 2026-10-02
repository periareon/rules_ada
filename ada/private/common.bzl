"""Common utilities for Ada compilation, binding, and linking."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

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
    link_flags = []
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
            link_flags.extend(linker_input.user_link_flags)
            extra_inputs.extend(linker_input.additional_inputs)
    return struct(libs = libs, flags = link_flags, extra_inputs = extra_inputs)

def _add_link_libraries(args, libs, ada_toolchain):
    """Add dependency libraries to a link command line.

    Archives marked `alwayslink` (cc_library(alwayslink = True)) must be
    linked in full so that unreferenced members such as constructors and
    registration objects survive; plain archive members are only pulled in
    when they resolve an undefined symbol.

    Args:
        args: ctx.actions.args() being populated.
        libs: list[struct(file, dynamic, alwayslink)] from _collect_cc_link_inputs.
        ada_toolchain: AdaToolchainInfo provider.
    """
    macos = _is_macos(ada_toolchain)
    for lib in libs:
        if not lib.alwayslink:
            args.add(lib.file)
        elif macos:
            args.add(lib.file, format = "-Wl,-force_load,%s")
        else:
            args.add("-Wl,--whole-archive")
            args.add(lib.file)
            args.add("-Wl,--no-whole-archive")

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

def _rpath_flags(executable, dynamic_libs, ada_toolchain):
    """Linker flags so an executable finds its shared library deps at runtime.

    One entry is emitted per distinct directory, relative to the executable,
    for both layouts the binary runs from: bazel-bin (`File.path`) and the
    runfiles tree (`File.short_path`). The two differ for files in external
    repositories.

    macOS uses `@executable_path` rather than `@loader_path`: they resolve
    identically for an executable, but GCC's Darwin driver may itself add an
    `-rpath @loader_path` (when built with --enable-darwin-at-rpath), and
    dyld on macOS 15.4+ refuses to load a binary with a duplicate LC_RPATH.
    A distinct string can never collide with it.

    Args:
        executable: File, the executable being linked.
        dynamic_libs: list[File] of shared libraries it links against.
        ada_toolchain: AdaToolchainInfo provider.

    Returns:
        list[str]: `-Wl,-rpath,...` flags.
    """
    origin = "@executable_path" if _is_macos(ada_toolchain) else "$ORIGIN"
    rel_dirs = {}
    for lib in dynamic_libs:
        rel_dirs[_relative_dir(executable.dirname, lib.dirname)] = True
        rel_dirs[_relative_dir(
            paths.dirname(executable.short_path),
            paths.dirname(lib.short_path),
        )] = True
    return [
        "-Wl,-rpath," + (origin + "/" + rel if rel else origin)
        for rel in rel_dirs.keys()
    ]

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
        args = _new_args(actions)
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

        args = _new_args(actions)
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

def _macos_link_flags(user_link_flags):
    """Driver flags that keep a macOS link independent of the output base.

    By default GCC's Darwin driver links `@rpath/libgcc_s.1.1.dylib` from its
    own installation and records absolute rpaths to the toolchain repository
    so the dylib can be found; see "Linking on macOS" in docs/src/toolchains.md.
    `-static-libgcc` removes the dylib and `-nodefaultrpaths` the paths. The
    `@executable_path` rpaths from `_rpath_flags` cover Bazel-built shared
    deps, so the driver's `@loader_path` entry is not missed.

    A user who asks for `-shared-libgcc` in `linkopts` keeps the driver's
    defaults, rpaths included, since that is the only way the dylib can load.

    Args:
        user_link_flags: list[str] user linker flags (linkopts).

    Returns:
        list[str]: flags to append to the link command line.
    """
    if "-shared-libgcc" in user_link_flags:
        return []
    return ["-static-libgcc", "-nodefaultrpaths"]

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

    dep_inputs = _collect_cc_link_inputs(dep_linking_contexts, use_pic = True)
    dep_flags = dep_inputs.flags
    if _is_windows(ada_toolchain):
        dep_flags = _msvc_to_mingw_flags(dep_flags)
    dep_files = [lib.file for lib in dep_inputs.libs]

    all_link_flags = list(user_link_flags)

    if _is_macos(ada_toolchain):
        all_link_flags.append("-Wl,-undefined,dynamic_lookup")
        all_link_flags.append("-Wl,-install_name,@rpath/lib" + name + ".so")
        all_link_flags.extend(_macos_link_flags(user_link_flags))
    elif _is_windows(ada_toolchain):
        all_link_flags.extend(_resolve_link_flags(ada_toolchain))
    else:
        all_link_flags.append("-Wl,-soname,lib" + name + ".so")

    if coverage_enabled:
        all_link_flags.extend(_gcov_link_flags(ada_toolchain))
        all_link_flags.extend(cc_coverage_link_flags)

    process_wrapper = ada_toolchain.process_wrapper

    args = _new_args(actions)
    args.add("--")
    args.add(compiler)
    args.add("-shared")
    args.add_all(objects)
    _add_link_libraries(args, dep_inputs.libs, ada_toolchain)
    args.add_all(dep_flags)
    args.add_all(all_link_flags)
    args.add("-o")
    args.add(shared_lib)

    actions.run(
        executable = process_wrapper,
        arguments = [args],
        inputs = depset(
            [compiler] + objects + dep_files + dep_inputs.extra_inputs,
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

    dep_inputs = _collect_cc_link_inputs(
        dep_linking_contexts,
        prefer_static = link_deps_statically,
    )
    dep_flags = dep_inputs.flags
    if _is_windows(ada_toolchain):
        dep_flags = _msvc_to_mingw_flags(dep_flags)

    all_link_flags = list(user_link_flags) + _resolve_link_flags(ada_toolchain)
    if _is_macos(ada_toolchain):
        all_link_flags.extend(_macos_link_flags(user_link_flags))
    if coverage_enabled:
        all_link_flags.extend(_gcov_link_flags(ada_toolchain))
        all_link_flags.extend(cc_coverage_link_flags)

    all_dep_files = [lib.file for lib in dep_inputs.libs] + dep_inputs.extra_inputs

    # extra_inputs are checked by extension for the no-CC-toolchain case,
    # where a shared library can only travel as a raw path plus input.
    dynamic_deps = [lib.file for lib in dep_inputs.libs if lib.dynamic] + \
                   [f for f in dep_inputs.extra_inputs if _is_dynamic_library(f)]

    # Windows has no rpath: DLLs are found next to the executable or on PATH.
    if dynamic_deps and not _is_windows(ada_toolchain):
        all_link_flags.extend(_rpath_flags(executable, dynamic_deps, ada_toolchain))

    process_wrapper = ada_toolchain.process_wrapper

    # GNU ld resolves archives in a single pass, so mutually dependent
    # archives from C/C++/Rust deps are wrapped in a group. Apple's and
    # (effectively) MinGW's linkers do not need it.
    is_elf = not _is_macos(ada_toolchain) and not _is_windows(ada_toolchain)
    use_group = (dep_inputs.libs or dep_flags) and is_elf

    args = _new_args(actions)
    args.add("--")
    args.add(compiler)
    args.add_all(objects)
    if use_group:
        args.add("-Wl,--start-group")
    _add_link_libraries(args, dep_inputs.libs, ada_toolchain)
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
    is_dynamic_library = _is_dynamic_library,
    gcov_link_flags = _gcov_link_flags,
    create_linker_input = cc_common.create_linker_input,
    create_linking_context = cc_common.create_linking_context,
    merge_linking_contexts = cc_common.merge_linking_contexts,
)
