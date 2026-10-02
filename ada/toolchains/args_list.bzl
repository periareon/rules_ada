"""# ada_args_list"""

load(
    "//ada/private:toolchain_config.bzl",
    _ada_args_list = "ada_args_list",
)

ada_args_list = _ada_args_list
