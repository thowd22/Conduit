# Conduit shell integration

Small scripts that let a shell tell Conduit two things:

- **where it is** — OSC 7, `ESC ] 7 ; kitty-shell-cwd://<host><path> BEL`, on every prompt;
- **where each prompt and command is** — OSC 133: `A` at prompt start, `B` at input start,
  `C` when a command starts running, `D;<exit status>` when it finishes.

Conduit treats both as display data. A reported directory is checked before it is used (the
scheme must be `file` or `kitty-shell-cwd`, the host must be this machine) and it never causes
an action on its own.

All three scripts are Conduit's own, MIT-licensed. They are written against Ghostty's integration
as a behavioural reference only; Ghostty's bash and zsh scripts are GPLv3 and none of their text
is used here.

## Status

| Shell | Script | Tested |
|---|---|---|
| bash | `bash/conduit.bash` | yes — real bash 5.3 over a real PTY |
| zsh | `zsh/.zshenv` + `zsh/conduit.zsh` | yes — real zsh 5.9 over a real PTY |
| fish | `fish/vendor_conf.d/conduit.fish` | **no, by decision** — the project proves bash and zsh only |

PowerShell has no script yet; it belongs to TASK-46.

## How Conduit loads them

Conduit embeds these files in its binary and writes them to a private directory when it starts a
shell. It recognises the shell from the program name and injects the integration without editing
any of your files:

- **bash** — started as `bash --posix` with `ENV` pointing at `bash/conduit.bash` and
  `CONDUIT_BASH_INJECT=1`. POSIX mode reads `ENV` instead of the usual startup files, so the
  script immediately turns POSIX mode off again, unsets `ENV`, and sources `/etc/bash.bashrc` and
  `~/.bashrc` itself, exactly as a normal interactive bash would have. Your `PROMPT_COMMAND` keeps
  running and sees the real exit status.
- **zsh** — started with `ZDOTDIR` pointing at the `zsh/` directory and your own `ZDOTDIR` (or
  its absence) saved in `CONDUIT_ZSH_ZDOTDIR`. The `.zshenv` there restores your `ZDOTDIR` before
  anything else runs and sources your own `.zshenv`, so `.zshrc`, `.zprofile` and `.zlogin` are
  read from where they always were.
- **fish** — started with the integration directory prepended to `XDG_DATA_DIRS`, so fish loads
  `vendor_conf.d/conduit.fish` at startup. The script removes that directory again.

Any other shell gets nothing: Conduit never guesses.

Every shell also sees `TERM_PROGRAM=conduit` and `CONDUIT_SHELL_INTEGRATION_DIR`.

## Turning it off

Run Conduit with `--no-shell-integration`. The shell then starts exactly as it would without
Conduit: no `--posix`, no `ENV`, no `ZDOTDIR` swap, and no OSC 7 or 133 from these scripts.

## Loading by hand

If Conduit starts your shell some other way, or you have turned injection off and still want the
marks, source the script from your own startup file:

```sh
# ~/.bashrc
[ -n "$CONDUIT_SHELL_INTEGRATION_DIR" ] && . "$CONDUIT_SHELL_INTEGRATION_DIR/bash/conduit.bash"

# ~/.zshrc
[[ -n $CONDUIT_SHELL_INTEGRATION_DIR ]] && source "$CONDUIT_SHELL_INTEGRATION_DIR/zsh/conduit.zsh"
```

Each script loads at most once per shell, so sourcing it as well as injecting it is harmless.
