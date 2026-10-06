#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/FabricApi.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$null = New-Item -ItemType Directory -Path $fixtureRoot
$originalConfig = $env:AZURE_CONFIG_DIR
$fixtureState = @{ Status = 200; Calls = 0; TokenCalls = 0 }
$assertions = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function az {
    $fixtureState.TokenCalls++
    $global:LASTEXITCODE = 0
    '{"accessToken":"synthetic-secret-do-not-persist"}'
}
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $SkipHttpErrorCheck, $MaximumRedirection, $TimeoutSec, $ContentType, $Body)
    $fixtureState.Calls++
    Assert-True ($Headers.Authorization -eq 'Bearer synthetic-secret-do-not-persist') 'Token not forwarded'
    Assert-True ($Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces') 'Unexpected host or path'
    Assert-True ($MaximumRedirection -eq 0) 'Redirects must not forward credentials'
    if ($Body) {
        $decoded = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -AsHashtable
        Assert-True ($decoded.displayName -eq 'Synthetic lab') 'Request body changed'
    }
    $content = switch ($fixtureState.Status) {
        200 { '{"value":[]}' }
        202 { '' }
        403 { '{"errorCode":"InsufficientPrivileges"}' }
    }
    @{ StatusCode = $fixtureState.Status; Content = $content; Headers = @{ Location = 'https://api.fabric.microsoft.com/v1/operations/synthetic'; 'Retry-After' = '30' } }
}
try {
    foreach ($status in @(200, 202, 403)) {
        $fixtureState.Status = $status
        $result = Invoke-LabFabricRequest -Path /v1/workspaces -Method POST -Body @{displayName = 'Synthetic lab'} -AzureConfigDirectory $fixtureRoot -EvidenceDirectory $fixtureRoot
        Assert-True ($result.StatusCode -eq $status) 'HTTP status lost'
        Assert-True ($result.IsPending -eq ($status -eq 202)) 'Pending misclassified'
        Assert-True ($env:AZURE_CONFIG_DIR -eq $originalConfig) 'CLI configuration leaked'
        $evidence = Get-Content -LiteralPath $result.EvidencePath -Raw
        Assert-True (-not $evidence.Contains('synthetic-secret')) 'Token leaked to evidence'
        Assert-True (-not $evidence.Contains('Authorization')) 'Authorization header leaked'
        if ($status -eq 403) { Assert-True ($result.Data.errorCode -eq 'InsufficientPrivileges') 'Error lost' }
    }
    $rejected = $false
    try { Invoke-LabFabricRequest -Path 'https://untrusted.example/v1/workspaces' } catch { $rejected = $true }
    Assert-True $rejected 'Absolute URL accepted'
    Assert-True ($fixtureState.TokenCalls -eq 3) 'Invalid URL acquired token'
    Assert-True ($fixtureState.Calls -eq 3) 'Mutation retried'
    $part = New-LabDefinitionPart -Path definition.json -Text '{"synthetic":true}'
    Assert-True ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) -eq '{"synthetic":true}') 'Definition encoding changed'
    . (Join-Path $PSScriptRoot '../scripts/OntologyDefinition.ps1')
    $parameters = @{
        WorkspaceId = '00000000-0000-0000-0000-000000000001'
        LakehouseId = '00000000-0000-0000-0000-000000000002'
        SqlEndpointId = '00000000-0000-0000-0000-000000000003'
        SqlServer = 'synthetic.datawarehouse.fabric.microsoft.com'
    }
    foreach ($experience in @('Gen1', 'New')) {
        $definition = New-LabOntologyDefinition -Experience $experience @parameters
        $decodedParts = @{}
        foreach ($definitionPart in $definition.parts) {
            Assert-True (-not $decodedParts.ContainsKey($definitionPart.path)) 'Duplicate definition part'
            $decodedParts[$definitionPart.path] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($definitionPart.payload))
        }
        if ($experience -eq 'Gen1') {
            Assert-True ($definition.parts.Count -eq 8) 'Gen1 part count'
            Assert-True ($decodedParts.ContainsKey('definition.json') -and -not $decodedParts.ContainsKey('database.tmdl')) 'Gen1 format mixed'
            $anomaly = $decodedParts['EntityTypes/200/definition.json'] | ConvertFrom-Json
            Assert-True ($anomaly.properties.Count -eq 5 -and $anomaly.entityIdParts[0] -eq '201') 'Anomaly keys/properties'
            foreach ($json in $decodedParts.Values) { $null = $json | ConvertFrom-Json }
        } else {
            Assert-True ($definition.parts.Count -eq 11) 'New experience part count'
            Assert-True ($decodedParts.ContainsKey('database.tmdl') -and -not $decodedParts.ContainsKey('definition.json')) 'TMDL format mixed'
            Assert-True ($decodedParts['entities/Anomaly.tmdl'].Contains("Severity = 'critical' AND Status = 'open'")) 'Business rule absent'
            Assert-True ($decodedParts['relationships.tmdl'].Contains('fromColumn: Anomalies.MachineId')) 'Join column incorrect'
            Assert-True ($decodedParts['model.tmdl'] -match '(?m)^ref namespace default$') 'Namespace ref must be top-level'
            Assert-True ($decodedParts['model.tmdl'] -notmatch '(?m)^[ \t]+ref ') 'Nested TMDL refs rejected by service'
            Assert-True (([regex]::Matches($decodedParts['model.tmdl'], '(?m)^ref (table|entity) ')).Count -eq 4) 'Missing model entity/table refs'
        }
    }
    foreach ($mode in @('Baseline', 'Mutate', 'Restore')) {
        $sql = & (Join-Path $PSScriptRoot '../scripts/Test-LabFreshness.ps1') -Mode $mode -BuildOnly
        Assert-True (([regex]::Matches($sql, 'EXCEPT ALL')).Count -eq 4) 'Freshness must compare both complete tables in both directions'
        Assert-True (([regex]::Matches($sql, 'assert_true')).Count -eq 6) 'Freshness preconditions and postconditions required'
        $total = if ($mode -eq 'Mutate') { 92 } else { 55 }
        Assert-True ($sql.Contains("SUM(DowntimeMinutes) = $total")) 'Freshness oracle incorrect'
        if ($mode -eq 'Baseline') {
            Assert-True (-not $sql.Contains('UPDATE dbo.')) 'Baseline must not mutate data'
        } else {
            $before = if ($mode -eq 'Restore') { 47 } else { 10 }
            $after = if ($mode -eq 'Mutate') { 47 } else { 10 }
            Assert-True ($sql.Contains("UPDATE dbo.Anomalies SET DowntimeMinutes = $after WHERE AnomalyId = 'A01' AND MachineId = 'M01' AND Severity = 'critical' AND Status = 'open' AND DowntimeMinutes = $before;")) 'Freshness update must be narrowly guarded'
        }
    }
    Assert-True ($fixtureState.Calls -eq 3) 'BuildOnly must not make cloud calls'
    Write-Host "PASS: $assertions assertions. No cloud calls."
} finally {
    $env:AZURE_CONFIG_DIR = $originalConfig
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}