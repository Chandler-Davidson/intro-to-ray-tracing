[CmdletBinding()]
param(
    [string]$Branch = "main",
    [string]$OutputDir = "commit_renders",
    [string]$RenderPath = "out/image.ppm",
    [int]$MaxCommits = 0,
    [int]$MaxParallel = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Get-SafeSlug {
    param([Parameter(Mandatory = $true)][string]$Text)

    $slug = $Text.ToLowerInvariant()
    $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-")
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "untitled"
    }
    return $slug
}

function Convert-PpmToPng {
    param(
        [Parameter(Mandatory = $true)][string]$PpmPath,
        [Parameter(Mandatory = $true)][string]$PngPath
    )

    Add-Type -AssemblyName System.Drawing

    # Read all tokens at once, stripping PPM comment lines.
    $rawLines = Get-Content -Path $PpmPath
    $lines    = $rawLines | Where-Object { $_ -notmatch '^\s*#' }
    $tokens   = ($lines -join ' ') -split '\s+' | Where-Object { $_ -ne '' }

    $idx = 0
    $magic  = $tokens[$idx++]
    if ($magic -ne 'P3') {
        throw "Only P3 (ASCII) PPM is supported; got '$magic'."
    }

    $width  = [int]$tokens[$idx++]
    $height = [int]$tokens[$idx++]
    $maxval = [int]$tokens[$idx++]

    $bitmap = New-Object System.Drawing.Bitmap($width, $height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

    $scale = if ($maxval -ne 255) { 255.0 / $maxval } else { 1.0 }

    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x++) {
            $r = [int]([double]$tokens[$idx++] * $scale)
            $g = [int]([double]$tokens[$idx++] * $scale)
            $b = [int]([double]$tokens[$idx++] * $scale)
            $bitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $r, $g, $b))
        }
    }

    $bitmap.Save($PngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

Assert-CommandAvailable -Name "git"
Assert-CommandAvailable -Name "cargo"

$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
    throw "Could not determine git repository root."
}

Push-Location $repoRoot

# Track all worktrees and active processes for finally-block cleanup.
$createdWorktrees = New-Object System.Collections.Generic.List[string]
$worktreeBaseDir  = ""
$active           = New-Object System.Collections.ArrayList

try {
    & git diff --quiet
    $hasUnstagedTrackedChanges = ($LASTEXITCODE -ne 0)

    & git diff --cached --quiet
    $hasStagedChanges = ($LASTEXITCODE -ne 0)

    if ($hasUnstagedTrackedChanges -or $hasStagedChanges) {
        throw "Working tree has tracked changes. Commit or stash tracked changes before running this script."
    }

    if ($MaxParallel -lt 1) {
        throw "MaxParallel must be at least 1."
    }

    $branchRef = (git rev-parse --verify $Branch 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $branchRef) {
        throw "Branch '$Branch' was not found."
    }

    $commits = @(git rev-list --reverse $Branch)
    if ($MaxCommits -gt 0) {
        $commits = @($commits | Select-Object -First $MaxCommits)
    }

    if (-not $commits -or $commits.Count -eq 0) {
        throw "No commits were found for branch '$Branch'."
    }

    $absOutputDir = Join-Path $repoRoot $OutputDir
    $renderDir    = Join-Path $absOutputDir "images"
    $logsDir      = Join-Path $absOutputDir "logs"
    $readmePath   = Join-Path $absOutputDir "README.md"
    $worktreeBaseDir = Join-Path $absOutputDir ".worktrees"

    New-Item -ItemType Directory -Force -Path $absOutputDir | Out-Null
    New-Item -ItemType Directory -Force -Path $renderDir    | Out-Null

    # Clean prior outputs for a deterministic re-run.
    Get-ChildItem -Path $renderDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
    if (Test-Path $logsDir) { Remove-Item -Path $logsDir -Recurse -Force }
    if (Test-Path $readmePath) { Remove-Item -Force $readmePath }
    if (Test-Path $worktreeBaseDir) { Remove-Item -Path $worktreeBaseDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $worktreeBaseDir | Out-Null

    # ── Phase 1: build metadata and create a git worktree per commit ──────────
    $records = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($commit in $commits) {
        $i++
        $short   = (git rev-parse --short $commit).Trim()
        $subject = (git log -1 --pretty=%s $commit).Trim()
        $slug    = Get-SafeSlug -Text $subject
        $worktreePath = Join-Path $worktreeBaseDir ("{0:D4}_{1}" -f $i, $short)

        git worktree add --quiet --detach $worktreePath $commit
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create worktree for commit $short."
        }
        $createdWorktrees.Add($worktreePath) | Out-Null

        $records.Add([pscustomobject]@{
            Index        = $i
            Commit       = $commit
            Short        = $short
            Subject      = $subject
            Slug         = $slug
            WorktreePath = $worktreePath
        }) | Out-Null
    }

    # ── Phase 2: run cargo concurrently, throttled to MaxParallel ─────────────
    $successes = New-Object System.Collections.Generic.List[object]
    $failures  = New-Object System.Collections.Generic.List[object]

    $pending = New-Object System.Collections.Generic.Queue[object]
    foreach ($r in $records) { $pending.Enqueue($r) }

    $active.Clear()

    while ($pending.Count -gt 0 -or $active.Count -gt 0) {

        # Fill slots up to MaxParallel.
        while ($pending.Count -gt 0 -and $active.Count -lt $MaxParallel) {
            $record = $pending.Dequeue()

            Write-Host "[$($record.Index)/$($records.Count)] Launching  $($record.Short) - $($record.Subject)"

            $renderPathAbs    = Join-Path $record.WorktreePath $RenderPath
            $renderPathParent = Split-Path -Path $renderPathAbs -Parent
            if (-not (Test-Path $renderPathParent)) {
                New-Item -ItemType Directory -Force -Path $renderPathParent | Out-Null
            }
            if (Test-Path $renderPathAbs) { Remove-Item -Force $renderPathAbs }

            # Stderr goes to a temp file inside the worktree; only kept on failure.
            $stderrTempPath = Join-Path $record.WorktreePath "render.stderr.tmp"
            if (Test-Path $stderrTempPath) { Remove-Item -Force $stderrTempPath }

            $proc = Start-Process -FilePath "cargo" `
                                  -ArgumentList @("run", "--release") `
                                  -WorkingDirectory $record.WorktreePath `
                                  -NoNewWindow -PassThru `
                                  -RedirectStandardOutput $renderPathAbs `
                                  -RedirectStandardError  $stderrTempPath

            # Access .Handle immediately to prevent GC releasing it before
            # WaitForExit() runs; without this ExitCode can return null.
            $null = $proc.Handle

            [void]$active.Add([pscustomobject]@{
                Record         = $record
                Process        = $proc
                RenderPath     = $renderPathAbs
                StderrTempPath = $stderrTempPath
            })
        }

        # Collect any finished tasks.
        $completed = @($active | Where-Object { $_.Process.HasExited })
        if ($completed.Count -eq 0) {
            Start-Sleep -Milliseconds 300
            continue
        }

        foreach ($task in $completed) {
            [void]$active.Remove($task)

            # WaitForExit() must be called even after HasExited is true to
            # guarantee ExitCode is populated (known Start-Process -PassThru quirk).
            $task.Process.WaitForExit()

            $record    = $task.Record
            $exitCode  = $task.Process.ExitCode
            $renderOk  = (Test-Path $task.RenderPath) -and ((Get-Item $task.RenderPath).Length -gt 0)

            if ($exitCode -eq 0 -and $renderOk) {
                $imageFileName  = ("{0:D4}_{1}.png" -f $record.Index, $record.Slug)
                $destImagePath  = Join-Path $renderDir $imageFileName
                $convertError   = $null

                try {
                    Convert-PpmToPng -PpmPath $task.RenderPath -PngPath $destImagePath
                } catch {
                    $convertError = $_.Exception.Message
                }

                # Discard stderr temp — no log written on success.
                if (Test-Path $task.StderrTempPath) { Remove-Item -Force $task.StderrTempPath }

                if (-not $convertError) {
                    $successes.Add([pscustomobject]@{
                        Index             = $record.Index
                        Commit            = $record.Commit
                        Short             = $record.Short
                        Subject           = $record.Subject
                        ImageRelativePath = "images/$imageFileName"
                    }) | Out-Null

                    Write-Host "[$($record.Index)/$($records.Count)] Completed  $($record.Short)"
                } else {
                    # Conversion failed (e.g. commit output is not valid PPM).
                    if (-not (Test-Path $logsDir)) {
                        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
                    }
                    $logFileName    = ("{0:D4}_{1}.stderr.log" -f $record.Index, $record.Short)
                    $failureLogPath = Join-Path $logsDir $logFileName
                    Set-Content -Path $failureLogPath -Value "PPM conversion failed: $convertError" -Encoding UTF8

                    $failures.Add([pscustomobject]@{
                        Index           = $record.Index
                        Commit          = $record.Commit
                        Short           = $record.Short
                        Subject         = $record.Subject
                        ExitCode        = 0
                        LogRelativePath = "logs/$logFileName"
                    }) | Out-Null

                    Write-Host "[$($record.Index)/$($records.Count)] Failed     $($record.Short) (PPM conversion error)"
                }
            }
            else {
                # Only now create the logs directory and persist the stderr file.
                if (-not (Test-Path $logsDir)) {
                    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
                }

                $logFileName     = ("{0:D4}_{1}.stderr.log" -f $record.Index, $record.Short)
                $failureLogPath  = Join-Path $logsDir $logFileName

                if (Test-Path $task.StderrTempPath) {
                    Move-Item -Path $task.StderrTempPath -Destination $failureLogPath -Force
                }
                else {
                    Set-Content -Path $failureLogPath -Value "No stderr output captured." -Encoding UTF8
                }

                $failures.Add([pscustomobject]@{
                    Index           = $record.Index
                    Commit          = $record.Commit
                    Short           = $record.Short
                    Subject         = $record.Subject
                    ExitCode        = $exitCode
                    LogRelativePath = "logs/$logFileName"
                }) | Out-Null

                Write-Host "[$($record.Index)/$($records.Count)] Failed     $($record.Short) (exit $exitCode)"
            }
        }
    }

    # ── Phase 3: generate README ──────────────────────────────────────────────
    $successes = @($successes | Sort-Object -Property Index)
    $failures  = @($failures  | Sort-Object -Property Index)

    $readmeLines = New-Object System.Collections.Generic.List[string]
    $readmeLines.Add("# Commit Render Gallery") | Out-Null
    $readmeLines.Add("") | Out-Null
    $readmeLines.Add("Generated from branch '$Branch' with $($commits.Count) commits processed.") | Out-Null
    $readmeLines.Add("") | Out-Null

    foreach ($item in $successes) {
        $readmeLines.Add("## $($item.Subject)") | Out-Null
        $readmeLines.Add("") | Out-Null
        $readmeLines.Add("Commit: $($item.Short)") | Out-Null
        $readmeLines.Add("") | Out-Null
        $readmeLines.Add("![$($item.Subject)]($($item.ImageRelativePath))") | Out-Null
        $readmeLines.Add("") | Out-Null
    }

    if ($failures.Count -gt 0) {
        $readmeLines.Add("## Failed Commits") | Out-Null
        $readmeLines.Add("") | Out-Null
        foreach ($f in $failures) {
            $readmeLines.Add("- $($f.Short) - $($f.Subject) (exit code $($f.ExitCode), log: $($f.LogRelativePath))") | Out-Null
        }
        $readmeLines.Add("") | Out-Null
    }

    Set-Content -Path $readmePath -Value $readmeLines -Encoding UTF8

    Write-Host ""
    Write-Host "Done."
    Write-Host "Processed : $($commits.Count)"
    Write-Host "Succeeded : $($successes.Count)"
    Write-Host "Failed    : $($failures.Count)"
    Write-Host "Gallery   : $readmePath"
}
finally {
    # Kill any cargo processes still running (e.g. after an early error)
    # before attempting directory removal; otherwise file locks block cleanup.
    foreach ($task in @($active)) {
        try {
            if (-not $task.Process.HasExited) {
                $task.Process.Kill()
                $task.Process.WaitForExit(5000)
            }
        } catch { }
    }

    # Remove all temporary worktrees regardless of how we exit.
    foreach ($worktreePath in $createdWorktrees) {
        if (Test-Path $worktreePath) {
            try { git worktree remove --force $worktreePath 2>$null | Out-Null }
            catch { Write-Warning "Could not remove worktree '$worktreePath'." }
        }
    }

    if ($worktreeBaseDir -and (Test-Path $worktreeBaseDir)) {
        try { Remove-Item -Path $worktreeBaseDir -Recurse -Force }
        catch { Write-Warning "Could not remove worktree base dir '$worktreeBaseDir'." }
    }

    Pop-Location
}
