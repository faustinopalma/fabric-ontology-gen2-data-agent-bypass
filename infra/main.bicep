targetScope = 'resourceGroup'

@description('Globally unique name for this dedicated test capacity.')
@minLength(3)
@maxLength(63)
param capacityName string = 'ontologygen2${uniqueString(resourceGroup().id)}'

@description('Fabric region. Keep every test item on this capacity.')
param location string = 'swedencentral'

@description('User principal name of the test capacity administrator.')
@minLength(1)
param administrator string

@description('Smallest paid capacity supported by Fabric data agent. Billable while active.')
@allowed(['F2'])
param sku string = 'F2'

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: capacityName
  location: location
  sku: {
    name: sku
    tier: 'Fabric'
  }
  tags: {
    project: 'fabric-ontology-gen2-lab'
    purpose: 'issue-reproduction'
    lifecycle: 'temporary'
  }
  properties: {
    administration: {
      members: [administrator]
    }
  }
}

output capacityResourceId string = capacity.id
output capacityName string = capacity.name
output capacitySku string = capacity.sku.name
