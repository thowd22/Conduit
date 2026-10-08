# Conduit zsh integration: the first file zsh reads, because Conduit started
# the shell with ZDOTDIR pointing at this directory and the user's own value
# (or its absence, as an empty string) in CONDUIT_ZSH_ZDOTDIR.
#
# ZDOTDIR stays here for the rest of startup so that zsh also reads this
# directory's .zprofile, .zshrc and .zlogin; each of them sources the user's
# file of the same name with the user's ZDOTDIR in place, and the .zshrc
# wrapper loads conduit.zsh only after the user's .zshrc has run, so an rc
# file that assigns precmd_functions outright cannot remove the hooks. The
# user's ZDOTDIR is restored for good at the end of startup (.zshrc for a
# non-login shell, .zlogin for a login shell) and at once for a
# non-interactive shell, which reads no rc file.
typeset -g __conduit_wrapper_dir=${${(%):-%x}:A:h}
typeset -g __conduit_zdotdir=${CONDUIT_ZSH_ZDOTDIR-}
builtin unset CONDUIT_ZSH_ZDOTDIR

# Run the user's file of this name with their ZDOTDIR in place.
__conduit_source_user() {
    builtin local file=$1
    if [[ -n $__conduit_zdotdir ]]; then
        builtin export ZDOTDIR=$__conduit_zdotdir
    else
        builtin unset ZDOTDIR
    fi
    builtin local user_file=${ZDOTDIR-$HOME}/$file
    [[ -r $user_file ]] && builtin source "$user_file"
    return 0
}

# Put the user's ZDOTDIR back for good.
__conduit_restore_zdotdir() {
    if [[ -n $__conduit_zdotdir ]]; then
        builtin export ZDOTDIR=$__conduit_zdotdir
    else
        builtin unset ZDOTDIR
    fi
    builtin unset __conduit_zdotdir __conduit_wrapper_dir
    builtin unfunction __conduit_source_user __conduit_restore_zdotdir 2>/dev/null
}

__conduit_source_user .zshenv
if [[ -o interactive ]]; then
    # Keep reading startup files from here.
    builtin export ZDOTDIR=$__conduit_wrapper_dir
else
    __conduit_restore_zdotdir
fi
