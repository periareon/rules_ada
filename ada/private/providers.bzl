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
        "transitive_objects": "depset[File]: Body .o files reachable through deps (link inputs).",
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
        bind_flags,
        binder,
        compile_flags,
        compiler,
        compiler_id,
        compiler_lib,
        gcov,
        label,
        link_flags,
        process_wrapper,
        target_triple):
    """AdaToolchainInfo constructor."""

    if process_wrapper.owner != Label("//ada/private/process_wrapper"):
        fail("AdaToolchainInfo.process_wrapper must be set to `Label(\"@rules_ada//ada/private/process_wrapper\")`")

    return {
        "ada_std": ada_std,
        "ar": ar,
        "bind_flags": bind_flags,
        "binder": binder,
        "compile_flags": compile_flags,
        "compiler": compiler,
        "compiler_id": compiler_id,
        "compiler_lib": compiler_lib,
        "gcov": gcov,
        "label": label,
        "link_flags": link_flags,
        "process_wrapper": process_wrapper,
        "target_triple": target_triple,
    }

AdaToolchainInfo, _new_ada_toolchain_info = provider(
    doc = "Information about a configured Ada toolchain.",
    fields = {
        "ada_std": "depset[File]: Ada standard library (adalib .ali and .a files, adainclude specs).",
        "ar": "File or None: The archiver executable. None when the GNAT archive does not include one; the CC toolchain's archiver is used as a fallback.",
        "bind_flags": "list[str]: Toolchain-level binder flags.",
        "binder": "File: The gnatbind executable for elaboration ordering.",
        "compile_flags": "list[str]: Toolchain-level compile flags.",
        "compiler": "File: The Ada compiler executable (gcc with GNAT support).",
        "compiler_id": "str: Compiler identifier (e.g., 'gnat').",
        "compiler_lib": "depset[File]: GCC support files (backends, shared libs, runtime libs).",
        "gcov": "File: The gcov executable for coverage, or None.",
        "label": "Label: The label of the toolchain target.",
        "link_flags": "list[str]: Toolchain-level link flags.",
        "process_wrapper": "File: The process wrapper executable for build actions.",
        "target_triple": "str: GCC target triple (e.g., 'aarch64-apple-darwin23.6.0', 'x86_64-pc-linux-gnu').",
    },
    init = _ada_toolchain_info_init,
)
