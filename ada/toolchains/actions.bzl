"""# Ada action names

Names of the actions an [`ada_args`](./ada_args.md) target can apply to.
Only the two link actions expose variables; see the toolchains documentation.
"""

load(
    "//ada/private:actions.bzl",
    _ACTIONS = "ACTIONS",
    _ALL_ACTIONS = "ALL_ACTIONS",
    _LINK_ACTIONS = "LINK_ACTIONS",
)

ACTIONS = _ACTIONS
ALL_ACTIONS = _ALL_ACTIONS
LINK_ACTIONS = _LINK_ACTIONS
