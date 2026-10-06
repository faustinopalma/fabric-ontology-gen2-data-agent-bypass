#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Baseline', 'Mutate', 'Restore')][string]$Mode,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9]{0,20}$')][string]$Attempt = 'verification',
    [switch]$BuildOnly,
    [switch]$CheckRun
)
$ErrorActionPreference = 'Stop'
$before = if ($Mode -eq 'Restore') { 47 } else { 10 }
$after = if ($Mode -eq 'Mutate') { 47 } else { 10 }
$total = 45 + $after
$update = if ($Mode -eq 'Baseline') { '' } else { "UPDATE dbo.Anomalies SET DowntimeMinutes = $after WHERE AnomalyId = 'A01' AND MachineId = 'M01' AND Severity = 'critical' AND Status = 'open' AND DowntimeMinutes = $before;" }
$sql = @"
CREATE OR REPLACE TEMP VIEW ExpectedMachines AS
SELECT * FROM VALUES ('M01','Press One','North'), ('M02','Press Two','North'), ('M03','Pump Three','South'), ('M04','Pump Four','South'), ('M05','Motor Five','North') AS fixture(MachineId, Name, Site);
CREATE OR REPLACE TEMP VIEW ExpectedAnomalies AS
SELECT AnomalyId, MachineId, Severity, Status, CAST(DowntimeMinutes AS DOUBLE) AS DowntimeMinutes FROM VALUES
('A01','M01','critical','open',$before), ('A02','M01','critical','open',15), ('A03','M02','critical','closed',100),
('A04','M03','critical','open',30), ('A05','M04','warning','open',5), ('A06','M03','warning','closed',7)
AS fixture(AnomalyId, MachineId, Severity, Status, DowntimeMinutes);
SELECT assert_true(COUNT(*) = 0, 'Unexpected machine rows') FROM (SELECT MachineId, Name, Site FROM dbo.Machines EXCEPT ALL SELECT * FROM ExpectedMachines);
SELECT assert_true(COUNT(*) = 0, 'Missing machine rows') FROM (SELECT * FROM ExpectedMachines EXCEPT ALL SELECT MachineId, Name, Site FROM dbo.Machines);
SELECT assert_true(COUNT(*) = 0, 'Unexpected anomaly rows') FROM (SELECT AnomalyId, MachineId, Severity, Status, DowntimeMinutes FROM dbo.Anomalies EXCEPT ALL SELECT * FROM ExpectedAnomalies);
SELECT assert_true(COUNT(*) = 0, 'Missing anomaly rows') FROM (SELECT * FROM ExpectedAnomalies EXCEPT ALL SELECT AnomalyId, MachineId, Severity, Status, DowntimeMinutes FROM dbo.Anomalies);
$update
SELECT assert_true(COUNT(*) = 1 AND MIN(DowntimeMinutes) = $after, 'A01 postcondition failed') FROM dbo.Anomalies WHERE AnomalyId = 'A01';
SELECT assert_true(COUNT(*) = 3 AND SUM(DowntimeMinutes) = $total, 'Actionable total mismatch') FROM dbo.Anomalies WHERE Severity = 'critical' AND Status = 'open';
"@
if ($BuildOnly) { $sql; return }
. (Join-Path $PSScriptRoot 'FabricApi.ps1')
$state = Get-Content (Join-Path $PSScriptRoot '../.local/lab-state.json') -Raw | ConvertFrom-Json -AsHashtable
if ($state.project -ne 'fabric-ontology-gen2-lab') { throw 'Unexpected lab ownership.' }
$workspace = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)"
if ($workspace.StatusCode -ne 200 -or $workspace.Data.capacityId -ne $state.capacityId -or $workspace.Data.description -ne 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.') { throw 'Workspace ownership mismatch.' }
$name = "VerifyFreshness${Mode}${Attempt}"
$journal = Join-Path $PSScriptRoot "../.local/freshness-$Mode-$Attempt.json"
if ($CheckRun) {
    $record = Get-Content $journal -Raw | ConvertFrom-Json -AsHashtable
    if ($record.workspaceId -ne $state.workspaceId -or $record.path -notlike "/v1/workspaces/$($state.workspaceId)/items/*/jobs/instances/*") { throw 'Unexpected job path.' }
    $response = Invoke-LabFabricRequest -Path $record.path
    if ($response.StatusCode -ne 200) { throw 'Job status unavailable.' }
    $record.lastCheck = $response
    $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
    $response.Data
    return
}
if (Test-Path $journal) { throw 'Run already journaled. Use -CheckRun; do not replay.' }
$inventory = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/items"
if ($inventory.StatusCode -ne 200 -or $inventory.Data.continuationToken) { throw 'Complete inventory unavailable.' }
$lakehouse = @($inventory.Data.value | Where-Object { $_.type -eq 'Lakehouse' -and $_.displayName -eq 'MaintenanceData' -and $_.description -eq 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.' })
if ($lakehouse.Count -ne 1) { throw 'Expected one lab-owned lakehouse.' }
$notebook = @{
    nbformat = 4; nbformat_minor = 5
    metadata = @{
        language_info = @{ name = 'python' }; kernel_info = @{ name = 'synapse_pyspark' }
        dependencies = @{ lakehouse = @{
            default_lakehouse = $lakehouse[0].id; default_lakehouse_name = 'MaintenanceData'
            default_lakehouse_workspace_id = $state.workspaceId; known_lakehouses = @(@{ id = $lakehouse[0].id })
        } }
    }
    cells = @(@{ cell_type = 'code'; id = 'verify-freshness'; source = @("%%sql`n$sql"); execution_count = $null; outputs = @(); metadata = @{ language = 'sparksql' } })
}
$definition = @{ format = 'ipynb'; parts = @(New-LabDefinitionPart -Path 'notebook-content.ipynb' -Text ($notebook | ConvertTo-Json -Depth 30)) }
$created = & (Join-Path $PSScriptRoot 'New-LabItem.ps1') -Type Notebook -Name $name -Definition $definition
if (-not $created.id) { throw 'Notebook creation is pending. Reconcile its operation before starting a run.' }
$record = @{ phase = 'Submitting'; workspaceId = $state.workspaceId; itemId = $created.id; mode = $Mode; expectedDowntime = $total; submittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
$record | ConvertTo-Json | Set-Content $journal -Encoding utf8
$response = Invoke-LabFabricRequest -Method POST -Path "/v1/workspaces/$($state.workspaceId)/items/$($created.id)/jobs/RunNotebook/instances"
$record.response = $response
$record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
if ($response.StatusCode -ne 202) { throw 'Job not accepted. Inspect private evidence.' }
$record.path = ([uri]$response.Headers.Location).PathAndQuery
$record.phase = 'Accepted'
$record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
[pscustomobject]@{ Mode = $Mode; Phase = 'Accepted'; ExpectedDowntime = $total; RetryAfter = $response.Headers['Retry-After'] }