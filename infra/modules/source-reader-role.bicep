metadata name = 'SQL Usage Source Reader Role'
metadata description = 'Grants an Azure Automation managed identity Reader access to a source subscription.'

targetScope = 'subscription'

@description('Principal ID of the Azure Automation Account system-assigned managed identity.')
param principalId string

var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, readerRoleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
  }
}

@description('Resource ID of the Reader role assignment.')
output roleAssignmentId string = readerRoleAssignment.id
