# Sequentially captures `clean build --warning-mode=all` for each sibling with source.
# Output: audit/raw/<sibling>-build.log per sibling. Continues even if a build fails.

$ErrorActionPreference = 'Continue'
$auditDir = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $auditDir
$rawDir = Join-Path $auditDir 'raw'
$siblingsRoot = Split-Path -Parent $root  # C:\Users\ostro\IdeaProjects

$siblings = @('kzen-lib', 'kzen-auto', 'kzen-project', 'kzen-launcher', 'kzen-shell')

foreach ($s in $siblings) {
    $dir = Join-Path $siblingsRoot $s
    if (-not (Test-Path $dir)) {
        Write-Host "SKIP $s — directory not found at $dir"
        continue
    }
    $log = Join-Path $rawDir "$s-build.log"
    $gradlew = Join-Path $dir 'gradlew.bat'
    if (-not (Test-Path $gradlew)) {
        Write-Host "SKIP $s — no gradlew.bat"
        continue
    }

    Write-Host ""
    Write-Host "=== [$s] starting clean build ==="
    $start = Get-Date
    Push-Location $dir
    try {
        & $gradlew clean build --warning-mode=all --console=plain *>&1 | Tee-Object -FilePath $log
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $dur = ((Get-Date) - $start).TotalMinutes
    Write-Host ("=== [$s] finished exit={0} in {1:N1} min ===" -f $exit, $dur)
}

Write-Host ""
Write-Host "All captures complete."
