"""# Ada toolchain configuration rules"""

load(":actions.bzl", _ACTIONS = "ACTIONS", _ALL_ACTIONS = "ALL_ACTIONS", _LINK_ACTIONS = "LINK_ACTIONS")
load(":args.bzl", _ada_args = "ada_args")
load(":args_list.bzl", _ada_args_list = "ada_args_list")
load(":feature.bzl", _ada_feature = "ada_feature")
load(":nested_args.bzl", _ada_nested_args = "ada_nested_args")

ACTIONS = _ACTIONS
ALL_ACTIONS = _ALL_ACTIONS
LINK_ACTIONS = _LINK_ACTIONS
ada_args = _ada_args
ada_args_list = _ada_args_list
ada_feature = _ada_feature
ada_nested_args = _ada_nested_args
