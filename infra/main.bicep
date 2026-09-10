metadata name = 'SQL Managed Instance Quota Monitoring'
metadata description = 'Deploys SQL Managed Instance quota collection, ingestion, and scheduling resources.'

targetScope = 'subscription'

@description('Azure region for the resource group and monitoring resources.')
param location string

@description('Name of the resource group to create for the solution.')
param resourceGroupName string

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Resource group containing the Log Analytics workspace.')
param logAnalyticsWorkspaceResourceGroupName string = resourceGroupName

@description('Subscription containing the Log Analytics workspace.')
param logAnalyticsWorkspaceSubscriptionId string = subscription().subscriptionId

@description('Whether to create the Log Analytics workspace.')
param shouldCreateLogAnalyticsWorkspace bool = true

@description('Name of the Log Analytics custom table. The name must end with _CL.')
param tableName string

@description('Whether to create an Azure Monitor alert for SQL Managed Instance quota usage.')
param shouldCreateQuotaAlert bool = false

@description('Quota usage percentage that causes the Azure Monitor alert to fire.')
@minValue(1)
@maxValue(100)
param quotaAlertThresholdPercentage int = 80

@description('DisplayName column value monitored by the Azure Monitor alert.')
param quotaAlertDisplayName string?

@description('Name of the direct Data Collection Rule.')
param dataCollectionRuleName string

@description('Name of the Azure Automation Account.')
param automationAccountName string

@description('Name of the PowerShell 7.2 runbook.')
param runbookName string

@description('Name of the daily Azure Automation schedule.')
param scheduleName string

@description('First schedule run time in ISO 8601 format. The value must be in the future.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT1H')

@description('IANA time zone used by the Azure Automation schedule.')
param scheduleTimeZone string = 'UTC'

@description('Subscription IDs from which the runbook reads Microsoft.Sql usage data.')
@minLength(1)
param sourceSubscriptionIds array

@description('Whether to grant the Automation Account Reader on each source subscription.')
param shouldAssignSourceReaderRole bool = true

@description('Whether to grant the Automation Account Monitoring Metrics Publisher on the DCR.')
param shouldAssignIngestionRole bool = true

@description('Tags applied to solution resources.')
param tags object = {}

resource resourceGroupResource 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'sqlmi-quota-log-analytics'
  scope: resourceGroup(logAnalyticsWorkspaceSubscriptionId, logAnalyticsWorkspaceResourceGroupName)
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    shouldCreateLogAnalyticsWorkspace: shouldCreateLogAnalyticsWorkspace
    tableName: tableName
    tags: tags
  }
  dependsOn: [
    resourceGroupResource
  ]
}

module solution 'modules/solution.bicep' = {
  name: 'sqlmi-quota-monitoring'
  scope: resourceGroupResource
  params: {
    automationAccountName: automationAccountName
    dataCollectionRuleName: dataCollectionRuleName
    dataCollectionRuleLocation: logAnalytics.outputs.logAnalyticsWorkspaceLocation
    location: location
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.logAnalyticsWorkspaceId
    runbookName: runbookName
    scheduleName: scheduleName
    scheduleStartTime: scheduleStartTime
    scheduleTimeZone: scheduleTimeZone
    shouldAssignIngestionRole: shouldAssignIngestionRole
    shouldCreateQuotaAlert: shouldCreateQuotaAlert
    quotaAlertDisplayName: quotaAlertDisplayName
    quotaAlertThresholdPercentage: quotaAlertThresholdPercentage
    tableName: tableName
    tags: tags
  }
}

module sourceReaderRoles 'modules/source-reader-role.bicep' = [for sourceSubscriptionId in sourceSubscriptionIds: if (shouldAssignSourceReaderRole) {
  name: 'source-reader-${take(uniqueString(sourceSubscriptionId), 8)}'
  scope: subscription(sourceSubscriptionId)
  params: {
    principalId: solution.outputs.automationPrincipalId
  }
}]

@description('Resource ID of the deployed resource group.')
output resourceGroupId string = resourceGroupResource.id

@description('Resource ID of the Azure Automation Account.')
output automationAccountId string = solution.outputs.automationAccountId

@description('Principal ID of the Azure Automation Account system-assigned managed identity.')
output automationPrincipalId string = solution.outputs.automationPrincipalId

@description('Name of the PowerShell 7.2 runbook.')
output runbookName string = solution.outputs.runbookName

@description('Resource ID of the Data Collection Rule.')
output dataCollectionRuleId string = solution.outputs.dataCollectionRuleId

@description('Immutable ID used in the Logs Ingestion API path.')
output dataCollectionRuleImmutableId string = solution.outputs.dataCollectionRuleImmutableId

@description('Logs Ingestion API endpoint exposed by the direct Data Collection Rule.')
output logsIngestionEndpoint string = solution.outputs.logsIngestionEndpoint

@description('Input stream name accepted by the Data Collection Rule.')
output streamName string = solution.outputs.streamName

@description('Resource ID of the Azure Monitor quota alert, or null when alert creation is disabled.')
output quotaAlertRuleId string? = solution.outputs.?quotaAlertRuleId
