#requires -Version 7.0
. (Join-Path $PSScriptRoot 'FabricApi.ps1')

function New-LabOntologyDefinition {
    param(
        [Parameter(Mandatory)][ValidateSet('Gen1', 'New')][string]$Experience,
        [Parameter(Mandatory)][guid]$WorkspaceId,
        [Parameter(Mandatory)][guid]$LakehouseId,
        [Parameter(Mandatory)][guid]$SqlEndpointId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9.-]+\.datawarehouse\.fabric\.microsoft\.com$')][string]$SqlServer
    )
    $name = "Maintenance$Experience"
    $rule = (Get-Content (Join-Path $PSScriptRoot '../fixtures/questions.json') -Raw | ConvertFrom-Json).businessRule
    $entities = @(
        @{ id = '100'; name = 'Machine'; table = 'Machines'; key = 'MachineId'; description = 'A synthetic industrial machine. Machines can have zero or more anomalies.'; columns = @(
            @{ id = '101'; name = 'MachineId'; type = 'String' },
            @{ id = '102'; name = 'Name'; type = 'String' },
            @{ id = '103'; name = 'Site'; type = 'String' }
        ) },
        @{ id = '200'; name = 'Anomaly'; table = 'Anomalies'; key = 'AnomalyId'; description = $rule; columns = @(
            @{ id = '201'; name = 'AnomalyId'; type = 'String' },
            @{ id = '202'; name = 'MachineId'; type = 'String' },
            @{ id = '203'; name = 'Severity'; type = 'String' },
            @{ id = '204'; name = 'Status'; type = 'String' },
            @{ id = '205'; name = 'DowntimeMinutes'; type = 'Double' }
        ) }
    )
    $parts = [Collections.Generic.List[object]]::new()
    $platform = @{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata = @{ type = 'Ontology'; displayName = $name }
        config = @{ version = '2.0'; logicalId = [guid]::NewGuid().ToString() }
    }
    $parts.Add((New-LabDefinitionPart -Path '.platform' -Text ($platform | ConvertTo-Json -Depth 10)))
    if ($Experience -eq 'Gen1') {
        $parts.Add((New-LabDefinitionPart -Path 'definition.json' -Text '{}'))
        foreach ($entity in $entities) {
            $definition = @{
                id = $entity.id; namespace = 'usertypes'; name = $entity.name
                namespaceType = 'Custom'; visibility = 'Visible'
                entityIdParts = @($entity.columns[0].id); displayNamePropertyId = $entity.columns[0].id
                semanticEnrichment = @{ description = $entity.description }
                properties = @($entity.columns | ForEach-Object { @{ id = $_.id; name = $_.name; valueType = $_.type } })
                timeseriesProperties = @()
            }
            $parts.Add((New-LabDefinitionPart -Path "EntityTypes/$($entity.id)/definition.json" -Text ($definition | ConvertTo-Json -Depth 20)))
            $bindingId = [guid]::NewGuid().ToString()
            $binding = @{
                id = $bindingId
                dataBindingConfiguration = @{
                    dataBindingType = 'NonTimeSeries'
                    propertyBindings = @($entity.columns | ForEach-Object { @{ sourceColumnName = $_.name; targetPropertyId = $_.id } })
                    sourceTableProperties = @{
                        sourceType = 'LakehouseTable'; workspaceId = $WorkspaceId.ToString(); itemId = $LakehouseId.ToString()
                        sourceTableName = $entity.table; sourceSchema = 'dbo'
                    }
                }
            }
            $parts.Add((New-LabDefinitionPart -Path "EntityTypes/$($entity.id)/DataBindings/$bindingId.json" -Text ($binding | ConvertTo-Json -Depth 20)))
        }
        $relationship = @{
            namespace = 'usertypes'; id = '300'; name = 'OccursOn'; namespaceType = 'Custom'
            source = @{ entityTypeId = '200' }; target = @{ entityTypeId = '100' }
        }
        $parts.Add((New-LabDefinitionPart -Path 'RelationshipTypes/300/definition.json' -Text ($relationship | ConvertTo-Json -Depth 10)))
        $contextId = [guid]::NewGuid().ToString()
        $context = @{
            id = $contextId
            dataBindingTable = @{
                sourceType = 'LakehouseTable'; workspaceId = $WorkspaceId.ToString(); itemId = $LakehouseId.ToString()
                sourceTableName = 'Anomalies'; sourceSchema = 'dbo'
            }
            sourceKeyRefBindings = @(@{ sourceColumnName = 'AnomalyId'; targetPropertyId = '201' })
            targetKeyRefBindings = @(@{ sourceColumnName = 'MachineId'; targetPropertyId = '101' })
        }
        $parts.Add((New-LabDefinitionPart -Path "RelationshipTypes/300/Contextualizations/$contextId.json" -Text ($context | ConvertTo-Json -Depth 20)))
    } else {
        $parts.Add((New-LabDefinitionPart -Path 'database.tmdl' -Text "database`n`tcompatibilityLevel: 1000000`n"))
        $model = "model Model`n`tculture: en-US`n`nref namespace default`n"
        $parts.Add((New-LabDefinitionPart -Path 'namespaces/default.tmdl' -Text "namespace default`n"))
        foreach ($entity in $entities) {
            $model += "ref table $($entity.table)`nref entity $($entity.name)`n"
            $table = "table $($entity.table)`n"
            $entityText = "/// $($entity.description)`nentity $($entity.name)`n`tbackingTable: $($entity.table)`n`tkeyProperty: $($entity.key)`n"
            foreach ($column in $entity.columns) {
                $dataType = $column.type.ToLowerInvariant()
                $table += "`n`tcolumn $($column.name)`n`t`tdataType: $dataType`n`t`tsourceColumn: $($column.name)`n"
                $entityText += "`n`tproperty $($column.name)`n`t`tdataType: $dataType`n`t`tbackingConfiguration`n`t`t`tvalueColumn: $($entity.table).$($column.name)`n"
            }
            $table += "`n`tpartition $($entity.table) = entity`n`t`tmode: directLake`n`t`tsource`n`t`t`tentityName: $($entity.table)`n`t`t`tschemaName: dbo`n`t`t`texpressionSource: DatabaseQuery`n"
            $parts.Add((New-LabDefinitionPart -Path "tables/$($entity.table).tmdl" -Text $table))
            $parts.Add((New-LabDefinitionPart -Path "entities/$($entity.name).tmdl" -Text $entityText))
        }
        $parts.Add((New-LabDefinitionPart -Path 'model.tmdl' -Text $model))
        $expression = "expression DatabaseQuery =`n`t`tlet`n`t`t`tdatabase = Sql.Database(`"$SqlServer`", `"$SqlEndpointId`")`n`t`tin`n`t`t`tdatabase`n"
        $parts.Add((New-LabDefinitionPart -Path 'expressions.tmdl' -Text $expression))
        $parts.Add((New-LabDefinitionPart -Path 'relationships.tmdl' -Text "relationship anomaly_machine`n`tfromColumn: Anomalies.MachineId`n`ttoColumn: Machines.MachineId`n"))
        $parts.Add((New-LabDefinitionPart -Path 'entityRelationships.tmdl' -Text "entityRelationship OccursOn`n`tfromEntity: Anomaly`n`ttoEntity: Machine`n`tbackingConfiguration`n`t`trelationship: anomaly_machine`n"))
    }
    @{ parts = $parts.ToArray() }
}