# Conduit zsh integration: a login shell reads this last. It runs the user's
# .zlogin with their ZDOTDIR in place and then restores it for good, so a
# nested zsh and .zlogout see the user's own value; see .zshenv.
__conduit_source_user .zlogin
__conduit_restore_zdotdir
