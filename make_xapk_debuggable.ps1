param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$ConfigPath = "",
    [string]$BaseApkName,
    [string]$PythonPath,
    [string]$KeystorePath,
    [string]$KeyAlias,
    [string]$KeystorePassword,
    [string]$ZipalignPath,
    [string]$ApksignerPath,
    [string]$KeytoolPath
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "makeDebuggable.config.psd1"
}

$settings = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    $settings = Import-PowerShellDataFile -Path $ConfigPath
}

function Get-Setting {
    param(
        [AllowNull()]
        [object]$CliValue,
        [string]$Name,
        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -ne $CliValue -and "$CliValue" -ne "") {
        return $CliValue
    }
    if ($settings.ContainsKey($Name)) {
        return $settings[$Name]
    }
    return $Default
}

function Require-Tool {
    param(
        [string]$Name,
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) {
            throw "Configured path for $Name does not exist: $ExplicitPath"
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required command not found: $Name"
    }
    return $cmd.Source
}

function Ensure-Keystore {
    param(
        [string]$KeystorePath,
        [string]$KeyAlias,
        [string]$KeystorePassword,
        [string]$KeytoolPath
    )

    $parentDir = Split-Path -Parent $KeystorePath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $KeystorePath) {
        Write-Host "Using existing keystore: $KeystorePath"
        return
    }

    Write-Host "Generating debug keystore: $KeystorePath"
    & $KeytoolPath `
        -genkeypair `
        -keystore $KeystorePath `
        -storepass $KeystorePassword `
        -keypass $KeystorePassword `
        -alias $KeyAlias `
        -keyalg RSA `
        -keysize 2048 `
        -validity 100000 `
        -dname "CN=Debuggable, OU=Debuggable, O=Debuggable, L=Lab, S=Lab, C=US" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Keystore generation failed with exit code $LASTEXITCODE"
    }
}

$resolvedConfig = @{
    PythonPath = Get-Setting -CliValue $PythonPath -Name "PythonPath"
    KeystorePath = Get-Setting -CliValue $KeystorePath -Name "KeystorePath"
    KeyAlias = Get-Setting -CliValue $KeyAlias -Name "KeyAlias" -Default "debuggable"
    KeystorePassword = Get-Setting -CliValue $KeystorePassword -Name "KeystorePassword" -Default "debuggable"
    ZipalignPath = Get-Setting -CliValue $ZipalignPath -Name "ZipalignPath"
    ApksignerPath = Get-Setting -CliValue $ApksignerPath -Name "ApksignerPath"
    KeytoolPath = Get-Setting -CliValue $KeytoolPath -Name "KeytoolPath"
    BaseApkName = Get-Setting -CliValue $BaseApkName -Name "BaseApkName"
}

foreach ($name in @("PythonPath", "KeystorePath", "KeyAlias", "KeystorePassword")) {
    if ([string]::IsNullOrWhiteSpace([string]$resolvedConfig[$name])) {
        throw "Missing required setting '$name'. Supply it via CLI or $ConfigPath."
    }
}

$python = Require-Tool -Name "python" -ExplicitPath $resolvedConfig.PythonPath
$keytool = Require-Tool -Name "keytool" -ExplicitPath $resolvedConfig.KeytoolPath
$resolvedConfig.KeystorePath = [System.IO.Path]::GetFullPath($resolvedConfig.KeystorePath)

if ($resolvedConfig.ZipalignPath) {
    $resolvedConfig.ZipalignPath = [System.IO.Path]::GetFullPath($resolvedConfig.ZipalignPath)
    if (-not (Test-Path -LiteralPath $resolvedConfig.ZipalignPath)) {
        throw "zipalign not found: $($resolvedConfig.ZipalignPath)"
    }
}

if ($resolvedConfig.ApksignerPath) {
    $resolvedConfig.ApksignerPath = [System.IO.Path]::GetFullPath($resolvedConfig.ApksignerPath)
    if (-not (Test-Path -LiteralPath $resolvedConfig.ApksignerPath)) {
        throw "apksigner not found: $($resolvedConfig.ApksignerPath)"
    }
}

Ensure-Keystore `
    -KeystorePath $resolvedConfig.KeystorePath `
    -KeyAlias $resolvedConfig.KeyAlias `
    -KeystorePassword $resolvedConfig.KeystorePassword `
    -KeytoolPath $keytool

$scriptPath = Join-Path $PSScriptRoot "makeDebuggable.py"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Python script not found: $scriptPath"
}

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$inputItem = Get-Item -LiteralPath $resolvedInputPath
$inputExtension = [System.IO.Path]::GetExtension($resolvedInputPath).ToLowerInvariant()

$arguments = @($scriptPath)

if ($inputItem.PSIsContainer) {
    $arguments += @(
        "split",
        $resolvedInputPath,
        $resolvedOutputPath,
        $resolvedConfig.KeystorePath,
        $resolvedConfig.KeyAlias,
        $resolvedConfig.KeystorePassword
    )
} elseif ($inputExtension -eq ".xapk") {
    $arguments += @(
        "xapk",
        $resolvedInputPath,
        $resolvedOutputPath,
        $resolvedConfig.KeystorePath,
        $resolvedConfig.KeyAlias,
        $resolvedConfig.KeystorePassword
    )
} elseif ($inputExtension -eq ".apk") {
    $outputDir = Split-Path -Parent $resolvedOutputPath
    if ($outputDir) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $arguments += @(
        "apk",
        $resolvedInputPath,
        $resolvedOutputPath,
        $resolvedConfig.KeystorePath,
        $resolvedConfig.KeyAlias,
        $resolvedConfig.KeystorePassword
    )
} else {
    throw "Unsupported input path: $resolvedInputPath. Use an APK file, XAPK file, or extracted split directory."
}

if ($resolvedConfig.BaseApkName) {
    $arguments += @("--base-apk", $resolvedConfig.BaseApkName)
}
if ($resolvedConfig.ZipalignPath) {
    $arguments += @("--zipalign", $resolvedConfig.ZipalignPath)
}
if ($resolvedConfig.ApksignerPath) {
    $arguments += @("--apksigner", $resolvedConfig.ApksignerPath)
}

Write-Host "Running Python pipeline through $python"
& $python @arguments | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Python pipeline failed with exit code $LASTEXITCODE"
}
