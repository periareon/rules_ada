"""Ada rule providers."""

AdaInfo = provider(
    doc = "Carries the spec/body ALI/object/source closure of an Ada compilation target.",
    fields = {
        "cc_info": "CcInfo: Compilation and linking context for cc_common integration.",
        "direct_body_alis": "depset[File]: Body ALIs emitted by this target only.",
        "direct_objects": "depset[File]: Body .o files emitted by this target only.",
        "direct_spec_alis": "depset[File]: Spec ALIs emitted by this target only.",
        "transitive_body_alidirs": "depset[str]: Dirs containing body ALIs.",
        "transitive_body_alis": "depset[File]: Body ALIs reachable through deps (binder inputs).",
        "transitive_exported_bodies": "depset[File]: .adb sources from libs marked exports_bodies; compile inputs for cross-lib generic instantiation.",
        "transitive_objects": "depset[File]: Body .o files reachable through deps (link inputs). Objects inside an `ada_shared_library` are not included; that code is reached through its CcInfo.",
        "transitive_spec_alidirs": "depset[str]: Dirs containing spec ALIs.",
        "transitive_spec_alis": "depset[File]: Spec ALIs reachable through deps (compile inputs).",
        "transitive_specs": "depset[File]: .ads files reachable through deps.",
        "transitive_srcdirs": "depset[str]: Dirs to add via -I for .ads source lookup.",
        "units": "list[struct(stem, spec, body, spec_ali, body_ali, object)]: Per-unit compilation info.",
    },
)

def merge_ada_infos(deps):
    """Combine AdaInfo from deps into an aggregate view used by action helpers."""
    return struct(
        transitive_spec_alis = depset(transitive = [d[AdaInfo].transitive_spec_alis for d in deps if AdaInfo in d]),
        transitive_body_alis = depset(transitive = [d[AdaInfo].transitive_body_alis for d in deps if AdaInfo in d]),
        transitive_objects = depset(transitive = [d[AdaInfo].transitive_objects for d in deps if AdaInfo in d]),
        transitive_specs = depset(transitive = [d[AdaInfo].transitive_specs for d in deps if AdaInfo in d]),
        transitive_exported_bodies = depset(transitive = [d[AdaInfo].transitive_exported_bodies for d in deps if AdaInfo in d]),
        transitive_srcdirs = depset(transitive = [d[AdaInfo].transitive_srcdirs for d in deps if AdaInfo in d]),
        transitive_spec_alidirs = depset(transitive = [d[AdaInfo].transitive_spec_alidirs for d in deps if AdaInfo in d]),
        transitive_body_alidirs = depset(transitive = [d[AdaInfo].transitive_body_alidirs for d in deps if AdaInfo in d]),
    )

def _ada_toolchain_info_init(
        ada_std,
        ar,
        args,
        args_files,
        artifact_name_patterns,
        bind_flags,
        binder,
        compile_flags,
        compiler,
        compiler_id,
        compiler_lib,
        dynamic_runtime_lib,
        enabled_features,
        gcov,
        known_features,
        label,
        process_wrapper,
        static_runtime_lib,
        target_triple):
    """AdaToolchainInfo constructor."""

    if process_wrapper.owner != Label("//ada/private/process_wrapper"):
        fail("AdaToolchainInfo.process_wrapper must be set to `Label(\"@rules_ada//ada/private/process_wrapper\")`")
    if type(static_runtime_lib) != "list" or type(dynamic_runtime_lib) != "list":
        fail("AdaToolchainInfo.static_runtime_lib and dynamic_runtime_lib must be lists of File (link order matters)")

    return {
        "ada_std": ada_std,
        "ar": ar,
        "args": args,
        "args_files": args_files,
        "artifact_name_patterns": artifact_name_patterns,
        "bind_flags": bind_flags,
        "binder": binder,
        "compile_flags": compile_flags,
        "compiler": compiler,
        "compiler_id": compiler_id,
        "compiler_lib": compiler_lib,
        "dynamic_runtime_lib": dynamic_runtime_lib,
        "enabled_features": enabled_features,
        "gcov": gcov,
        "known_features": known_features,
        "label": label,
        "process_wrapper": process_wrapper,
        "static_runtime_lib": static_runtime_lib,
        "target_triple": target_triple,
    }

AdaToolchainInfo, _new_ada_toolchain_info = provider(
    doc = "Information about a configured Ada toolchain.",
    fields = {
        "ada_std": "depset[File]: Ada standard library (adalib .ali and .a files, adainclude specs).",
        "ar": "File or None: The archiver executable. None when the GNAT archive does not include one; the CC toolchain's archiver is used as a fallback.",
        "args": "tuple[AdaArgsInfo]: Arguments expanded into every action, in command-line order.",
        "args_files": "depset[File]: Files referenced by `args`, added to every action's inputs.",
        "artifact_name_patterns": "dict[str, str]: Output file name pattern per category (`executable`, `shared_library`, `static_library`) with `%{name}` for the target name.",
        "bind_flags": "list[str]: Toolchain-level binder flags.",
        "binder": "File: The gnatbind executable for elaboration ordering.",
        "compile_flags": "list[str]: Toolchain-level compile flags.",
        "compiler": "File: The Ada compiler executable (gcc with GNAT support).",
        "compiler_id": "str: Compiler identifier (e.g., 'gnat').",
        "compiler_lib": "depset[File]: GCC support files (backends, shared libs, runtime libs).",
        "dynamic_runtime_lib": "list[File]: Shared runtime libraries staged beside each linked output when the `static_libgcc` feature is disabled (e.g. libgcc_s.1.1.dylib).",
        "enabled_features": "tuple[AdaFeatureInfo]: Features on by default for every target using this toolchain.",
        "gcov": "File: The gcov executable for coverage, or None.",
        "known_features": "tuple[AdaFeatureInfo]: Features the toolchain understands, in the order their arguments are emitted.",
        "label": "Label: The label of the toolchain target.",
        "process_wrapper": "File: The process wrapper executable for build actions.",
        "static_runtime_lib": "list[File]: Runtime archives in link order (libgnarl.a, libgnat.a, libgcc.a, ...), linked into executables and Windows shared libraries after the dependency libraries.",
        "target_triple": "str: GCC target triple (e.g., 'aarch64-apple-darwin24.6.0', 'x86_64-pc-linux-gnu'). Informational; no rule behaviour depends on it.",
    },
    init = _ada_toolchain_info_init,
)
