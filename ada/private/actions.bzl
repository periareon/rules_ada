"""Names of the actions an `ada_args` target can apply to."""

ACTIONS = struct(
    compile = "compile",
    bind = "bind",
    archive = "archive",
    link_executable = "link_executable",
    link_shared_library = "link_shared_library",
)

LINK_ACTIONS = [
    ACTIONS.link_executable,
    ACTIONS.link_shared_library,
]

ALL_ACTIONS = [
    ACTIONS.compile,
    ACTIONS.bind,
    ACTIONS.archive,
    ACTIONS.link_executable,
    ACTIONS.link_shared_library,
]
