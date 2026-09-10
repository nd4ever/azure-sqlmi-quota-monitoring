metadata name = 'SQL MI Quota Usage Alert'
metadata description = 'Deploys an Azure Monitor scheduled query alert for one SQL Managed Instance quota display name.'

@description('Name of the Azure Monitor scheduled query alert.')
param alertRuleName string

@description('Azure region for the Azure Monitor scheduled query alert.')
param location string

@description('Resource ID of the Log Analytics workspace queried by the alert.')
param logAnalyticsWorkspaceResourceId string

@description('Name of the Log Analytics custom table.')
param tableName string

@description('DisplayName column value monitored by the Azure Monitor alert.')
@minLength(1)
param quotaAlertDisplayName string

@description('Quota usage percentage that causes the Azure Monitor alert to fire.')
@minValue(1)
@maxValue(100)
param quotaAlertThresholdPercentage int

@description('Tags applied to the Azure Monitor scheduled query alert.')
param tags object

var escapedQuotaAlertDisplayName = replace(quotaAlertDisplayName, '\'', '\'\'')
var quotaAlertQuery = join([
  tableName
  '| where DisplayName =~ @\'${escapedQuotaAlertDisplayName}\''
  '| extend CurrentValueNumeric = todouble(CurrentValue), LimitNumeric = todouble(Limit)'
  '| where isnotnull(CurrentValueNumeric) and isnotnull(LimitNumeric) and LimitNumeric > 0.0'
  '| summarize arg_max(TimeGenerated, *) by SubscriptionId, Region, Name'
  '| extend UsagePercentage = 100.0 * CurrentValueNumeric / LimitNumeric'
  '| where UsagePercentage >= ${quotaAlertThresholdPercentage}'
  '| project TimeGenerated, Name, DisplayName, CurrentValue = CurrentValueNumeric, Limit = LimitNumeric, UsagePercentage, Unit, Region, SubscriptionId'
], '\n')

resource quotaUsageAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: alertRuleName
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: take('SQL MI quota >= ${quotaAlertThresholdPercentage}%: ${quotaAlertDisplayName}', 256)
    description: 'Alerts when the latest SQL Managed Instance quota value reaches the configured percentage of its limit.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT1H'
    windowSize: 'P2D'
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: quotaAlertQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
}

@description('Resource ID of the Azure Monitor quota alert.')
output quotaAlertRuleId string = quotaUsageAlert.id
