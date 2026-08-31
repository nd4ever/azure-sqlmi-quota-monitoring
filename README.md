---
title: Azure SQL Managed Instance Quota Monitoring
description: Deploy reusable SQL Managed Instance quota collection with Azure Automation and Azure Monitor Logs
ms.date: 2026-08-31
ms.topic: how-to
---

## Overview

This project deploys a daily, credential-free pipeline that collects regional
Azure SQL Managed Instance vCore quota values and writes them to a custom Log
Analytics table.

The solution is based on a verified production pattern. A `kind: Direct` Data
Collection Rule (DCR) exposes its own Logs Ingestion API endpoint, so a separate
Data Collection Endpoint (DCE) is not required for public network ingestion.

```mermaid
flowchart LR
    SUB[Source subscriptions] -->|Reader| AA[Azure Automation runbook]
    AA -->|Microsoft.Sql usages API| SUB
    AA -->|Monitoring Metrics Publisher| DCR[Direct DCR endpoint]
    DCR --> TABLE[Custom Log Analytics table]
    TABLE --> LAW[Log Analytics workspace]
```

## Deployed resources

The subscription-scoped Bicep template creates:

* Resource group
* Log Analytics workspace with 30-day retention
* Custom Analytics table for quota records
* Direct Data Collection Rule and transformation
* Azure Automation Account with a system-assigned managed identity
* PowerShell 7.2 runbook shell
* Daily Automation schedule
* `Reader` assignments on the selected source subscriptions
* `Monitoring Metrics Publisher` on the DCR

The deployment script publishes the local runbook and links it to the schedule.
No subscription IDs, resource IDs, endpoints, credentials, or existing managed
identities are embedded in the repository.

## Collected counters

The default configuration collects these regional vCore quota counters:

* `SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota`
* `SubscriptionSQLManagedInstancePremiumSeriesVCoreQuota`
* `SubscriptionSQLManagedInstancePremiumSeriesMemoryOptimizedVCoreQuota`

Each record includes the timestamp, counter name and display name, current
value, limit, unit, region, and source subscription ID.

## Prerequisites

Install or configure:

* PowerShell 7.2 or later
* Azure CLI with Bicep support
* Azure CLI `automation` extension
* An authenticated Azure CLI session
* Permission to create resources and role assignments in the deployment scope
* `Reader` role assignment permission on every source subscription

```powershell
az login
az extension add --name automation
az bicep install
```

The deployment identity typically needs `Contributor` plus `User Access
Administrator` at the target resource group or subscription. It also needs role
assignment permission on each source subscription. Runtime access is narrower:
the Automation Account receives only the two roles listed above.

## Deploy

Choose globally valid names where Azure requires them, then run:

```powershell
./scripts/Deploy-Solution.ps1 `
    -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Location 'eastus2' `
    -ResourceGroupName 'rg-sqlmi-quota-monitoring' `
    -LogAnalyticsWorkspaceName 'law-sqlmi-quota-monitoring' `
    -TableName 'SqlMiQuota_CL' `
    -DataCollectionRuleName 'dcr-sqlmi-quota-monitoring' `
    -AutomationAccountName 'aa-sqlmi-quota-monitoring' `
    -SourceSubscriptionIds @(
        '00000000-0000-0000-0000-000000000000',
        '11111111-1111-1111-1111-111111111111'
    ) `
    -Regions @('eastus2', 'centralus')
```

The schedule starts approximately one hour after deployment and repeats daily
in UTC. Use `-ScheduleStartTime` and `-ScheduleTimeZone` to change that behavior.
The time zone must be an IANA value supported by Azure Automation, such as
`America/New_York`.

Use `-SkipSourceReaderRole` or `-SkipIngestionRole` only when those assignments
are managed separately. The Automation Account identity must have equivalent
permissions before the runbook starts.

## Query quota usage

Replace the table name when you choose a different deployment value:

```kusto
SqlMiQuota_CL
| extend UtilizationPercent = iff(Limit > 0, CurrentValue / Limit * 100.0, 0.0)
| summarize arg_max(TimeGenerated, *) by SubscriptionId, Region, Name
| project TimeGenerated, SubscriptionId, Region, DisplayName,
          CurrentValue, Limit, UtilizationPercent
| order by UtilizationPercent desc
```

## Validate changes

Install the local test tools once:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Run all checks:

```powershell
npm run validate
```

Validation compiles the Bicep template and sample parameters, runs
PSScriptAnalyzer, and executes the Pester unit tests. GitHub Actions runs the
same command for pushes to `main` and for pull requests.

## Design notes

The Logs Ingestion API supports either a DCE or, for a direct DCR, the endpoint
published on the DCR itself. This project uses the latter. Add a DCE only when
your network design requires private links or another endpoint-specific
configuration; do not attach an unrelated historical DCE.

The runbook requests two managed identity tokens:

* `https://management.azure.com/` for reading Microsoft.Sql usage
* `https://monitor.azure.com/` for posting to the Logs Ingestion API

Transient HTTP responses (`408`, `429`, `500`, `502`, `503`, and `504`) use
bounded exponential retries. Records are posted as JSON arrays, including when
a region returns only one selected counter.

## References

* [Azure Monitor Logs Ingestion API overview](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview)
* [Data Collection Rules overview](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-overview)
* [Azure Automation managed identity](https://learn.microsoft.com/azure/automation/enable-managed-identity-for-automation)
* [Azure SQL resource provider usage API](https://learn.microsoft.com/rest/api/sql/usages/list-by-location)