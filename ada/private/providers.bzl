"""Ada rule providers."""

AdaInfo = provider(
    doc = "Information about Ada targets.",
    fields = {
        "ali_files": "depset[File]: Transitive Ada Library Information files (.ali), consumed by the binder.",
        "cc_info": "CcInfo: Compilation and linking context for cc_common integration.",
        "objects": "depset[File]: Compiled object files.",
        "transitive_sources": "depset[File]: Transitive Ada spec files (.ads) needed for downstream compilation.",
    },
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
        process_wrapper):
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
    }

AdaToolchainInfo, _new_ada_toolchain_info = provider(
    doc = "Information about a configured Ada toolchain.",
    fields = {
        "ada_std": "depset[File]: Ada standard library (adalib .ali and .a files, adainclude specs).",
        "ar": "File: The archiver executable (ar or gcc-ar).",
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
    },
    init = _ada_toolchain_info_init,
)
