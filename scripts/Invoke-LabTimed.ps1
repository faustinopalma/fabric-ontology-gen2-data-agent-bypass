#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [ValidateRange(1, 1200)][int]$LimitSeconds = 1200,
    [ValidateRange(1, 120)][int]$ProgressSeconds = 120
)
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $FilePath
$start.UseShellExecute = $false
foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::Start($start)
try {
    while (-not $process.HasExited) {
        $remaining = $LimitSeconds - $timer.Elapsed.TotalSeconds
        if ($remaining -le 0) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Local activity exceeded its time limit. Remote operations may still be running; inspect their journal before retrying.'
        }
        if (-not $process.WaitForExit([int](1000 * [math]::Min($ProgressSeconds, $remaining)))) {
            Write-Host "Activity running: $([math]::Round($timer.Elapsed.TotalSeconds))s / ${LimitSeconds}s"
        }
    }
    if ($process.ExitCode -ne 0) { throw "Child process exited with code $($process.ExitCode)." }
} finally {
    $process.Dispose()
    Write-Host "Activity elapsed: $([math]::Round($timer.Elapsed.TotalSeconds, 2))s"
}