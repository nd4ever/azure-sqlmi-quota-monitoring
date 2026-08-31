using './main.bicep'

param location = 'eastus2'
param resourceGroupName = 'rg-sqlmi-quota-monitoring'
param logAnalyticsWorkspaceName = 'law-sqlmi-quota-monitoring-a1b2c'
param shouldCreateLogAnalyticsWorkspace = true
param tableName = 'SqlMiQuota_CL'
param dataCollectionRuleName = 'dcr-sqlmi-quota-monitoring'
param automationAccountName = 'aa-sqlmi-quota-monitoring'
param runbookName = 'Get-SqlMiQuotaUsage'
param scheduleName = 'Daily'
param scheduleTimeZone = 'UTC'
param sourceSubscriptionIds = [
  '00000000-0000-0000-0000-000000000000'
]
param tags = {
  workload: 'sqlmi-quota-monitoring'
}
