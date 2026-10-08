# Conduit shell integration for PowerShell (PowerShell 7 `pwsh` and Windows
# PowerShell 5.1 `powershell`).
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Conduit authors. Written for Conduit; not derived from
# any other terminal's integration script.
#
# Reports the working directory (OSC 7) and marks the prompt and each command
# (OSC 133) so the terminal knows where the shell is and where its output is.
#
# Conduit loads this by starting PowerShell with
#     -NoExit -Command ". ([scriptblock]::Create([System.IO.File]::ReadAllText('<this file>')))"
# which runs after PowerShell has loaded your own profile, so nothing about your
# startup changes, and which an execution policy that forbids unsigned script
# files does not block. To use it by hand instead, add to your $PROFILE:
#
#     if ($env:CONDUIT_SHELL_INTEGRATION_DIR) { . "$env:CONDUIT_SHELL_INTEGRATION_DIR/powershell/conduit.ps1" }

# Interactive hosts only, and only once.
if ($Host.Name -ne 'ConsoleHost') { return }
if ($global:__ConduitLoaded) { return }
$global:__ConduitLoaded = $true
$global:__ConduitPrompted = $false

$global:__ConduitEsc = [char]0x1b
$global:__ConduitBel = [char]0x07

# The prompt the user had, as a script block: their profile's, or the default.
$global:__ConduitUserPrompt = $function:prompt

# OSC 7 needs a URL path: forward slashes, a leading slash before a drive
# letter, and every segment percent-encoded so a space or `#` survives.
function global:__ConduitCwdReport {
    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -ne 'FileSystem') { return '' }
    $path = $location.ProviderPath -replace '\\', '/'
    # A UNC path (`//server/share`) has no local URL form; say nothing.
    if ($path.StartsWith('//')) { return '' }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
    $encoded = ($path.Split('/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    return "$($global:__ConduitEsc)]7;file://localhost$encoded$($global:__ConduitBel)"
}

function global:prompt {
    # `$?` first: anything that runs before it would replace the status of the
    # command the user just ran.
    $succeeded = $global:?
    $code = if ($succeeded) { 0 } elseif ($global:LASTEXITCODE) { $global:LASTEXITCODE } else { 1 }
    $esc = $global:__ConduitEsc
    $bel = $global:__ConduitBel
    $marks = ''
    # Every prompt after the first closes the command line before it.
    if ($global:__ConduitPrompted) { $marks += "$esc]133;D;$code$bel" }
    $global:__ConduitPrompted = $true
    $marks += __ConduitCwdReport
    $marks += "$esc]133;A$bel"
    $text = if ($global:__ConduitUserPrompt) { & $global:__ConduitUserPrompt } else { "PS $($ExecutionContext.SessionState.Path.CurrentLocation)> " }
    # The end of the prompt is the start of input.
    return "$marks$text$esc]133;B$bel"
}

# A command is about to run: mark the start of its output. PSReadLine reads the
# line, so wrapping its read is the one place every submitted line passes.
# Without PSReadLine the prompt marks still arrive; only `C` is missing.
if (Get-Command -Name PSConsoleHostReadLine -ErrorAction SilentlyContinue) {
    $global:__ConduitReadLine = $function:PSConsoleHostReadLine
    function global:PSConsoleHostReadLine {
        $line = & $global:__ConduitReadLine
        [Console]::Write("$($global:__ConduitEsc)]133;C$($global:__ConduitBel)")
        $line
    }
}
