#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Attach', 'Mount', 'ResaveOntology', 'ConfigureSnapshot', 'VerifySnapshot', 'Publish')][string]$Action = 'Inspect',
    [ValidatePattern('^Maintenance[A-Za-z0-9_]+$')][string]$AgentName = 'MaintenanceGen2',
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Attempt = 'standard'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricApi.ps1')
$state = Get-Content (Join-Path $PSScriptRoot '../.local/lab-state.json') -Raw | ConvertFrom-Json -AsHashtable
if ($state.project -ne 'fabric-ontology-gen2-lab') { throw 'Unexpected lab ownership.' }
$workspace = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)"
if ($workspace.StatusCode -ne 200 -or $workspace.Data.capacityId -ne $state.capacityId -or $workspace.Data.description -ne 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.') { throw 'Workspace ownership mismatch.' }
$inventory = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/items"
if ($inventory.StatusCode -ne 200 -or $inventory.Data.continuationToken) { throw 'Complete inventory unavailable.' }
$agent = @($inventory.Data.value | Where-Object { $_.type -eq 'DataAgent' -and $_.displayName -eq $AgentName })
$ontology = @($inventory.Data.value | Where-Object { $_.type -eq 'Ontology' -and $_.displayName -eq 'MaintenanceNew' })
$lakehouse = @($inventory.Data.value | Where-Object { $_.type -eq 'Lakehouse' -and $_.displayName -eq 'MaintenanceData' })
if ($agent.Count -ne 1 -or $ontology.Count -ne 1 -or $lakehouse.Count -ne 1) { throw 'Expected unique lab items are missing.' }
foreach ($item in @($agent[0], $ontology[0], $lakehouse[0])) {
    if ($item.description -ne 'Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.') { throw 'Item ownership mismatch.' }
}
$base = "/v1/workspaces/$($state.workspaceId)/dataAgents/$($agent[0].id)"
if ($Action -eq 'Inspect') {
    $response = Invoke-LabFabricRequest -Path "$base/staging/datasources"
} elseif ($Action -in @('ConfigureSnapshot', 'VerifySnapshot')) {
    $journal = Join-Path $PSScriptRoot "../.local/gen2-$AgentName-$Action-$Attempt.json"
    if (Test-Path $journal) { throw 'Snapshot attempt already journaled; inspect state before another attempt.' }
    $metadata = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/ontologies/$($ontology[0].id)"
    if ($metadata.StatusCode -ne 200 -or $metadata.Data.properties.generation -ne 2) { throw 'Expected a confirmed Gen2 ontology.' }
    $definition = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/ontologies/$($ontology[0].id)/getDefinition" -Method POST
    if ($definition.StatusCode -ne 200) { throw "Definition not ready; inspect evidence $($definition.EvidencePath) before continuing." }
    $parts = @($definition.Data.definition.parts | Where-Object path -Like '*.tmdl' | Sort-Object path)
    if ($parts.Count -lt 5 -or @($parts | Where-Object path -Like 'entities/*').Count -ne 2) { throw 'Unexpected lab ontology definition.' }
    $context = ($parts | ForEach-Object { "$($_.path)`n$([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.payload)))" }) -join "`n`n"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($context))).ToLowerInvariant()
    $instructions = "Use this exported Gen2 ontology snapshot as business context for the MaintenanceData lakehouse. Derive business definitions, property mappings and joins from it. Query the actual underlying tables; metadata is not instance data. The ontology is not attached natively. Return factual results and the executed query when available.`n`n$context"
    $sourcePath = "$base/staging/datasources/$($lakehouse[0].id)"
    if ($Action -eq 'VerifySnapshot') {
        $settings = Invoke-LabFabricRequest -Path "$base/settings"
        $sources = Invoke-LabFabricRequest -Path "$base/datasources"
        $sourcePath = "$base/datasources/$($lakehouse[0].id)"
        $source = Invoke-LabFabricRequest -Path $sourcePath
        if ($settings.StatusCode -ne 200 -or $settings.Data.aiInstructions -cne $instructions) { throw 'Published agent context differs from the current ontology export.' }
        if ($sources.StatusCode -ne 200 -or $sources.Data.continuationToken -or @($sources.Data.value).Count -ne 1 -or $sources.Data.value[0].id -ne $lakehouse[0].id) { throw 'Expected exactly one published Lakehouse source and no native ontology attachment.' }
        if ($source.StatusCode -ne 200 -or $source.Data.instructions -cne $instructions) { throw 'Published source context differs from the current ontology export.' }
        if ($context -match '\b(?:M0[1-5]|A0[1-6])\b') { throw 'Fixture row identifiers must not appear in ontology context.' }
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue('')
    $tables = @()
    $visited = [Collections.Generic.HashSet[string]]::new()
    while ($queue.Count -gt 0) {
        $root = $queue.Dequeue()
        if (-not $visited.Add($root) -or $visited.Count -gt 30) { throw 'Unexpected schema traversal.' }
        $path = "$sourcePath/elements"
        if ($root) { $path += "?rootId=$([Uri]::EscapeDataString($root))" }
        $elements = Invoke-LabFabricRequest -Path $path
        if ($elements.StatusCode -ne 200 -or $elements.Data.continuationToken) { throw 'Complete schema unavailable.' }
        foreach ($element in $elements.Data.value) {
            if ($element.type -eq 'Table') { $tables += $element }
            elseif ($element.hasSubElements) { $queue.Enqueue($element.id) }
        }
    }
    if ($tables.Count -ne 2 -or @($tables | Where-Object { $_.displayName -notin @('Machines', 'Anomalies') }).Count -ne 0) { throw 'Unexpected source tables.' }
    if ($Action -eq 'VerifySnapshot') {
        if (@($tables | Where-Object { $_.isSelected -ne $true }).Count -ne 0) { throw 'Both published tables must be selected.' }
        $record = @{
            phase = 'Verified'; checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); contextSha256 = $hash
            definitionEvidence = $definition.EvidencePath; settingsEvidence = $settings.EvidencePath
            sourcesEvidence = $sources.EvidencePath; sourceEvidence = $source.EvidencePath
            tables = $tables.displayName; publishedContextMatchesOntology = $true; nativeOntologyAttached = $false
        }
        $record | ConvertTo-Json -Depth 20 | Set-Content $journal -Encoding utf8
        [pscustomobject]$record
        return
    }
    $record = @{ phase = 'Submitting'; submittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); ontologyId = $ontology[0].id; contextSha256 = $hash; definitionEvidence = $definition.EvidencePath; steps = @() }
    $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
    $updates = @(
        @{ path = "$base/staging/settings"; body = @{ aiInstructions = $instructions } },
        @{ path = $sourcePath; body = @{ instructions = $instructions; description = 'Synthetic maintenance data bound by the Gen2 ontology. Context is an explicitly synchronized snapshot, not a native ontology attachment.' } }
    )
    foreach ($table in $tables) { $updates += @{ path = "$sourcePath/elements?id=$([Uri]::EscapeDataString($table.id))"; body = @{ isSelected = $true } } }
    foreach ($update in $updates) {
        $record.pendingPath = $update.path
        $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
        $response = Invoke-LabFabricRequest -Path $update.path -Method PATCH -Body $update.body
        $record.steps += @{ path = $update.path; response = $response }
        $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
        if ($response.StatusCode -ne 200) { throw "Configuration failed: HTTP $($response.StatusCode). Inspect journal." }
    }
    $record.phase = 'Configured'
    $record.Remove('pendingPath')
    $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
    [pscustomobject]@{ Phase = $record.phase; ContextSha256 = $hash; Tables = $tables.displayName }
    return
} else {
    $journal = Join-Path $PSScriptRoot "../.local/gen2-$AgentName-$Action-$Attempt.json"
    if (Test-Path $journal) { throw 'Attempt already journaled. Inspect remote state and evidence before choosing another attempt.' }
    $path = "$base/staging/datasources"
    if ($Action -eq 'ResaveOntology') {
        $definition = Invoke-LabFabricRequest -Path "/v1/workspaces/$($state.workspaceId)/ontologies/$($ontology[0].id)/getDefinition" -Method POST
        if ($definition.StatusCode -ne 200 -or @($definition.Data.definition.parts | Where-Object path -Like '*.tmdl').Count -lt 5) { throw 'Confirmed TMDL definition required before reimport.' }
        $path = "/v1/workspaces/$($state.workspaceId)/ontologies/$($ontology[0].id)/updateDefinition"
        $body = @{ definition = $definition.Data.definition }
    } elseif ($Action -eq 'Publish') {
        $path = "$base/staging/publish"
        $body = @{ publishedDescription = 'Synthetic Gen2 ontology test.' }
    } else {
        $reference = @{ referenceType = 'ById'; workspaceId = $state.workspaceId }
        if ($Action -eq 'Attach') {
            $reference.itemId = $ontology[0].id
            $body = @{ type = 'FabricItem'; itemReference = $reference }
        } else {
            $reference.itemId = $lakehouse[0].id
            $body = @{ type = 'LakehouseTables'; lakehouseReference = $reference }
        }
    }
    $record = @{ action = $Action; phase = 'Submitting'; submittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); path = $path; body = $body }
    $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
    $response = Invoke-LabFabricRequest -Path $path -Method POST -Body $body
    $record.phase = 'ResponseReceived'
    $record.response = $response
    $record | ConvertTo-Json -Depth 100 | Set-Content $journal -Encoding utf8
}
$response | ConvertTo-Json -Depth 100