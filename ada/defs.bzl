"""# Ada rules"""

load(
    ":ada_binary.bzl",
    _ada_binary = "ada_binary",
)
load(
    ":ada_library.bzl",
    _ada_library = "ada_library",
)
load(
    ":ada_shared_library.bzl",
    _ada_shared_library = "ada_shared_library",
)
load(
    ":ada_static_library.bzl",
    _ada_static_library = "ada_static_library",
)
load(
    ":ada_test.bzl",
    _ada_test = "ada_test",
)
load(
    ":ada_toolchain.bzl",
    _ada_toolchain = "ada_toolchain",
)

ada_binary = _ada_binary
ada_library = _ada_library
ada_shared_library = _ada_shared_library
ada_static_library = _ada_static_library
ada_test = _ada_test
ada_toolchain = _ada_toolchain
