#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Lakehouse', 'DataAgent', 'Ontology', 'Notebook')][string]$Type,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,63}$')][string]$Name,
    [hashtable]$Definition,
    [string]$StatePath = (Join-Path $PSScriptRoot '../.local/lab-state.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricApi.ps1')
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
if ($state.project -ne 'fabric-ontology-gen2-lab') { throw 'Invalid lab ownership marker.' }
$workspace = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)"
if ($workspace.StatusCode -ne 200 -or $workspace.Data.capacityId -ne $state.capacityId -or $workspace.Data.description -ne 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.') {
    throw 'Workspace identity, ownership or capacity changed.'
}
$description = 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.'
$journalDirectory = Join-Path (Split-Path $StatePath) 'items'
$null = New-Item -ItemType Directory -Path $journalDirectory -Force
$journalPath = Join-Path $journalDirectory "$Name.json"
$listing = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/items"
if ($listing.StatusCode -ne 200 -or $listing.Data.continuationToken) { throw 'Complete item inventory unavailable.' }
$existing = @($listing.Data.value | Where-Object { $_.displayName -eq $Name })
if ($existing.Count -gt 0) {
    if ($existing.Count -ne 1 -or $existing[0].type -ne $Type -or $existing[0].description -ne $description -or -not (Test-Path $journalPath)) {
        throw 'Existing item could not be attributed to this lab.'
    }
    $existing[0]
    return
}
if (Test-Path $journalPath) { throw 'Previous submission exists. Inspect its operation/evidence before retrying.' }
$collection = @{ Lakehouse = 'lakehouses'; DataAgent = 'dataAgents'; Ontology = 'ontologies'; Notebook = 'notebooks' }[$Type]
$body = @{ displayName = $Name; description = $description }
if ($Type -eq 'Lakehouse') { $body.creationPayload = @{ enableSchemas = $true } }
if ($Definition) { $body.definition = $Definition }
@{ phase = 'Submitting'; workspaceId = $state.workspaceId; type = $Type; name = $Name; submittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $journalPath -Encoding utf8
$response = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/$collection" -Method POST -Body $body
@{ phase = 'ResponseReceived'; workspaceId = $state.workspaceId; type = $Type; name = $Name; response = $response } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $journalPath -Encoding utf8
if ($response.StatusCode -eq 202) {
    Write-Host 'Creation accepted. Inspect operation status before depending on the item.'
    $response
} elseif ($response.StatusCode -eq 201) {
    $response.Data
} else {
    throw "Item creation failed: HTTP $($response.StatusCode), $($response.Data.errorCode). Evidence: $($response.EvidencePath)"
}