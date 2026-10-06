#requires -Version 7.0
[CmdletBinding()]
param([switch]$Start, [switch]$CheckRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricApi.ps1')
$runPath = Join-Path $PSScriptRoot '../.local/seed-run.json'
if ($CheckRun) {
    $run = Get-Content $runPath -Raw | ConvertFrom-Json -AsHashtable
    $response = Invoke-LabFabricRequest -Path $run.path
    $response.Data
    return
}
$state = Get-Content (Join-Path $PSScriptRoot '../.local/lab-state.json') -Raw | ConvertFrom-Json -AsHashtable
$lakehouse = Get-Content (Join-Path $PSScriptRoot '../.local/items/MaintenanceData.json') -Raw | ConvertFrom-Json -AsHashtable
$lakehouseId = $lakehouse.response.Data.id
if (-not $lakehouseId -or $lakehouse.response.StatusCode -ne 201) { throw 'Lakehouse creation must be reconciled before creating the seed notebook.' }
$sql = Get-Content (Join-Path $PSScriptRoot '../fixtures/maintenance.sql') -Raw
$notebook = @{
    nbformat = 4
    nbformat_minor = 5
    metadata = @{
        language_info = @{ name = 'python' }
        kernel_info = @{ name = 'synapse_pyspark' }
        dependencies = @{ lakehouse = @{
            default_lakehouse = $lakehouseId
            default_lakehouse_name = 'MaintenanceData'
            default_lakehouse_workspace_id = $state.workspaceId
            known_lakehouses = @(@{ id = $lakehouseId })
        } }
    }
    cells = @(@{
        cell_type = 'code'
        id = 'seed-maintenance'
        source = @("%%sql`n$sql")
        execution_count = $null
        outputs = @()
        metadata = @{ language = 'sparksql' }
    })
}
$definition = @{
    format = 'ipynb'
    parts = @(New-LabDefinitionPart -Path 'notebook-content.ipynb' -Text ($notebook | ConvertTo-Json -Depth 30))
}
$created = & (Join-Path $PSScriptRoot 'New-LabItem.ps1') -Type Notebook -Name SeedMaintenance -Definition $definition
if (-not $Start) { $created; return }
if (-not $created.id) { throw 'Notebook creation is pending. Do not start a job until it has an item ID.' }
if (Test-Path $runPath) { throw 'A seed run was already submitted. Use -CheckRun; do not replay.' }
@{ phase = 'Submitting'; itemId = $created.id } | ConvertTo-Json | Set-Content $runPath -Encoding utf8
$response = Invoke-LabFabricRequest -Method POST -Path "/v1/workspaces/$($state.workspaceId)/items/$($created.id)/jobs/RunNotebook/instances"
if ($response.StatusCode -ne 202) { throw "Seed job not accepted: HTTP $($response.StatusCode). Inspect private API evidence." }
$location = [uri]$response.Headers.Location
@{ phase = 'Accepted'; itemId = $created.id; path = $location.PathAndQuery; response = $response } | ConvertTo-Json -Depth 20 | Set-Content $runPath -Encoding utf8
Write-Host 'Seed job accepted. Use -CheckRun after the response Retry-After interval.'
$response