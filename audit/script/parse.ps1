# Parses audit/raw/*.log into audit/parsed.tsv (one row per unique warning).
# Surfaces: kotlin, gradle-deprecation, gradle-daemon, kgp, jvm-runtime, yarn, node, java, webpack.
# Dedupe key: (surface, normalized_msg). Normalization strips paths/numbers/quoted idents.

param(
    [string]$RawDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'raw'),
    [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'parsed.tsv')
)

$rows = @{}

function Normalize-Msg([string]$msg) {
    $n = $msg
    $n = $n -replace "'[^']*'", "'<id>'"
    $n = $n -replace "`"[^`"]*`"", '"<id>"'
    $n = $n -replace 'file:///?\S+', '<file>'
    $n = $n -replace ':\d+(:\d+)?\b', ':<n>'
    $n = $n -replace '\b\d+\.\d+\.\d+\S*', '<ver>'
    $n = $n -replace '\b\d+\b', '<n>'
    $n = $n.Trim()
    return $n
}

function Source-Set([string]$path) {
    if (-not $path) { return '' }
    if ($path -match '/src/([A-Za-z]+)/(?:kotlin|java|resources)/') { return $Matches[1] }
    if ($path -match '\\src\\([A-Za-z]+)\\(?:kotlin|java|resources)\\') { return $Matches[1] }
    if ($path -match 'build\.gradle(\.kts)?$') { return 'build-script' }
    if ($path -match 'settings\.gradle(\.kts)?$') { return 'settings-script' }
    if ($path -match 'buildSrc') { return 'buildSrc' }
    return 'unknown'
}

function Sibling([string]$path) {
    if (-not $path) { return '' }
    if ($path -match 'kzen-(lib|auto|project|launcher|shell)') { return "kzen-$($Matches[1])" }
    return ''
}

function Add-Row($surface, $rawMsg, $path, $line) {
    $norm = Normalize-Msg $rawMsg
    $key = "$surface||$norm"
    if (-not $rows.ContainsKey($key)) {
        $rows[$key] = @{
            surface = $surface
            normalized = $norm
            occurrences = 0
            sites = New-Object System.Collections.ArrayList
            sourceSets = @{}
            siblings = @{}
        }
    }
    $r = $rows[$key]
    $r.occurrences++
    $site = if ($path) { if ($line) { "${path}:${line}" } else { $path } } else { '' }
    if ($site -and $r.sites.Count -lt 5 -and ($r.sites -notcontains $site)) { [void]$r.sites.Add($site) }
    $ss = Source-Set $path
    if ($ss) { $r.sourceSets[$ss] = ($r.sourceSets[$ss] + 1) }
    $sb = Sibling $path
    if ($sb) { $r.siblings[$sb] = ($r.siblings[$sb] + 1) }
}

$logs = Get-ChildItem -Path $RawDir -Filter '*.log' -ErrorAction SilentlyContinue
if (-not $logs) { Write-Error "No logs in $RawDir"; exit 1 }

foreach ($log in $logs) {
    Write-Host "Parsing $($log.Name) ($([math]::Round($log.Length/1KB)) KB)..."
    $logSibling = $log.BaseName -replace '-build$', ''
    $inGradleDeprBlock = $false
    $inDaemonMetaspaceBlock = $false
    $inJvmUnsafeBlock = $false
    $lines = Get-Content -LiteralPath $log.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Kotlin compiler — handles `w: file:///C:/path:LINE:COL message` (Windows triple-slash)
        if ($line -match '^w:\s+file:///?([A-Za-z]:[^:]+):(\d+):(\d+)\s+(.+)$') {
            Add-Row 'kotlin' $Matches[4] $Matches[1] $Matches[2]
            continue
        }
        # Kotlin compiler — Unix path or no column
        if ($line -match '^w:\s+file:///?([^:]+):(\d+)(?::(\d+))?\s+(.+)$') {
            Add-Row 'kotlin' $Matches[4] $Matches[1] $Matches[2]
            continue
        }
        # Kotlin without location
        if ($line -match '^w:\s+(.+)$') {
            Add-Row 'kotlin' $Matches[1] '' ''
            continue
        }

        # Gradle deprecation block
        if ($line -match '^Deprecated Gradle features were used in this build') {
            $inGradleDeprBlock = $true; continue
        }
        if ($inGradleDeprBlock) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^You can use|^Build|^For more') {
                $inGradleDeprBlock = $false; continue
            }
            Add-Row 'gradle-deprecation' $line.Trim() '' ''
            continue
        }

        # Gradle daemon performance / metaspace warning block
        if ($line -match 'Daemon will expire after the build after running out of JVM Metaspace') {
            $inDaemonMetaspaceBlock = $true
            Add-Row 'gradle-daemon' 'Daemon will expire after the build after running out of JVM Metaspace (memory under-configured)' '' ''
            continue
        }
        if ($inDaemonMetaspaceBlock) {
            if ($line -match '^>\s+Task' -or [string]::IsNullOrWhiteSpace($line)) { $inDaemonMetaspaceBlock = $false }
            continue
        }

        # JVM runtime — sun.misc.Unsafe terminally deprecated block
        if ($line -match '^WARNING:\s+A terminally deprecated method in (\S+) has been called') {
            Add-Row 'jvm-runtime' "Terminally deprecated method in $($Matches[1]) has been called by a transitive dep (will be removed in a future JDK)" '' ''
            $inJvmUnsafeBlock = $true
            continue
        }
        if ($inJvmUnsafeBlock) {
            if ($line -match '^WARNING:' -or $line -match '^>\s+Task' -or [string]::IsNullOrWhiteSpace($line)) {
                if ($line -notmatch '^WARNING:') { $inJvmUnsafeBlock = $false }
            }
            continue
        }

        # KGP / KMP plugin
        if ($line -match '(The Default Kotlin Hierarchy Template was not applied|expect/actual.*are in Beta|Kotlin/Native|Kotlin/JS .* is deprecated)') {
            Add-Row 'kgp' $line.Trim() '' ''
            continue
        }

        # Java compiler
        if ($line -match '^(.+\.java):(\d+):\s+warning:\s+(.+)$') {
            Add-Row 'java' $Matches[3] $Matches[1] $Matches[2]
            continue
        }

        # Webpack
        if ($line -match '^WARNING in (.+)$') {
            Add-Row 'webpack' $Matches[1] '' ''
            continue
        }

        # npm warn ...
        if ($line -match '^npm (?:warn|WARN)\s+(.+)$') {
            Add-Row 'node-toolchain' $Matches[1] '' ''
            continue
        }

        # Yarn warnings
        if ($line -match '^warning\s+Pattern\s+\[.*\]\s+is trying to unpack in the same destination') {
            Add-Row 'yarn' 'Pattern is trying to unpack in the same destination as another pattern (Yarn workspace duplicate)' '' ''
            continue
        }
        if ($line -match '^warning\s+".*"\s+has incorrect peer dependency\s+(.+)$') {
            Add-Row 'yarn' "Workspace package has incorrect peer dependency: $($Matches[1])" '' ''
            continue
        }
        if ($line -match '^warning\s+(.+)$') {
            Add-Row 'yarn' $Matches[1] '' ''
            continue
        }

        # Node DEP warnings
        if ($line -match '^\(node:\d+\)\s+\[(DEP\d+)\]\s+DeprecationWarning:\s+(.+)$') {
            Add-Row 'node-runtime' "$($Matches[1]): $($Matches[2])" '' ''
            continue
        }
    }
}

# Emit TSV
$header = "surface`tnormalized_msg`toccurrences`tsource_sets`tsiblings`tsample_sites"
$body = $rows.GetEnumerator() | Sort-Object { -$_.Value.occurrences } | ForEach-Object {
    $r = $_.Value
    $ssStr = ($r.sourceSets.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
    $sbStr = ($r.siblings.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
    $sitesStr = ($r.sites -join ' | ')
    "{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $r.surface, $r.normalized, $r.occurrences, $ssStr, $sbStr, $sitesStr
}
@($header) + @($body) | Set-Content -LiteralPath $Out -Encoding UTF8

Write-Host ""
Write-Host "Wrote $($rows.Count) unique warnings to $Out"
Write-Host ""
Write-Host "Surface breakdown:"
$rows.Values | Group-Object surface | Sort-Object @{e={$_.Count}; desc=$true} | ForEach-Object {
    $occ = ($_.Group | Measure-Object -Property occurrences -Sum).Sum
    Write-Host ("  {0,-22} {1,5} unique  ({2,5} occurrences)" -f $_.Name, $_.Count, $occ)
}
