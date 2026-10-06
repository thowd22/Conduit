# Conduit shell integration for bash.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Conduit authors. Written for Conduit; not derived from
# any other terminal's integration script.
#
# Reports the working directory (OSC 7) and marks the prompt and each command
# (OSC 133) so the terminal knows where the shell is and where its output is.
#
# Conduit loads this by starting bash in POSIX mode with ENV pointing here and
# CONDUIT_BASH_INJECT=1 set. POSIX mode reads ENV instead of the usual startup
# files, so this file first turns POSIX mode off again and replays the startup a
# normal interactive bash would have done. To use it by hand instead, add to
# ~/.bashrc:
#
#     [ -n "$CONDUIT_SHELL_INTEGRATION_DIR" ] && . "$CONDUIT_SHELL_INTEGRATION_DIR/bash/conduit.bash"

# Interactive shells only, and only once.
[[ $- == *i* ]] || return 0
[[ -n ${__conduit_loaded-} ]] && return 0
__conduit_loaded=1

if [[ -n ${CONDUIT_BASH_INJECT-} ]]; then
    builtin unset CONDUIT_BASH_INJECT ENV
    builtin set +o posix
    # The startup a non-login interactive bash runs, which POSIX mode skipped.
    if [[ -r /etc/bash.bashrc ]]; then builtin source /etc/bash.bashrc; fi
    if [[ -r ~/.bashrc ]]; then builtin source ~/.bashrc; fi
fi

# The prompt is about to be drawn: close the previous command with its status,
# report the directory, and open a new prompt. Runs first in PROMPT_COMMAND, so
# $? is still the command's status, and it hands that status back so anything
# after it in PROMPT_COMMAND sees the same $?.
__conduit_precmd() {
    local status=$?
    if [[ -n ${__conduit_in_command-} ]]; then
        builtin printf '\e]133;D;%s\a' "$status"
        __conduit_in_command=
    fi
    builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "${HOSTNAME-}" "$PWD"
    builtin printf '\e]133;A\a'
    return "$status"
}

# The end of the prompt is the start of input. Runs last in PROMPT_COMMAND, so a
# theme that rebuilds PS1 from its own PROMPT_COMMAND entry still gets the mark.
__conduit_mark_input() {
    [[ $PS1 == *'\e]133;B\a'* ]] || PS1="$PS1"'\[\e]133;B\a\]'
}

# First and last in PROMPT_COMMAND, keeping whatever the user put in between.
# bash >= 5.1 also accepts PROMPT_COMMAND as an array.
if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
    PROMPT_COMMAND=(__conduit_precmd "${PROMPT_COMMAND[@]}" __conduit_mark_input)
else
    PROMPT_COMMAND="__conduit_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __conduit_mark_input"
fi

# A command is about to run: mark the start of its output. PS0 is printed once
# per command line and never for the prompt. The subscript is evaluated in the
# current shell (a $(...) would run in a subshell and lose the assignment) and
# the unset element expands to nothing, so this only sets the flag.
PS0='\e]133;C\a${__conduit_mark[__conduit_in_command=1]}'"${PS0-}"
