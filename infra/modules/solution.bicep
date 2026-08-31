metadata name = 'SQL MI Quota Monitoring Resources'
metadata description = 'Deploys the workspace, custom table, direct DCR, Automation Account, schedule, and ingestion role.'

@description('Name of the Azure Automation Account.')
param automationAccountName string

@description('Name of the direct Data Collection Rule.')
param dataCollectionRuleName string

@description('Azure region for all resources.')
param location string

@description('Azure region for the Data Collection Rule. It must match the Log Analytics workspace region.')
param dataCollectionRuleLocation string

@description('Resource ID of the Log Analytics workspace.')
param logAnalyticsWorkspaceResourceId string

@description('Name of the PowerShell 7.2 runbook.')
param runbookName string

@description('Name of the daily Azure Automation schedule.')
param scheduleName string

@description('First schedule run time in ISO 8601 format.')
param scheduleStartTime string

@description('IANA time zone used by the Azure Automation schedule.')
param scheduleTimeZone string

@description('Whether to grant the Automation Account Monitoring Metrics Publisher on the DCR.')
param shouldAssignIngestionRole bool

@description('Name of the Log Analytics custom table.')
param tableName string

@description('Tags applied to solution resources.')
param tags object

var inputStreamName = 'Custom-SqlMiQuota'
var outputStreamName = 'Custom-${tableName}'
var logAnalyticsDestinationName = 'logAnalytics'
var monitoringMetricsPublisherRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: dataCollectionRuleLocation
  kind: 'Direct'
  tags: tags
  properties: {
    streamDeclarations: {
      '${inputStreamName}': {
        columns: [
          {
            name: 'TimeGenerated'
            type: 'datetime'
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
    destinations: {
      logAnalytics: [
        {
          name: logAnalyticsDestinationName
          workspaceResourceId: logAnalyticsWorkspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          inputStreamName
        ]
        destinations: [
          logAnalyticsDestinationName
        ]
        transformKql: 'source | project TimeGenerated = todatetime(TimeGenerated), Name = tostring(Name), DisplayName = tostring(DisplayName), CurrentValue = toreal(CurrentValue), Limit = toreal(Limit), Unit = tostring(Unit), Region = tostring(Region), SubscriptionId = tostring(SubscriptionId)'
        outputStream: outputStreamName
      }
    ]
  }
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: true
    sku: {
      name: 'Basic'
    }
  }
}

resource quotaRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    description: 'Collects regional Azure SQL Managed Instance vCore quota usage and sends it to Azure Monitor Logs.'
    logProgress: false
    logVerbose: false
    runbookType: 'PowerShell72'
  }
}

resource dailySchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: scheduleName
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: scheduleStartTime
    timeZone: scheduleTimeZone
  }
}

resource ingestionRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (shouldAssignIngestionRole) {
  name: guid(dataCollectionRule.id, automationAccount.id, monitoringMetricsPublisherRoleDefinitionId)
  scope: dataCollectionRule
  properties: {
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleDefinitionId)
  }
}

@description('Resource ID of the Azure Automation Account.')
output automationAccountId string = automationAccount.id

@description('Principal ID of the Azure Automation Account system-assigned managed identity.')
output automationPrincipalId string = automationAccount.identity.principalId

@description('Name of the PowerShell 7.2 runbook.')
output runbookName string = quotaRunbook.name

@description('Resource ID of the Data Collection Rule.')
output dataCollectionRuleId string = dataCollectionRule.id

@description('Immutable ID used in the Logs Ingestion API path.')
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId

@description('Logs Ingestion API endpoint exposed by the direct Data Collection Rule.')
output logsIngestionEndpoint string = dataCollectionRule.properties.endpoints.logsIngestion

@description('Input stream name accepted by the Data Collection Rule.')
output streamName string = inputStreamName

@description('Name of the deployed Azure Automation schedule.')
output scheduleName string = dailySchedule.name
