#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Collects regional Azure SQL Managed Instance vCore quota usage.
.DESCRIPTION
    Uses the Azure Automation Account system-assigned managed identity to read
    Microsoft.Sql regional usage from every accessible subscription in a tenant
    and send selected counters to an Azure Monitor direct Data Collection Rule
    endpoint.
.PARAMETER TenantId
    Microsoft Entra tenant containing the subscriptions to query.
.PARAMETER RegionsJson
    JSON array of Azure region names to query.
.PARAMETER LogsIngestionEndpoint
    Logs ingestion endpoint exposed by the direct Data Collection Rule.
.PARAMETER DcrImmutableId
    Immutable ID of the Data Collection Rule.
.PARAMETER StreamName
    Input stream name declared by the Data Collection Rule.
.PARAMETER UsageNamesJson
    JSON array of Microsoft.Sql usage counter names to collect.
.PARAMETER SqlUsageApiVersion
    API version used to query Microsoft.Sql regional usage.
.PARAMETER LogsIngestionApiVersion
    API version used to send records through the Logs Ingestion API.
.PARAMETER MaxRetryCount
    Maximum retries after the initial request for transient HTTP failures.
.EXAMPLE
    ./Get-SqlMiQuotaUsage.ps1 -TenantId '00000000-0000-0000-0000-000000000000' -RegionsJson '["eastus2"]' -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' -DcrImmutableId 'dcr-00000000000000000000000000000000' -StreamName 'Custom-SqlMiQuota'
.NOTES
    Designed for the Azure Automation PowerShell 7.2 runtime.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId = '__TENANT_ID__',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RegionsJson = '__REGIONS_JSON__',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^https://[^/]+$')]
    [string]$LogsIngestionEndpoint = '__LOGS_INGESTION_ENDPOINT__',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^dcr-[a-fA-F0-9]+$')]
    [string]$DcrImmutableId = '__DCR_IMMUTABLE_ID__',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^Custom-[A-Za-z][A-Za-z0-9_-]*$')]
    [string]$StreamName = '__STREAM_NAME__',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$UsageNamesJson = '__USAGE_NAMES_JSON__',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}(-preview)?$')]
    [string]$SqlUsageApiVersion = '2023-08-01',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}(-preview)?$')]
    [string]$LogsIngestionApiVersion = '2023-01-01',

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 10)]
    [int]$MaxRetryCount = 4
)

$ErrorActionPreference = 'Stop'

#region Functions

function ConvertFrom-JsonArrayParameter {
    <#
    .SYNOPSIS
        Converts a JSON array parameter to a validated string array.
    .PARAMETER Json
        JSON text that must represent a non-empty array.
    .PARAMETER ParameterName
        Parameter name included in validation errors.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ParameterName
    )

    $ParsedValue = ConvertFrom-Json -InputObject $Json -NoEnumerate
    if ($ParsedValue -isnot [array]) {
        throw "$ParameterName must be a JSON array."
    }

    $Values = @($ParsedValue | ForEach-Object { [string]$_ })
    if ($Values.Count -eq 0 -or @($Values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "$ParameterName must contain at least one non-empty string."
    }

    return $Values
}

function Get-ManagedIdentityAccessToken {
    <#
    .SYNOPSIS
        Gets an access token from the Azure-hosted managed identity endpoint.
    .PARAMETER Resource
        Token audience requested from the managed identity endpoint.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Resource
    )

    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) {
        throw 'The Azure managed identity endpoint is unavailable. Run this script in Azure Automation with a system-assigned identity.'
    }

    $TokenUri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [Uri]::EscapeDataString($Resource)
    $TokenResponse = Invoke-RestMethod -Method Get -Uri $TokenUri -Headers @{
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
        Metadata            = 'True'
    }

    if ([string]::IsNullOrWhiteSpace([string]$TokenResponse.access_token)) {
        throw "Managed identity did not return an access token for $Resource."
    }

    return [string]$TokenResponse.access_token
}

function Get-HttpStatusCode {
    <#
    .SYNOPSIS
        Extracts an HTTP status code from a PowerShell web exception.
    .PARAMETER ErrorRecord
        Error record raised by Invoke-RestMethod.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($null -eq $ErrorRecord.Exception.Response -or $null -eq $ErrorRecord.Exception.Response.StatusCode) {
        return 0
    }

    return [int]$ErrorRecord.Exception.Response.StatusCode
}

function Test-TransientHttpStatusCode {
    <#
    .SYNOPSIS
        Determines whether an HTTP status code represents a transient failure.
    .PARAMETER StatusCode
        HTTP status code to evaluate.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$StatusCode
    )

    return $StatusCode -in @(408, 429, 500, 502, 503, 504)
}

function Invoke-AzureRestRequest {
    <#
    .SYNOPSIS
        Invokes an authenticated Azure REST request with bounded retries.
    .PARAMETER Method
        HTTP method for the request.
    .PARAMETER Uri
        Absolute request URI.
    .PARAMETER AccessToken
        OAuth bearer token for the target service.
    .PARAMETER Body
        Optional JSON request body.
    .PARAMETER MaxRetryCount
        Maximum retries after the initial request.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^https://')]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AccessToken,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 10)]
        [int]$MaxRetryCount
    )

    for ($Attempt = 0; $Attempt -le $MaxRetryCount; $Attempt++) {
        try {
            $RequestParameters = @{
                Method  = $Method
                Uri     = $Uri
                Headers = @{ Authorization = "Bearer $AccessToken" }
            }

            if ($PSBoundParameters.ContainsKey('Body')) {
                $RequestParameters.Body = $Body
                $RequestParameters.ContentType = 'application/json'
            }

            return Invoke-RestMethod @RequestParameters
        }
        catch {
            $StatusCode = Get-HttpStatusCode -ErrorRecord $_
            if ($Attempt -ge $MaxRetryCount -or -not (Test-TransientHttpStatusCode -StatusCode $StatusCode)) {
                $FailureMessage = if ([string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)) {
                    $_.Exception.Message
                }
                else {
                    $_.ErrorDetails.Message
                }

                if ($StatusCode -gt 0) {
                    throw "$Method request to $Uri failed with HTTP $StatusCode. $FailureMessage"
                }

                throw "$Method request to $Uri failed. $FailureMessage"
            }

            $DelaySeconds = [Math]::Min([Math]::Pow(2, $Attempt + 1), 30)
            Write-Warning "Request to $Uri failed with HTTP $StatusCode. Retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-SqlResourceProviderRegistrationState {
    <#
    .SYNOPSIS
        Gets the Microsoft.Sql registration state for a subscription.
    .PARAMETER SubscriptionId
        Subscription ID to inspect.
    .PARAMETER ArmAccessToken
        OAuth bearer token for Azure Resource Manager.
    .PARAMETER MaxRetryCount
        Maximum retries after the initial HTTP request.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ArmAccessToken,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 10)]
        [int]$MaxRetryCount
    )

    $ProviderUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Sql?api-version=2021-04-01"
    $Provider = Invoke-AzureRestRequest -Method Get -Uri $ProviderUri -AccessToken $ArmAccessToken -MaxRetryCount $MaxRetryCount
    return [string]$Provider.registrationState
}

function Get-AccessibleTenantSubscriptionId {
    <#
    .SYNOPSIS
        Gets enabled subscriptions accessible to the managed identity in a tenant.
    .PARAMETER TenantId
        Microsoft Entra tenant ID used to filter subscriptions.
    .PARAMETER ArmAccessToken
        OAuth bearer token for Azure Resource Manager.
    .PARAMETER MaxRetryCount
        Maximum retries after each initial HTTP request.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ArmAccessToken,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 10)]
        [int]$MaxRetryCount
    )

    $SubscriptionIds = [System.Collections.Generic.List[string]]::new()
    $RequestUri = 'https://management.azure.com/subscriptions?api-version=2022-12-01'

    while (-not [string]::IsNullOrWhiteSpace($RequestUri)) {
        $Response = Invoke-AzureRestRequest -Method Get -Uri $RequestUri -AccessToken $ArmAccessToken -MaxRetryCount $MaxRetryCount
        foreach ($Subscription in @($Response.value)) {
            if ([string]$Subscription.tenantId -eq $TenantId -and [string]$Subscription.state -eq 'Enabled') {
                $SubscriptionIds.Add([string]$Subscription.subscriptionId)
            }
        }

        $RequestUri = [string]$Response.nextLink
    }

    if ($SubscriptionIds.Count -eq 0) {
        throw "The Automation Account managed identity cannot access any enabled subscriptions in tenant $TenantId."
    }

    return $SubscriptionIds.ToArray()
}

function ConvertTo-SqlMiQuotaRecord {
    <#
    .SYNOPSIS
        Maps a Microsoft.Sql usage response item to the custom table schema.
    .PARAMETER Usage
        Usage response item returned by Microsoft.Sql.
    .PARAMETER SubscriptionId
        Source subscription ID.
    .PARAMETER Region
        Azure region queried for usage.
    .PARAMETER TimeGenerated
        UTC timestamp assigned to the record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Usage,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [datetime]$TimeGenerated
    )

    return [pscustomobject]@{
        TimeGenerated  = $TimeGenerated.ToUniversalTime().ToString('o')
        Name           = [string]$Usage.name
        DisplayName    = [string]$Usage.properties.displayName
        CurrentValue   = [double]$Usage.properties.currentValue
        Limit          = [double]$Usage.properties.limit
        Unit           = [string]$Usage.properties.unit
        Region         = $Region
        SubscriptionId = $SubscriptionId
    }
}

function Get-LogsIngestionUri {
    <#
    .SYNOPSIS
        Builds the Azure Monitor Logs Ingestion API URI.
    .PARAMETER LogsIngestionEndpoint
        Logs ingestion endpoint exposed by the direct DCR.
    .PARAMETER DcrImmutableId
        Immutable ID of the Data Collection Rule.
    .PARAMETER StreamName
        Input stream name accepted by the Data Collection Rule.
    .PARAMETER ApiVersion
        API version used by the Logs Ingestion API.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogsIngestionEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory = $true)]
        [string]$StreamName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = '2023-01-01'
    )

    $Endpoint = $LogsIngestionEndpoint.TrimEnd('/')
    $EncodedStreamName = [Uri]::EscapeDataString($StreamName)
    return "$Endpoint/dataCollectionRules/$DcrImmutableId/streams/${EncodedStreamName}?api-version=$ApiVersion"
}

function Invoke-SqlMiQuotaCollection {
    <#
    .SYNOPSIS
        Collects and ingests SQL MI quota records for all configured scopes.
    .PARAMETER TenantId
        Microsoft Entra tenant containing the subscriptions to query.
    .PARAMETER Regions
        Azure regions to query.
    .PARAMETER UsageNames
        Microsoft.Sql usage counter names to collect.
    .PARAMETER LogsIngestionEndpoint
        Logs ingestion endpoint exposed by the direct DCR.
    .PARAMETER DcrImmutableId
        Immutable ID of the Data Collection Rule.
    .PARAMETER StreamName
        Input stream name accepted by the DCR.
    .PARAMETER SqlUsageApiVersion
        API version used to query Microsoft.Sql regional usage.
    .PARAMETER LogsIngestionApiVersion
        API version used to send records through the Logs Ingestion API.
    .PARAMETER MaxRetryCount
        Maximum retries after each initial HTTP request.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string[]]$Regions,

        [Parameter(Mandatory = $true)]
        [string[]]$UsageNames,

        [Parameter(Mandatory = $true)]
        [string]$LogsIngestionEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory = $true)]
        [string]$StreamName,

        [Parameter(Mandatory = $false)]
        [string]$SqlUsageApiVersion = '2023-08-01',

        [Parameter(Mandatory = $false)]
        [string]$LogsIngestionApiVersion = '2023-01-01',

        [Parameter(Mandatory = $true)]
        [int]$MaxRetryCount
    )

    $ArmAccessToken = Get-ManagedIdentityAccessToken -Resource 'https://management.azure.com/'
    $SubscriptionIds = @(Get-AccessibleTenantSubscriptionId -TenantId $TenantId -ArmAccessToken $ArmAccessToken -MaxRetryCount $MaxRetryCount)
    $MonitorAccessToken = Get-ManagedIdentityAccessToken -Resource 'https://monitor.azure.com/'
    $IngestionUri = Get-LogsIngestionUri -LogsIngestionEndpoint $LogsIngestionEndpoint -DcrImmutableId $DcrImmutableId -StreamName $StreamName -ApiVersion $LogsIngestionApiVersion
    $RecordCount = 0
    $QueryCount = 0
    $SkippedSubscriptionCount = 0
    $FailureMessages = [System.Collections.Generic.List[string]]::new()

    foreach ($SubscriptionId in $SubscriptionIds) {
        $ParsedSubscriptionId = [guid]::Empty
        if (-not [guid]::TryParse($SubscriptionId, [ref]$ParsedSubscriptionId)) {
            $FailureMessage = "Azure Resource Manager returned an invalid subscription ID: $SubscriptionId"
            $FailureMessages.Add($FailureMessage)
            Write-Warning $FailureMessage
            continue
        }

        try {
            $RegistrationState = Get-SqlResourceProviderRegistrationState -SubscriptionId $SubscriptionId -ArmAccessToken $ArmAccessToken -MaxRetryCount $MaxRetryCount
        }
        catch {
            $FailureMessage = "Provider check failed for subscription ${SubscriptionId}: $($_.Exception.Message)"
            $FailureMessages.Add($FailureMessage)
            Write-Warning $FailureMessage
            continue
        }

        if ($RegistrationState -ne 'Registered') {
            $SkippedSubscriptionCount++
            Write-Warning "Skipping subscription $SubscriptionId because Microsoft.Sql is $RegistrationState."
            continue
        }

        foreach ($Region in $Regions) {
            $QueryCount++
            $EncodedRegion = [Uri]::EscapeDataString($Region)
            $UsageUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Sql/locations/$EncodedRegion/usages?api-version=$SqlUsageApiVersion"
            try {
                $UsageResponse = Invoke-AzureRestRequest -Method Get -Uri $UsageUri -AccessToken $ArmAccessToken -MaxRetryCount $MaxRetryCount
            }
            catch {
                $FailureMessage = "Usage query failed for subscription $SubscriptionId in ${Region}: $($_.Exception.Message)"
                $FailureMessages.Add($FailureMessage)
                Write-Warning $FailureMessage
                continue
            }

            $TimeGenerated = [datetime]::UtcNow
            $Records = @(
                $UsageResponse.value |
                    Where-Object { [string]$_.name -in $UsageNames } |
                    ForEach-Object {
                        ConvertTo-SqlMiQuotaRecord -Usage $_ -SubscriptionId $SubscriptionId -Region $Region -TimeGenerated $TimeGenerated
                    }
            )

            if ($Records.Count -eq 0) {
                Write-Warning "No configured SQL MI quota counters were returned for subscription $SubscriptionId in $Region."
                continue
            }

            $Body = ConvertTo-Json -InputObject $Records -Depth 5 -Compress
            try {
                $null = Invoke-AzureRestRequest -Method Post -Uri $IngestionUri -AccessToken $MonitorAccessToken -Body $Body -MaxRetryCount $MaxRetryCount
            }
            catch {
                $FailureMessage = "Log ingestion failed for subscription $SubscriptionId in ${Region}: $($_.Exception.Message)"
                $FailureMessages.Add($FailureMessage)
                Write-Warning $FailureMessage
                continue
            }

            $RecordCount += $Records.Count
            Write-Information "Ingested $($Records.Count) SQL MI quota records for subscription $SubscriptionId in $Region."
        }
    }

    if ($FailureMessages.Count -gt 0) {
        $FailureSummary = $FailureMessages -join [Environment]::NewLine
        throw "SQL MI quota collection completed with $($FailureMessages.Count) failure(s):$([Environment]::NewLine)$FailureSummary"
    }

    return [pscustomobject]@{
        QueryCount               = $QueryCount
        RecordCount              = $RecordCount
        SkippedSubscriptionCount = $SkippedSubscriptionCount
    }
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $Regions = ConvertFrom-JsonArrayParameter -Json $RegionsJson -ParameterName 'RegionsJson'
        $UsageNames = ConvertFrom-JsonArrayParameter -Json $UsageNamesJson -ParameterName 'UsageNamesJson'

        $Result = Invoke-SqlMiQuotaCollection -TenantId $TenantId -Regions $Regions -UsageNames $UsageNames -LogsIngestionEndpoint $LogsIngestionEndpoint -DcrImmutableId $DcrImmutableId -StreamName $StreamName -SqlUsageApiVersion $SqlUsageApiVersion -LogsIngestionApiVersion $LogsIngestionApiVersion -MaxRetryCount $MaxRetryCount
        Write-Output "Completed $($Result.QueryCount) queries, ingested $($Result.RecordCount) records, and skipped $($Result.SkippedSubscriptionCount) subscriptions without Microsoft.Sql registration."
    }
    catch {
        Write-Error -ErrorAction Continue "SQL MI quota collection failed: $($_.Exception.Message)"
        throw
    }
}

#endregion Main Execution