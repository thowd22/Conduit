# Conduit shell integration for zsh.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Conduit authors. Written for Conduit; not derived from
# any other terminal's integration script.
#
# Reports the working directory (OSC 7) and marks the prompt and each command
# (OSC 133). Loaded by the .zshenv next to it when Conduit injects it, or by
# hand from ~/.zshrc:
#
#     [[ -n $CONDUIT_SHELL_INTEGRATION_DIR ]] && source "$CONDUIT_SHELL_INTEGRATION_DIR/zsh/conduit.zsh"

[[ -o interactive ]] || return 0
(( ${+__conduit_loaded} )) && return 0
typeset -g __conduit_loaded=1
typeset -g __conduit_in_command=

builtin autoload -Uz add-zsh-hook

# The prompt is about to be drawn: close the previous command with its status,
# report the directory, and open a new prompt.
__conduit_precmd() {
    # Not `status`: in zsh that is a read-only alias for $?, and assigning it
    # aborts the whole hook.
    builtin local exit_code=$?
    if [[ -n $__conduit_in_command ]]; then
        builtin printf '\e]133;D;%s\a' "$exit_code"
        __conduit_in_command=
    fi
    builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "${HOST-}" "$PWD"
    builtin printf '\e]133;A\a'
    # The end of the prompt is the start of input. Re-applied at every prompt,
    # because a theme may rebuild PS1 from its own precmd.
    [[ $PS1 == *$'\e]133;B\a'* ]] || PS1="$PS1"$'%{\e]133;B\a%}'
}

# A command is about to run: mark the start of its output.
__conduit_preexec() {
    __conduit_in_command=1
    builtin printf '\e]133;C\a'
}

add-zsh-hook precmd __conduit_precmd
add-zsh-hook preexec __conduit_preexec

# Some themes rewrite PS1 after every precmd hook has run, which drops the input
# mark above. Re-emit it when the line editor starts, which is the last moment
# before the user types.
#
# The widget is installed from the first prompt, not here: this file runs from
# .zshenv, and the global and user zshrc run after it and may define their own
# zle-line-init (Debian's /etc/zsh/zshrc does, for keypad mode), which would
# silently replace ours. By the first prompt every startup file has run, so the
# widget that is there is wrapped and keeps working.
__conduit_zle_line_init() {
    [[ $PS1 == *$'\e]133;B\a'* ]] || builtin printf '\e]133;B\a'
    (( ${+widgets[__conduit_user_zle_line_init]} )) && builtin zle __conduit_user_zle_line_init -- "$@"
}
__conduit_install_line_init() {
    add-zsh-hook -d precmd __conduit_install_line_init
    (( ${+widgets[zle-line-init]} )) && builtin zle -A zle-line-init __conduit_user_zle_line_init
    builtin zle -N zle-line-init __conduit_zle_line_init
}
add-zsh-hook precmd __conduit_install_line_init
