metadata name = 'SQL MI Quota Log Analytics Resources'
metadata description = 'Creates or references a Log Analytics workspace and deploys the quota table.'

@description('Azure region used when creating the Log Analytics workspace.')
param location string

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Whether to create the Log Analytics workspace.')
param shouldCreateLogAnalyticsWorkspace bool

@description('Name of the Log Analytics custom table.')
param tableName string

@description('Tags applied when creating the Log Analytics workspace.')
param tags object

resource createdLogAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (shouldCreateLogAnalyticsWorkspace) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource quotaTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: logAnalyticsWorkspace
  name: tableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 30
    schema: {
      name: tableName
      columns: [
        {
          name: 'TimeGenerated'
          type: 'dateTime'
        }
        {
          name: 'Name'
          type: 'string'
        }
        {
          name: 'DisplayName'
          type: 'string'
        }
        {
          name: 'CurrentValue'
          type: 'real'
        }
        {
          name: 'Limit'
          type: 'real'
        }
        {
          name: 'Unit'
          type: 'string'
        }
        {
          name: 'Region'
          type: 'string'
        }
        {
          name: 'SubscriptionId'
          type: 'string'
        }
      ]
    }
  }
  dependsOn: [
    createdLogAnalyticsWorkspace
  ]
}

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

@description('Azure region of the Log Analytics workspace.')
output logAnalyticsWorkspaceLocation string = shouldCreateLogAnalyticsWorkspace ? location : logAnalyticsWorkspace.location
