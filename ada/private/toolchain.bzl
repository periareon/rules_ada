"""Ada toolchain rules."""

load(":providers.bzl", "AdaToolchainInfo")

TOOLCHAIN_TYPE = str(Label("//ada:toolchain_type"))

def _ada_toolchain_impl(ctx):
    make_variable_info = platform_common.TemplateVariableInfo({
        "ADA": ctx.file.compiler.path,
        "GNATBIND": ctx.file.binder.path,
    })

    ada_toolchain_info = AdaToolchainInfo(
        label = ctx.label,
        compiler_id = ctx.attr.compiler_id,
        compiler = ctx.file.compiler,
        binder = ctx.file.binder,
        ar = ctx.file.ar,
        gcov = ctx.file.gcov if ctx.attr.gcov else None,
        compile_flags = ctx.attr.compile_flags,
        bind_flags = ctx.attr.bind_flags,
        link_flags = ctx.attr.link_flags,
        ada_std = ctx.attr.ada_std.files if ctx.attr.ada_std else depset(),
        compiler_lib = ctx.attr.compiler_lib.files if ctx.attr.compiler_lib else depset(),
        process_wrapper = ctx.executable._process_wrapper,
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
Defines an Ada toolchain providing the GNAT compiler (gcc), binder (gnatbind),
archiver (ar), and compilation/linking flags.

Example:

```python
load("@rules_ada//ada:ada_toolchain.bzl", "ada_toolchain")

ada_toolchain(
    name = "gnat_toolchain",
    compiler = "@gnat//:bin/gcc",
    binder = "@gnat//:bin/gnatbind",
    ar = "@gnat//:bin/ar",
    ada_std = "@gnat//:ada_std",
    compiler_lib = "@gnat//:compiler_lib",
    gcov = "@gnat//:bin/gcov",
    compile_flags = ["-O2"],
    link_flags = ["-lgnat"],
)
```
""",
    implementation = _ada_toolchain_impl,
    attrs = {
        "ada_std": attr.label(
            doc = "The Ada standard library (adalib and adainclude).",
            cfg = "exec",
        ),
        "ar": attr.label(
            doc = "The archiver executable (ar or gcc-ar).",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "bind_flags": attr.string_list(
            doc = "Additional flags for gnatbind.",
        ),
        "binder": attr.label(
            doc = "The gnatbind executable for elaboration ordering and consistency checking.",
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
            doc = "GCC support files (backends, shared libs, runtime libs like libgcc.a, libatomic.a).",
            cfg = "exec",
        ),
        "gcov": attr.label(
            doc = "The gcov executable for coverage support.",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "link_flags": attr.string_list(
            doc = "Additional linker flags (e.g., -lgnat, -lgnarl).",
        ),
        "_process_wrapper": attr.label(
            default = Label("//ada/private/process_wrapper"),
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
)

def _current_ada_toolchain_impl(ctx):
    toolchain_info = ctx.toolchains[TOOLCHAIN_TYPE]
    ada_toolchain = toolchain_info.ada_toolchain
    return [toolchain_info, ada_toolchain]

current_ada_toolchain = rule(
    doc = "Provides access to the currently selected Ada toolchain.",
    implementation = _current_ada_toolchain_impl,
    toolchains = [TOOLCHAIN_TYPE],
)
