# Conduit shell integration for fish.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Conduit authors. Written for Conduit; not derived from
# any other terminal's integration script.
#
# UNTESTED BY DECISION: fish is not exercised by Conduit's tests (the project
# chose to prove bash and zsh only). This file is written to the same contract
# as the bash and zsh scripts but has never been run against a real fish.
#
# Reports the working directory (OSC 7) and marks the prompt and each command
# (OSC 133). Conduit loads it by prepending its integration directory to
# XDG_DATA_DIRS, so fish finds it in vendor_conf.d at startup. To load it by
# hand instead, add to ~/.config/fish/config.fish:
#
#     test -n "$CONDUIT_SHELL_INTEGRATION_DIR"; and source "$CONDUIT_SHELL_INTEGRATION_DIR/fish/vendor_conf.d/conduit.fish"

status is-interactive; or exit 0
set -q __conduit_loaded; and exit 0
set -g __conduit_loaded 1
set -g __conduit_in_command

# Take Conduit's directory back out of XDG_DATA_DIRS, so programs started from
# this shell see the user's own value.
if set -q CONDUIT_SHELL_INTEGRATION_XDG_DIR
    set -l kept
    for dir in $XDG_DATA_DIRS
        test "$dir" = "$CONDUIT_SHELL_INTEGRATION_XDG_DIR"; or set -a kept $dir
    end
    if test (count $kept) -gt 0
        set -gx XDG_DATA_DIRS $kept
    else
        set -e XDG_DATA_DIRS
    end
    set -e CONDUIT_SHELL_INTEGRATION_XDG_DIR
end

function __conduit_prompt --on-event fish_prompt
    set -l exit_code $status
    if test -n "$__conduit_in_command"
        printf '\e]133;D;%s\a' $exit_code
        set -g __conduit_in_command
    end
    printf '\e]7;kitty-shell-cwd://%s%s\a' (prompt_hostname) "$PWD"
    printf '\e]133;A\a'
end

function __conduit_preexec --on-event fish_preexec
    set -g __conduit_in_command 1
    printf '\e]133;C\a'
end
