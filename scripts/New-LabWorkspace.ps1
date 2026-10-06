#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CapacityId,
    [string]$DisplayName = 'Ontology Gen2 snapshot lab',
    [string]$StatePath = (Join-Path $PSScriptRoot '../.local/lab-state.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricApi.ps1')
$description = 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.'
$capacities = Invoke-LabFabricRequest -Path /v1/capacities
if ($capacities.StatusCode -ne 200) { throw "Capacity list failed: HTTP $($capacities.StatusCode)" }
$matches = @($capacities.Data.value | Where-Object { $_.id -eq $CapacityId.ToString() })
if ($matches.Count -ne 1 -or $matches[0].state -ne 'Active' -or $matches[0].region -ne 'Sweden Central' -or $matches[0].sku -ne 'F2') {
    throw 'Expected exactly one active F2 in Sweden Central with the selected capacity ID.'
}
if (Test-Path $StatePath) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
    if ($state.project -ne 'fabric-ontology-gen2-lab' -or $state.capacityId -ne $CapacityId.ToString()) { throw 'Local state belongs to a different lab.' }
    $workspace = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)"
} else {
    $listing = Invoke-LabFabricRequest -Path /v1/workspaces
    if ($listing.StatusCode -ne 200 -or $listing.Data.continuationToken) { throw 'Cannot establish complete workspace inventory. No workspace created.' }
    $existing = @($listing.Data.value | Where-Object { $_.displayName -eq $DisplayName })
    if ($existing.Count -gt 0) { throw 'Workspace name already exists. Reconcile with private API evidence instead of recreating it.' }
    $workspace = Invoke-LabFabricRequest -Method POST -Path /v1/workspaces -Body @{
        displayName = $DisplayName
        description = $description
        capacityId = $CapacityId.ToString()
    }
}
if ($workspace.StatusCode -notin @(200, 201)) { throw "Workspace request returned HTTP $($workspace.StatusCode). Inspect private evidence; do not blindly replay." }
if ($workspace.Data.description -ne $description -or -not $workspace.Data.id) { throw 'Workspace ownership could not be established.' }
$verified = Invoke-LabFabricRequest -Path "/v1/workspaces/$($workspace.Data.id)"
if ($verified.StatusCode -ne 200 -or $verified.Data.capacityId -ne $CapacityId.ToString()) { throw 'Workspace capacity assignment could not be verified.' }
$state = @{
    project = 'fabric-ontology-gen2-lab'
    capacityId = $CapacityId.ToString()
    workspaceId = $workspace.Data.id
    workspaceName = $workspace.Data.displayName
}
$null = New-Item -ItemType Directory -Path (Split-Path $StatePath) -Force
$state | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding utf8
Write-Host 'Workspace verified on the requested capacity. Private state saved.'