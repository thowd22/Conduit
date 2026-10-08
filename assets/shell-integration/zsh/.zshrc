# Conduit zsh integration: an interactive shell reads this after .zshenv (and
# .zprofile for a login shell). The user's .zshrc runs first, with their
# ZDOTDIR in place, and conduit.zsh installs its hooks afterwards, so nothing
# the rc file does to precmd_functions can remove them; see .zshenv.
__conduit_source_user .zshrc
builtin source "$__conduit_wrapper_dir/conduit.zsh"
if [[ -o login ]]; then
    # .zlogin is still to come from this directory.
    builtin export ZDOTDIR=$__conduit_wrapper_dir
else
    __conduit_restore_zdotdir
fi
