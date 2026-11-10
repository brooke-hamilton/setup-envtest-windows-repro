#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Go = 'go',
    [ValidateRange(1, 120)][int]$LaunchTimeoutSeconds = 15,
    [ValidateRange(1, 3600)][int]$BuildTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This reproduction requires Windows.' }
if (-not ('NativeProbe' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeProbe.cs')
}
if ([NativeProbe]::IsElevated()) {
    throw 'Run this reproduction from a non-elevated terminal.'
}
$goCommand = (Get-Command $Go -CommandType Application -ErrorAction Stop).Source
$runName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = Join-Path $PSScriptRoot "results\$runName"
$null = New-Item -ItemType Directory -Path $runDirectory

function Format-LocalPath([string]$Path) {
    return $Path.Replace($PSScriptRoot.Replace('\', '\\'), '<repo>').
        Replace($HOME.Replace('\', '\\'), '<home>').
        Replace($PSScriptRoot, '<repo>').Replace($HOME, '<home>')
}

function Invoke-BoundedProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Label,
        [int]$TimeoutSeconds
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GOWORK'] = 'off'
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $result = [ordered]@{
        label = $Label
        executable = Format-LocalPath $Executable
        arguments = $Arguments
        launched = $false
        timedOut = $false
        exitCode = $null
        win32Error = $null
        error = $null
        stdoutFile = $null
        stderrFile = $null
    }
    try {
        try { $null = $process.Start() }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -isnot [System.ComponentModel.Win32Exception]) { throw }
            $result.win32Error = $cause.NativeErrorCode
            $result.error = Format-LocalPath $cause.Message
            return [pscustomobject]$result
        }
        $result.launched = $true
        $result.stdoutFile = "$Label.stdout.txt"
        $result.stderrFile = "$Label.stderr.txt"
        # Drain both streams concurrently before waiting to avoid pipe deadlocks.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $result.timedOut = $true
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) { throw "Cannot stop timed-out process $Label." }
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll(
            [System.Threading.Tasks.Task[]]@($stdout, $stderr), 10000)) {
            throw "Timed out draining output for $Label."
        }
        $result.exitCode = $process.ExitCode
        Format-LocalPath $stdout.Result | Set-Content -LiteralPath (Join-Path $runDirectory $result.stdoutFile)
        Format-LocalPath $stderr.Result | Set-Content -LiteralPath (Join-Path $runDirectory $result.stderrFile)
        return [pscustomobject]$result
    }
    finally { $process.Dispose() }
}

function Invoke-Go([string[]]$GoArguments, [string]$Label) {
    $result = Invoke-BoundedProcess $goCommand $GoArguments $Label $BuildTimeoutSeconds
    if (-not $result.launched -or $result.timedOut -or $result.exitCode -ne 0) {
        $result | ConvertTo-Json | Write-Host
        if ($result.launched) {
            Get-Content -LiteralPath (Join-Path $runDirectory $result.stderrFile) | Write-Host
        }
        throw "Go command failed: $Label. See $runDirectory."
    }
    return $result
}

function Get-BinaryEvidence([string]$Path) {
    return [pscustomobject]@{
        path = Format-LocalPath $Path
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        length = (Get-Item -LiteralPath $Path).Length
        machine = [NativeProbe]::Machine($Path)
        manifests = @([NativeProbe]::Manifests($Path))
    }
}

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$osInfo = Get-CimInstance Win32_OperatingSystem
$policy = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$report = [ordered]@{
    startedUtc = [DateTime]::UtcNow.ToString('o')
    os = [ordered]@{
        caption = $osInfo.Caption
        version = $osInfo.Version
        registryProductName = $os.ProductName
        displayVersion = $os.DisplayVersion
        build = "$($os.CurrentBuildNumber).$($os.UBR)"
        osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        elevated = [NativeProbe]::IsElevated()
        powershellVersion = $PSVersionTable.PSVersion.ToString()
    }
    policy = [ordered]@{}
    compatibilityEnvironment = [Environment]::GetEnvironmentVariable('__COMPAT_LAYER')
    goEnvironment = $null
    module = $null
    commands = @()
    binaries = @()
    launches = @()
    compatibilityLayers = @()
    manifestExperiment = $null
    completed = $false
    failure = $null
}
foreach ($name in @('EnableLUA', 'EnableInstallerDetection', 'ConsentPromptBehaviorAdmin', 'FilterAdministratorToken')) {
    $property = $policy.PSObject.Properties[$name]
    $report.policy[$name] = if ($null -eq $property) { $null } else { $property.Value }
}

try {
    $report.commands += Invoke-Go @('version') 'go-version'
    $report.commands += Invoke-Go @('env', '-json', 'GOOS', 'GOARCH', 'GOHOSTOS', 'GOHOSTARCH', 'GOVERSION') 'go-env'
    $report.goEnvironment = Get-Content (Join-Path $runDirectory 'go-env.stdout.txt') -Raw | ConvertFrom-Json
    if ($report.goEnvironment.GOOS -ne 'windows' -or
        $report.goEnvironment.GOARCH -ne $report.goEnvironment.GOHOSTARCH) {
        throw 'Use the native Windows target without GOOS/GOARCH cross-compilation overrides.'
    }
    $report.commands += Invoke-Go @('mod', 'tidy') 'go-mod-tidy'
    $report.commands += Invoke-Go @('list', '-m', '-json', 'sigs.k8s.io/controller-runtime/tools/setup-envtest') 'go-module'
    $module = Get-Content (Join-Path $runDirectory 'go-module.stdout.txt') -Raw | ConvertFrom-Json
    $report.module = $module | Select-Object Path, Version, Time, GoVersion, Sum, GoModSum
    if ($report.module.Version -ne 'v0.24.1') { throw 'Unexpected setup-envtest version.' }
    # -n resolves/builds the Go tool without launching setup-envtest.
    $report.commands += Invoke-Go @('tool', '-n', 'setup-envtest') 'go-tool-path'
    $source = (Get-Content (Join-Path $runDirectory 'go-tool-path.stdout.txt') -Raw).Trim()
    $source = $source.Replace('<home>', $HOME).Replace('<repo>', $PSScriptRoot).Trim('"')
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Go did not return an existing executable path: $source"
    }
    $setupCopy = Join-Path $runDirectory 'setup-envtest.exe'
    $neutralCopy = Join-Path $runDirectory 'envtest-probe.exe'
    Copy-Item -LiteralPath $source -Destination $setupCopy
    Copy-Item -LiteralPath $source -Destination $neutralCopy
    foreach ($path in @($source, $setupCopy, $neutralCopy)) {
        $report.binaries += Get-BinaryEvidence $path
    }
    if (@($report.binaries.sha256 | Select-Object -Unique).Count -ne 1) {
        throw 'Baseline binaries are not byte-identical.'
    }
    foreach ($key in @(
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
        'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    )) {
        if (Test-Path -LiteralPath $key) {
            $layers = Get-ItemProperty -LiteralPath $key
            foreach ($path in @($source, $setupCopy, $neutralCopy)) {
                $entry = $layers.PSObject.Properties[$path]
                if ($null -ne $entry) {
                    $report.compatibilityLayers += [pscustomobject]@{
                        key = $key; path = Format-LocalPath $path; value = $entry.Value
                    }
                }
            }
        }
    }
    $report.launches += Invoke-BoundedProcess $goCommand @('tool', 'setup-envtest', '--help') 'go-tool-help' $BuildTimeoutSeconds
    $report.launches += Invoke-BoundedProcess $source @('--help') 'cached-original' $LaunchTimeoutSeconds
    $report.launches += Invoke-BoundedProcess $setupCopy @('--help') 'same-directory-setup' $LaunchTimeoutSeconds
    $report.launches += Invoke-BoundedProcess $neutralCopy @('--help') 'same-directory-neutral' $LaunchTimeoutSeconds
    if ($report.binaries[1].manifests.Count -eq 0) {
        [NativeProbe]::AddAsInvokerManifest($setupCopy)
        $report.manifestExperiment = Get-BinaryEvidence $setupCopy
        $report.launches += Invoke-BoundedProcess $setupCopy @('--help') 'same-path-asInvoker' $LaunchTimeoutSeconds
    }
    else {
        $report.manifestExperiment = 'Skipped: original already has a manifest; no resources were overwritten.'
    }
    $report.completed = $true
}
catch {
    $report.failure = Format-LocalPath $_.Exception.Message
    throw
}
finally {
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $runDirectory 'report.json')
    $report.launches | Format-Table label, launched, timedOut, exitCode, win32Error | Out-Host
    Write-Host "Evidence: $runDirectory"
}
