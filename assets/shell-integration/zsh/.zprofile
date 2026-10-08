# Conduit zsh integration: a login shell reads this after .zshenv. It only
# runs the user's .zprofile with their ZDOTDIR in place; see .zshenv.
__conduit_source_user .zprofile
builtin export ZDOTDIR=$__conduit_wrapper_dir
