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
| PowerShell | `powershell/conduit.ps1` | yes — PowerShell 7 over Windows ConPTY on the hosted Windows runner (TASK-46, CI run 37720295115), and pwsh over a Linux PTY |

The PowerShell script emits OSC 7 as `file://localhost/<path>` with forward slashes and a leading
slash before the drive (`file://localhost/C:/Users/me`), each segment percent-encoded; Conduit
turns that back into `C:\Users\me` when it starts a new tab there. A path outside the file system
provider (the registry, a UNC share) reports nothing.

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
- **PowerShell** (`pwsh` or `powershell`, with or without `.exe`, on any platform) — started with
  `-NoExit -Command ". ([scriptblock]::Create([System.IO.File]::ReadAllText('<dir>/powershell/conduit.ps1')))"`.
  `-Command` runs after PowerShell has loaded your own `$PROFILE`, and `-NoExit` keeps it
  interactive. The script is loaded from its text rather than run as a script file, so an
  execution policy that forbids unsigned scripts (Windows PowerShell's default on client Windows)
  does not block it. The script wraps your `prompt` function: it emits `D;<status>` for the
  previous command, OSC 7 and `A` before your prompt text and `B` after it, and wraps PSReadLine's
  `PSConsoleHostReadLine` to emit `C` when a line is submitted (without PSReadLine there is no
  `C`).

A login shell (a shell profile with `login = true`, TASK-46) is started with `-l` (`--login` for
bash, `-Login` for PowerShell 7 off Windows). For bash, whose POSIX-mode startup reads only `ENV`,
the script then replays the login startup files (`/etc/profile`, then the first of
`~/.bash_profile`, `~/.bash_login` and `~/.profile`) instead of `/etc/bash.bashrc` and
`~/.bashrc`, exactly as a login bash would.

Integration is added only when a shell starts bare: a shell profile that gives the shell a command
or other arguments (`bash -c ...`) is started exactly as written. PowerShell also keeps it with
`-NoLogo`, `-NoProfile` or `-Login`.

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

```powershell
# $PROFILE
if ($env:CONDUIT_SHELL_INTEGRATION_DIR) { . "$env:CONDUIT_SHELL_INTEGRATION_DIR/powershell/conduit.ps1" }
```

Each script loads at most once per shell, so sourcing it as well as injecting it is harmless.
