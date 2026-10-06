#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$AzureConfigDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) '.azure'),
    [string]$EvidenceDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local')
)

$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$previousConfig = $env:AZURE_CONFIG_DIR

function Invoke-AzRead {
    param([string[]]$Arguments)
    $raw = @(& az @Arguments --only-show-errors -o json 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -eq 0) {
        return @{ succeeded = $true; data = ($text | ConvertFrom-Json -AsHashtable); errorCode = $null }
    }
    $errorCode = 'CliOrHttpError'
    $jsonStart = $text.IndexOf('{')
    $jsonEnd = $text.LastIndexOf('}')
    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        try {
            $failure = $text.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json -AsHashtable
            if ($failure.errorCode) { $errorCode = $failure.errorCode }
        } catch { }
    }
    return @{ succeeded = $false; data = $null; errorCode = $errorCode }
}

try {
    if (-not (Test-Path -LiteralPath $AzureConfigDirectory -PathType Container)) {
        throw 'Azure CLI configuration directory does not exist. Sign in explicitly before running this check.'
    }
    $env:AZURE_CONFIG_DIR = (Resolve-Path -LiteralPath $AzureConfigDirectory).Path
    $account = Invoke-AzRead @('account', 'show')
    if (-not $account.succeeded) { throw 'Azure CLI account lookup failed. No login or license changes were attempted.' }
    $fabric = Invoke-AzRead @('rest', '--method', 'get', '--url', 'https://api.fabric.microsoft.com/v1/capacities', '--resource', 'https://api.fabric.microsoft.com')
    $licenses = Invoke-AzRead @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/me/licenseDetails')
    $licenseCount = $null
    if ($licenses.succeeded) { $licenseCount = @($licenses.data.value).Count }
    $status = if ($fabric.succeeded) { 'FabricApiAccessible' } else { 'Blocked' }
    $result = [ordered]@{
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        status = $status
        fabricErrorCode = $fabric.errorCode
        licenseReadSucceeded = $licenses.succeeded
        assignedLicenseCount = $licenseCount
        nativeAttachmentFailureReproduced = $false
        nativeAttachmentTestStatus = 'NotRun'
    }
    $privateEvidence = @{
        result = $result
        account = @{
            subscriptionId = $account.data.id
            tenantId = $account.data.tenantId
            user = $account.data.user.name
        }
    }
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    $privateEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'access-check.json') -Encoding utf8
    $result | ConvertTo-Json -Depth 5
    if (-not $fabric.succeeded) {
        throw "Fabric access blocked: $($fabric.errorCode). This prerequisite failure is not an ontology attachment test. No licenses were changed."
    }
} finally {
    $env:AZURE_CONFIG_DIR = $previousConfig
    Write-Host "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
}