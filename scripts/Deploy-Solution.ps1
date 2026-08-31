#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Deploys Azure SQL Managed Instance quota monitoring.
.DESCRIPTION
    Deploys the Bicep infrastructure at subscription scope, uploads and
    publishes the PowerShell 7.2 runbook, and links it to the daily schedule.
.PARAMETER DeploymentSubscriptionId
    Subscription that hosts the monitoring resources.
.PARAMETER Location
    Azure region for the deployment and monitoring resources.
.PARAMETER ResourceGroupName
    Resource group created for the solution.
.PARAMETER LogAnalyticsWorkspaceName
    Log Analytics workspace name.
.PARAMETER TableName
    Custom Log Analytics table name ending in _CL.
.PARAMETER DataCollectionRuleName
    Direct Data Collection Rule name.
.PARAMETER AutomationAccountName
    Azure Automation Account name.
.PARAMETER RunbookName
    PowerShell 7.2 runbook name.
.PARAMETER ScheduleName
    Daily Azure Automation schedule name.
.PARAMETER ScheduleStartTime
    First schedule run time in ISO 8601 format. It must be in the future.
.PARAMETER ScheduleTimeZone
    IANA time zone used by the Azure Automation schedule.
.PARAMETER SourceSubscriptionIds
    Subscriptions from which the runbook reads Microsoft.Sql usage data.
.PARAMETER Regions
    Azure regions queried in each source subscription.
.PARAMETER UsageNames
    Microsoft.Sql usage counters written to Log Analytics.
.PARAMETER SkipSourceReaderRole
    Omits Reader assignments on source subscriptions.
.PARAMETER SkipIngestionRole
    Omits Monitoring Metrics Publisher on the DCR.
.EXAMPLE
    ./scripts/Deploy-Solution.ps1 -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' -Location 'eastus2' -ResourceGroupName 'rg-sqlmi-quota' -LogAnalyticsWorkspaceName 'law-sqlmi-quota' -TableName 'SqlMiQuota_CL' -DataCollectionRuleName 'dcr-sqlmi-quota' -AutomationAccountName 'aa-sqlmi-quota' -RunbookName 'Get-SqlMiQuotaUsage' -ScheduleName 'Daily' -SourceSubscriptionIds @('00000000-0000-0000-0000-000000000000') -Regions @('eastus2')
.NOTES
    Requires Azure CLI, Bicep CLI support, and permission to deploy resources
    and create the requested role assignments.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$DeploymentSubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LogAnalyticsWorkspaceName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*_CL$')]
    [string]$TableName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DataCollectionRuleName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RunbookName = 'Get-SqlMiQuotaUsage',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ScheduleName = 'Daily',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ScheduleStartTime = ([datetimeoffset]::UtcNow.AddHours(1).ToString('o')),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ScheduleTimeZone = 'UTC',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceSubscriptionIds,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Regions,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$UsageNames = @(
        'SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota',
        'SubscriptionSQLManagedInstancePremiumSeriesVCoreQuota',
        'SubscriptionSQLManagedInstancePremiumSeriesMemoryOptimizedVCoreQuota'
    ),

    [Parameter(Mandatory = $false)]
    [switch]$SkipSourceReaderRole,

    [Parameter(Mandatory = $false)]
    [switch]$SkipIngestionRole
)

$ErrorActionPreference = 'Stop'

#region Functions

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs Azure CLI and throws when it returns a nonzero exit code.
    .PARAMETER Arguments
        Arguments passed to the Azure CLI executable.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $Output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($Output -join [Environment]::NewLine)"
    }

    return $Output
}

function ConvertTo-JsonArrayParameter {
    <#
    .SYNOPSIS
        Serializes string values as a flat JSON array.
    .PARAMETER Value
        One or more string values to serialize.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Value
    )

    return ConvertTo-Json -InputObject @($Value) -Compress
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    $ParameterFile = $null
    $JobScheduleBodyFile = $null

    try {
        if ($null -eq (Get-Command -Name az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required. Install it from https://aka.ms/installazurecli.'
        }

        $ParsedDeploymentSubscriptionId = [guid]::Empty
        if (-not [guid]::TryParse($DeploymentSubscriptionId, [ref]$ParsedDeploymentSubscriptionId)) {
            throw "DeploymentSubscriptionId is not a valid GUID: $DeploymentSubscriptionId"
        }

        foreach ($SourceSubscriptionId in $SourceSubscriptionIds) {
            $ParsedSourceSubscriptionId = [guid]::Empty
            if (-not [guid]::TryParse($SourceSubscriptionId, [ref]$ParsedSourceSubscriptionId)) {
                throw "SourceSubscriptionIds contains an invalid GUID: $SourceSubscriptionId"
            }
        }

        $ParsedScheduleStartTime = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($ScheduleStartTime, [ref]$ParsedScheduleStartTime)) {
            throw "ScheduleStartTime is not a valid ISO 8601 date and time: $ScheduleStartTime"
        }
        if ($ParsedScheduleStartTime -le [datetimeoffset]::UtcNow.AddMinutes(5)) {
            throw 'ScheduleStartTime must be more than five minutes in the future.'
        }

        $ProjectRoot = Split-Path $PSScriptRoot -Parent
        $TemplateFile = Join-Path $ProjectRoot 'infra/main.bicep'
        $RunbookFile = Join-Path $ProjectRoot 'runbooks/Get-SqlMiQuotaUsage.ps1'
        $DeploymentName = "sqlmi-quota-$([datetime]::UtcNow.ToString('yyyyMMddHHmmss'))"

        $null = Invoke-AzCli -Arguments @(
            'account', 'show',
            '--subscription', $DeploymentSubscriptionId,
            '--only-show-errors',
            '--output', 'none'
        )

        $ParameterDocument = @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{
                location                       = @{ value = $Location }
                resourceGroupName              = @{ value = $ResourceGroupName }
                logAnalyticsWorkspaceName      = @{ value = $LogAnalyticsWorkspaceName }
                tableName                      = @{ value = $TableName }
                dataCollectionRuleName         = @{ value = $DataCollectionRuleName }
                automationAccountName          = @{ value = $AutomationAccountName }
                runbookName                    = @{ value = $RunbookName }
                scheduleName                   = @{ value = $ScheduleName }
                scheduleStartTime              = @{ value = $ParsedScheduleStartTime.ToString('o') }
                scheduleTimeZone               = @{ value = $ScheduleTimeZone }
                sourceSubscriptionIds          = @{ value = @($SourceSubscriptionIds) }
                shouldAssignSourceReaderRole   = @{ value = -not $SkipSourceReaderRole.IsPresent }
                shouldAssignIngestionRole      = @{ value = -not $SkipIngestionRole.IsPresent }
            }
        }

        $ParameterFile = New-TemporaryFile
        $ParameterDocument |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $ParameterFile -Encoding utf8NoBOM

        Write-Information "Deploying infrastructure to subscription $DeploymentSubscriptionId." -InformationAction Continue
        $DeploymentOutputText = Invoke-AzCli -Arguments @(
            'deployment', 'sub', 'create',
            '--name', $DeploymentName,
            '--subscription', $DeploymentSubscriptionId,
            '--location', $Location,
            '--template-file', $TemplateFile,
            '--parameters', "@$ParameterFile",
            '--query', 'properties.outputs',
            '--only-show-errors',
            '--output', 'json'
        )
        $DeploymentOutputs = ConvertFrom-Json -InputObject ($DeploymentOutputText -join [Environment]::NewLine)

        $AutomationAccountId = [string]$DeploymentOutputs.automationAccountId.value
        $RunbookResourceId = "$AutomationAccountId/runbooks/$RunbookName"

        Write-Information "Uploading and publishing runbook $RunbookName." -InformationAction Continue
        $null = Invoke-AzCli -Arguments @(
            'automation', 'runbook', 'replace-content',
            '--ids', $RunbookResourceId,
            '--content', "@$RunbookFile",
            '--subscription', $DeploymentSubscriptionId,
            '--only-show-errors',
            '--output', 'none'
        )
        $null = Invoke-AzCli -Arguments @(
            'automation', 'runbook', 'publish',
            '--ids', $RunbookResourceId,
            '--subscription', $DeploymentSubscriptionId,
            '--only-show-errors',
            '--output', 'none'
        )

        $JobSchedulesUri = "https://management.azure.com$AutomationAccountId/jobSchedules?api-version=2023-11-01"
        $ExistingJobSchedulesText = Invoke-AzCli -Arguments @(
            'rest',
            '--method', 'get',
            '--uri', $JobSchedulesUri,
            '--subscription', $DeploymentSubscriptionId,
            '--only-show-errors',
            '--output', 'json'
        )
        $ExistingJobSchedules = ConvertFrom-Json -InputObject ($ExistingJobSchedulesText -join [Environment]::NewLine)

        foreach ($ExistingJobSchedule in @($ExistingJobSchedules.value | Where-Object {
                    $_.properties.runbook.name -eq $RunbookName -and
                    $_.properties.schedule.name -eq $ScheduleName
                })) {
            $DeleteJobScheduleUri = "https://management.azure.com$($ExistingJobSchedule.id)?api-version=2023-11-01"
            $null = Invoke-AzCli -Arguments @(
                'rest',
                '--method', 'delete',
                '--uri', $DeleteJobScheduleUri,
                '--subscription', $DeploymentSubscriptionId,
                '--only-show-errors',
                '--output', 'none'
            )
        }

        $JobScheduleGuid = [guid]::NewGuid().ToString()
        $JobScheduleUri = "https://management.azure.com$AutomationAccountId/jobSchedules/${JobScheduleGuid}?api-version=2023-11-01"

        $JobScheduleBody = @{
            properties = @{
                parameters = @{
                    SubscriptionIdsJson  = ConvertTo-JsonArrayParameter -Value $SourceSubscriptionIds
                    RegionsJson          = ConvertTo-JsonArrayParameter -Value $Regions
                    LogsIngestionEndpoint = [string]$DeploymentOutputs.logsIngestionEndpoint.value
                    DcrImmutableId       = [string]$DeploymentOutputs.dataCollectionRuleImmutableId.value
                    StreamName           = [string]$DeploymentOutputs.streamName.value
                    UsageNamesJson       = ConvertTo-JsonArrayParameter -Value $UsageNames
                    MaxRetryCount        = '4'
                }
                runbook = @{
                    name = $RunbookName
                }
                schedule = @{
                    name = $ScheduleName
                }
            }
        }

        $JobScheduleBodyFile = New-TemporaryFile
        $JobScheduleBody |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $JobScheduleBodyFile -Encoding utf8NoBOM

        Write-Information "Linking runbook $RunbookName to schedule $ScheduleName." -InformationAction Continue
        $null = Invoke-AzCli -Arguments @(
            'rest',
            '--method', 'put',
            '--uri', $JobScheduleUri,
            '--body', "@$JobScheduleBodyFile",
            '--subscription', $DeploymentSubscriptionId,
            '--only-show-errors',
            '--output', 'none'
        )

        [pscustomobject]@{
            ResourceGroupId       = [string]$DeploymentOutputs.resourceGroupId.value
            AutomationAccountId   = $AutomationAccountId
            DataCollectionRuleId  = [string]$DeploymentOutputs.dataCollectionRuleId.value
            RunbookName           = $RunbookName
            ScheduleName          = $ScheduleName
            SourceSubscriptionIds = @($SourceSubscriptionIds)
            Regions               = @($Regions)
        }
    }
    catch {
        Write-Error -ErrorAction Continue "Deployment failed: $($_.Exception.Message)"
        exit 1
    }
    finally {
        if ($null -ne $ParameterFile) {
            Remove-Item -LiteralPath $ParameterFile -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $JobScheduleBodyFile) {
            Remove-Item -LiteralPath $JobScheduleBodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion Main Execution