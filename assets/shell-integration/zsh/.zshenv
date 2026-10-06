# Conduit shell integration for zsh: the ZDOTDIR entry point.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Conduit authors. Written for Conduit; not derived from
# any other terminal's integration script.
#
# Conduit points ZDOTDIR at this directory and saves the user's own value (or
# its absence) in CONDUIT_ZSH_ZDOTDIR. This file puts ZDOTDIR back before
# anything else runs, so the user's .zshenv, .zprofile, .zshrc and .zlogin are
# read from exactly where zsh would have looked for them, then loads the
# integration for interactive shells.

if [[ -n ${CONDUIT_ZSH_ZDOTDIR+set} ]]; then
    if [[ -n $CONDUIT_ZSH_ZDOTDIR ]]; then
        builtin export ZDOTDIR=$CONDUIT_ZSH_ZDOTDIR
    else
        builtin unset ZDOTDIR
    fi
    builtin unset CONDUIT_ZSH_ZDOTDIR
fi

# The user's own .zshenv, from wherever ZDOTDIR now says (HOME by default).
() {
    builtin local user_zshenv=${ZDOTDIR-$HOME}/.zshenv
    [[ -r $user_zshenv ]] && builtin source "$user_zshenv"
}

[[ -o interactive ]] && builtin source "${${(%):-%x}:A:h}/conduit.zsh"
