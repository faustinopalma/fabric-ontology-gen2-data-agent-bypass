#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ontology-gen2-tests-' + [guid]::NewGuid())
$originalConfig = $env:AZURE_CONFIG_DIR
$originalExitCode = $global:LASTEXITCODE
$testScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Test-FabricAccess.ps1'
$assertions = 0
$fixtureState = @{ Case = '' }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function az {
    $commandText = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($commandText.StartsWith('account show')) {
        return '{"id":"test-subscription","tenantId":"test-tenant","user":{"name":"synthetic-user"}}'
    }
    if ($commandText.Contains('https://api.fabric.microsoft.com/v1/capacities')) {
        if ($fixtureState.Case -eq 'Unlicensed') {
            $global:LASTEXITCODE = 1
            return 'Unauthorized({"errorCode":"UserNotLicensed","message":"User is not licensed"})'
        }
        return '{"value":[]}'
    }
    if ($commandText.Contains('https://graph.microsoft.com/v1.0/me/licenseDetails')) {
        if ($fixtureState.Case -eq 'GraphDenied') {
            $global:LASTEXITCODE = 1
            return 'Forbidden({"error":{"code":"Authorization_RequestDenied"}})'
        }
        if ($fixtureState.Case -eq 'Unlicensed') { return '{"value":[]}' }
        return '{"value":[{"skuPartNumber":"SYNTHETIC_LICENSE"}]}'
    }
    throw "Unexpected CLI call in offline test: $commandText"
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $env:AZURE_CONFIG_DIR = 'restore-this-synthetic-value'
    foreach ($caseName in @('Accessible', 'Unlicensed', 'GraphDenied')) {
        $fixtureState.Case = $caseName
        $caseDirectory = Join-Path $fixtureRoot $caseName
        $caught = $null
        $outputLines = [Collections.Generic.List[object]]::new()
        try {
            & $testScript -AzureConfigDirectory $fixtureRoot -EvidenceDirectory $caseDirectory | ForEach-Object { $outputLines.Add($_) }
        } catch {
            $caught = $_
        }
        $evidence = Get-Content -LiteralPath (Join-Path $caseDirectory 'access-check.json') -Raw | ConvertFrom-Json
        $aggregateText = $outputLines.ToArray() -join "`n"
        $aggregate = $aggregateText | ConvertFrom-Json
        Assert-True ($env:AZURE_CONFIG_DIR -eq 'restore-this-synthetic-value') "$caseName did not restore the CLI config."
        Assert-True (-not $aggregateText.Contains('synthetic-user')) "$caseName leaked the user identifier."
        Assert-True (-not $aggregateText.Contains('test-tenant')) "$caseName leaked the tenant identifier."
        Assert-True ($evidence.account.user -eq 'synthetic-user') "$caseName did not persist private account context."
        Assert-True ($aggregate.nativeAttachmentTestStatus -eq 'NotRun' -and $aggregate.nativeAttachmentFailureReproduced -eq $false) "$caseName falsely reported a reproduction."
        if ($caseName -eq 'Unlicensed') {
            Assert-True ($null -ne $caught) 'Unlicensed access must fail.'
            Assert-True ($aggregate.status -eq 'Blocked' -and $aggregate.fabricErrorCode -eq 'UserNotLicensed') 'Wrong blocked classification.'
            Assert-True ($aggregate.assignedLicenseCount -eq 0) 'A successful empty license list must have count zero.'
        } else {
            Assert-True ($null -eq $caught) "$caseName unexpectedly failed."
            Assert-True ($aggregate.status -eq 'FabricApiAccessible') "$caseName was not accessible."
            if ($caseName -eq 'GraphDenied') {
                Assert-True ($aggregate.licenseReadSucceeded -eq $false -and $null -eq $aggregate.assignedLicenseCount) 'Graph failure must not become zero licenses.'
            } else {
                Assert-True ($aggregate.assignedLicenseCount -eq 1) 'Singleton license array was miscounted.'
            }
        }
    }
    Write-Output "PASS: $assertions assertions across 3 offline cases. No cloud calls."
} finally {
    $env:AZURE_CONFIG_DIR = $originalConfig
    $global:LASTEXITCODE = $originalExitCode
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
}