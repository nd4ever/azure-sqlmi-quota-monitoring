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
.PARAMETER LogAnalyticsWorkspaceMode
    Whether to use an existing workspace or create a new workspace. Prompts when omitted.
.PARAMETER LogAnalyticsWorkspaceName
    Existing workspace name or base name for a new workspace. Prompts when omitted.
.PARAMETER LogAnalyticsWorkspaceResourceGroupName
    Resource group containing an existing workspace. Discovered by workspace name when omitted.
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
.PARAMETER TenantId
    Microsoft Entra tenant to scan. Defaults to the deployment subscription tenant.
.PARAMETER Regions
    Azure regions queried in each source subscription.
.PARAMETER UsageNames
    Microsoft.Sql usage counters written to Log Analytics.
.PARAMETER SkipSourceReaderRole
    Omits Reader assignments on source subscriptions.
.PARAMETER SkipIngestionRole
    Omits Monitoring Metrics Publisher on the DCR.
.EXAMPLE
    ./scripts/Deploy-Solution.ps1 -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' -Location 'eastus2' -ResourceGroupName 'rg-sqlmi-quota' -LogAnalyticsWorkspaceName 'law-sqlmi-quota' -TableName 'SqlMiQuota_CL' -DataCollectionRuleName 'dcr-sqlmi-quota' -AutomationAccountName 'aa-sqlmi-quota' -RunbookName 'Get-SqlMiQuotaUsage' -ScheduleName 'Daily' -Regions @('eastus2')
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

    [Parameter(Mandatory = $false)]
    [ValidateSet('Existing', 'New')]
    [string]$LogAnalyticsWorkspaceMode,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')]
    [string]$LogAnalyticsWorkspaceName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogAnalyticsWorkspaceResourceGroupName,

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

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

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

function Get-EnabledTenantSubscriptionId {
    <#
    .SYNOPSIS
        Gets enabled Azure CLI subscriptions in a Microsoft Entra tenant.
    .PARAMETER TenantId
        Microsoft Entra tenant ID used to filter subscriptions.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$TenantId
    )

    $AccountOutput = Invoke-AzCli -Arguments @(
        'account', 'list',
        '--all',
        '--only-show-errors',
        '--output', 'json'
    )
    $Accounts = @(ConvertFrom-Json -InputObject ($AccountOutput -join [Environment]::NewLine))
    $SubscriptionIds = @(
        $Accounts |
            Where-Object { [string]$_.tenantId -eq $TenantId -and [string]$_.state -eq 'Enabled' } |
            ForEach-Object { [string]$_.id } |
            Sort-Object -Unique
    )

    if ($SubscriptionIds.Count -eq 0) {
        throw "Azure CLI cannot access any enabled subscriptions in tenant $TenantId."
    }

    return $SubscriptionIds
}

function Get-ConfiguredRunbookContent {
    <#
    .SYNOPSIS
        Renders deployment values as defaults in the runbook template.
    .PARAMETER TemplatePath
        Path to the runbook template.
    .PARAMETER TenantId
        Default Microsoft Entra tenant ID.
    .PARAMETER RegionsJson
        Default JSON array of Azure regions.
    .PARAMETER LogsIngestionEndpoint
        Default direct DCR ingestion endpoint.
    .PARAMETER DcrImmutableId
        Default immutable DCR ID.
    .PARAMETER StreamName
        Default DCR stream name.
    .PARAMETER UsageNamesJson
        Default JSON array of Microsoft.Sql usage counters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$RegionsJson,

        [Parameter(Mandatory = $true)]
        [string]$LogsIngestionEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory = $true)]
        [string]$StreamName,

        [Parameter(Mandatory = $true)]
        [string]$UsageNamesJson
    )

    $Content = Get-Content -LiteralPath $TemplatePath -Raw
    $Replacements = [ordered]@{
        '__TENANT_ID__'               = $TenantId
        '__REGIONS_JSON__'            = $RegionsJson
        '__LOGS_INGESTION_ENDPOINT__' = $LogsIngestionEndpoint
        '__DCR_IMMUTABLE_ID__'        = $DcrImmutableId
        '__STREAM_NAME__'             = $StreamName
        '__USAGE_NAMES_JSON__'        = $UsageNamesJson
    }

    foreach ($Replacement in $Replacements.GetEnumerator()) {
        if (-not $Content.Contains([string]$Replacement.Key)) {
            throw "Runbook template placeholder $($Replacement.Key) was not found."
        }

        $EscapedValue = ([string]$Replacement.Value).Replace("'", "''")
        $Content = $Content.Replace([string]$Replacement.Key, $EscapedValue)
    }

    if ($Content -match '__[A-Z0-9_]+__') {
        throw "The configured runbook still contains placeholder $($Matches[0])."
    }

    return $Content
}

function Read-LogAnalyticsWorkspaceMode {
    <#
    .SYNOPSIS
        Prompts for the Log Analytics workspace deployment mode.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    while ($true) {
        $Selection = (Read-Host 'Use an [E]xisting Log Analytics workspace or create a [N]ew one?').Trim()
        switch ($Selection.ToLowerInvariant()) {
            { $_ -in @('e', 'existing') } { return 'Existing' }
            { $_ -in @('n', 'new') } { return 'New' }
            default { Write-Warning 'Enter E for Existing or N for New.' }
        }
    }
}

function Get-GeneratedLogAnalyticsWorkspaceName {
    <#
    .SYNOPSIS
        Appends a stable five-character suffix to a workspace base name.
    .PARAMETER BaseName
        Base name for the new Log Analytics workspace.
    .PARAMETER DeploymentSubscriptionId
        Subscription used to deploy the workspace.
    .PARAMETER ResourceGroupName
        Resource group used to deploy the workspace.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 57)]
        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')]
        [string]$BaseName,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$DeploymentSubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName
    )

    $SuffixSeed = "$($DeploymentSubscriptionId.ToLowerInvariant())/$($ResourceGroupName.ToLowerInvariant())/$($BaseName.ToLowerInvariant())"
    $SuffixBytes = [System.Text.Encoding]::UTF8.GetBytes($SuffixSeed)
    $StableSuffix = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($SuffixBytes)).Substring(0, 5).ToLowerInvariant()
    return "$BaseName-$StableSuffix"
}

function Get-LogAnalyticsWorkspace {
    <#
    .SYNOPSIS
        Finds one existing Log Analytics workspace by name.
    .PARAMETER SubscriptionId
        Subscription containing the workspace.
    .PARAMETER WorkspaceName
        Name of the existing workspace.
    .PARAMETER ResourceGroupName
        Optional resource group used to disambiguate the workspace.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName
    )

    $Arguments = @(
        'resource', 'list',
        '--subscription', $SubscriptionId,
        '--resource-type', 'Microsoft.OperationalInsights/workspaces',
        '--name', $WorkspaceName,
        '--only-show-errors',
        '--output', 'json'
    )
    if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $Arguments += @('--resource-group', $ResourceGroupName)
    }

    $WorkspaceOutput = Invoke-AzCli -Arguments $Arguments
    $Workspaces = @(ConvertFrom-Json -InputObject ($WorkspaceOutput -join [Environment]::NewLine))
    if ($Workspaces.Count -eq 0) {
        throw "Log Analytics workspace '$WorkspaceName' was not found in subscription $SubscriptionId."
    }
    if ($Workspaces.Count -gt 1) {
        throw "Multiple Log Analytics workspaces named '$WorkspaceName' were found. Specify -LogAnalyticsWorkspaceResourceGroupName."
    }

    return $Workspaces[0]
}

function Resolve-LogAnalyticsWorkspaceConfiguration {
    <#
    .SYNOPSIS
        Resolves workspace prompts and deployment parameters.
    .PARAMETER Mode
        Existing or New. Prompts when omitted.
    .PARAMETER WorkspaceName
        Existing workspace name or new workspace base name.
    .PARAMETER WorkspaceResourceGroupName
        Optional resource group containing an existing workspace.
    .PARAMETER DeploymentSubscriptionId
        Subscription used to discover and deploy the workspace.
    .PARAMETER SolutionResourceGroupName
        Resource group used for a newly created workspace.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [string]$WorkspaceName,

        [Parameter(Mandatory = $false)]
        [string]$WorkspaceResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$DeploymentSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$SolutionResourceGroupName
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        $Mode = Read-LogAnalyticsWorkspaceMode
    }
    if ($Mode -notin @('Existing', 'New')) {
        throw "LogAnalyticsWorkspaceMode must be Existing or New. Received: $Mode"
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceName)) {
        $Prompt = if ($Mode -eq 'Existing') {
            'Enter the existing Log Analytics workspace name'
        }
        else {
            'Enter the base name for the new Log Analytics workspace'
        }
        $WorkspaceName = (Read-Host $Prompt).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceName)) {
        throw 'A Log Analytics workspace name is required.'
    }

    if ($Mode -eq 'New') {
        return [pscustomobject]@{
            Name              = Get-GeneratedLogAnalyticsWorkspaceName -BaseName $WorkspaceName -DeploymentSubscriptionId $DeploymentSubscriptionId -ResourceGroupName $SolutionResourceGroupName
            ResourceGroupName = $SolutionResourceGroupName
            SubscriptionId    = $DeploymentSubscriptionId
            ShouldCreate      = $true
        }
    }

    if ($WorkspaceName.Length -lt 4 -or $WorkspaceName.Length -gt 63 -or
        $WorkspaceName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$') {
        throw 'An existing Log Analytics workspace name must be 4-63 characters and contain only letters, numbers, and hyphens.'
    }

    $Workspace = Get-LogAnalyticsWorkspace `
        -SubscriptionId $DeploymentSubscriptionId `
        -WorkspaceName $WorkspaceName `
        -ResourceGroupName $WorkspaceResourceGroupName

    return [pscustomobject]@{
        Name              = [string]$Workspace.name
        ResourceGroupName = [string]$Workspace.resourceGroup
        SubscriptionId    = $DeploymentSubscriptionId
        ShouldCreate      = $false
    }
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    $ParameterFile = $null
    $JobScheduleBodyFile = $null
    $ConfiguredRunbookFile = $null

    try {
        if ($null -eq (Get-Command -Name az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required. Install it from https://aka.ms/installazurecli.'
        }

        $ParsedDeploymentSubscriptionId = [guid]::Empty
        if (-not [guid]::TryParse($DeploymentSubscriptionId, [ref]$ParsedDeploymentSubscriptionId)) {
            throw "DeploymentSubscriptionId is not a valid GUID: $DeploymentSubscriptionId"
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

        $DeploymentAccountText = Invoke-AzCli -Arguments @(
            'account', 'show',
            '--subscription', $DeploymentSubscriptionId,
            '--only-show-errors',
            '--output', 'json'
        )
        $DeploymentAccount = ConvertFrom-Json -InputObject ($DeploymentAccountText -join [Environment]::NewLine)
        $ResolvedTenantId = if ([string]::IsNullOrWhiteSpace($TenantId)) {
            [string]$DeploymentAccount.tenantId
        }
        else {
            $TenantId
        }
        if ($ResolvedTenantId -ne [string]$DeploymentAccount.tenantId) {
            throw "TenantId $ResolvedTenantId does not match the deployment subscription tenant $($DeploymentAccount.tenantId)."
        }

        $SourceSubscriptionIds = @(Get-EnabledTenantSubscriptionId -TenantId $ResolvedTenantId)
        Write-Information "Found $($SourceSubscriptionIds.Count) enabled subscriptions in tenant $ResolvedTenantId for Reader role assignment." -InformationAction Continue

        $WorkspaceConfiguration = Resolve-LogAnalyticsWorkspaceConfiguration `
            -Mode $LogAnalyticsWorkspaceMode `
            -WorkspaceName $LogAnalyticsWorkspaceName `
            -WorkspaceResourceGroupName $LogAnalyticsWorkspaceResourceGroupName `
            -DeploymentSubscriptionId $DeploymentSubscriptionId `
            -SolutionResourceGroupName $ResourceGroupName

        if ($WorkspaceConfiguration.ShouldCreate) {
            Write-Information "Creating Log Analytics workspace $($WorkspaceConfiguration.Name)." -InformationAction Continue
        }
        else {
            Write-Information "Using existing Log Analytics workspace $($WorkspaceConfiguration.Name)." -InformationAction Continue
        }

        $ParameterDocument = @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{
                location                       = @{ value = $Location }
                resourceGroupName              = @{ value = $ResourceGroupName }
                logAnalyticsWorkspaceName      = @{ value = $WorkspaceConfiguration.Name }
                logAnalyticsWorkspaceResourceGroupName = @{ value = $WorkspaceConfiguration.ResourceGroupName }
                logAnalyticsWorkspaceSubscriptionId = @{ value = $WorkspaceConfiguration.SubscriptionId }
                tableName                      = @{ value = $TableName }
                dataCollectionRuleName         = @{ value = $DataCollectionRuleName }
                automationAccountName          = @{ value = $AutomationAccountName }
                runbookName                    = @{ value = $RunbookName }
                scheduleName                   = @{ value = $ScheduleName }
                scheduleStartTime              = @{ value = $ParsedScheduleStartTime.ToString('o') }
                scheduleTimeZone               = @{ value = $ScheduleTimeZone }
                sourceSubscriptionIds          = @{ value = @($SourceSubscriptionIds) }
                shouldCreateLogAnalyticsWorkspace = @{ value = $WorkspaceConfiguration.ShouldCreate }
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
        $ConfiguredRunbookContent = Get-ConfiguredRunbookContent `
            -TemplatePath $RunbookFile `
            -TenantId $ResolvedTenantId `
            -RegionsJson (ConvertTo-JsonArrayParameter -Value $Regions) `
            -LogsIngestionEndpoint ([string]$DeploymentOutputs.logsIngestionEndpoint.value) `
            -DcrImmutableId ([string]$DeploymentOutputs.dataCollectionRuleImmutableId.value) `
            -StreamName ([string]$DeploymentOutputs.streamName.value) `
            -UsageNamesJson (ConvertTo-JsonArrayParameter -Value $UsageNames)
        $ConfiguredRunbookFile = New-TemporaryFile
        Set-Content -LiteralPath $ConfiguredRunbookFile -Value $ConfiguredRunbookContent -Encoding utf8NoBOM

        Write-Information "Uploading and publishing runbook $RunbookName." -InformationAction Continue
        $null = Invoke-AzCli -Arguments @(
            'automation', 'runbook', 'replace-content',
            '--ids', $RunbookResourceId,
            '--content', "@$ConfiguredRunbookFile",
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
                parameters = @{}
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
            LogAnalyticsWorkspaceName = $WorkspaceConfiguration.Name
            AutomationAccountId   = $AutomationAccountId
            DataCollectionRuleId  = [string]$DeploymentOutputs.dataCollectionRuleId.value
            RunbookName           = $RunbookName
            ScheduleName          = $ScheduleName
            TenantId              = $ResolvedTenantId
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
        if ($null -ne $ConfiguredRunbookFile) {
            Remove-Item -LiteralPath $ConfiguredRunbookFile -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion Main Execution