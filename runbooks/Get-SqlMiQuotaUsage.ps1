#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Collects regional Azure SQL Managed Instance vCore quota usage.
.DESCRIPTION
    Uses the Azure Automation Account system-assigned managed identity to read
    Microsoft.Sql regional usage and send selected counters to an Azure Monitor
    direct Data Collection Rule endpoint.
.PARAMETER SubscriptionIdsJson
    JSON array of source subscription IDs.
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
.PARAMETER MaxRetryCount
    Maximum retries after the initial request for transient HTTP failures.
.EXAMPLE
    ./Get-SqlMiQuotaUsage.ps1 -SubscriptionIdsJson '["00000000-0000-0000-0000-000000000000"]' -RegionsJson '["eastus2"]' -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' -DcrImmutableId 'dcr-00000000000000000000000000000000' -StreamName 'Custom-SqlMiQuota'
.NOTES
    Designed for the Azure Automation PowerShell 7.2 runtime.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionIdsJson,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RegionsJson,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^/]+$')]
    [string]$LogsIngestionEndpoint,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^dcr-[a-fA-F0-9]+$')]
    [string]$DcrImmutableId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^Custom-[A-Za-z][A-Za-z0-9_-]*$')]
    [string]$StreamName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$UsageNamesJson = '["SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota","SubscriptionSQLManagedInstancePremiumSeriesVCoreQuota","SubscriptionSQLManagedInstancePremiumSeriesMemoryOptimizedVCoreQuota"]',

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
                throw
            }

            $DelaySeconds = [Math]::Min([Math]::Pow(2, $Attempt + 1), 30)
            Write-Warning "Request to $Uri failed with HTTP $StatusCode. Retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
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
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogsIngestionEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory = $true)]
        [string]$StreamName
    )

    $Endpoint = $LogsIngestionEndpoint.TrimEnd('/')
    $EncodedStreamName = [Uri]::EscapeDataString($StreamName)
    return "$Endpoint/dataCollectionRules/$DcrImmutableId/streams/${EncodedStreamName}?api-version=2023-01-01"
}

function Invoke-SqlMiQuotaCollection {
    <#
    .SYNOPSIS
        Collects and ingests SQL MI quota records for all configured scopes.
    .PARAMETER SubscriptionIds
        Source subscription IDs.
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
    .PARAMETER MaxRetryCount
        Maximum retries after each initial HTTP request.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SubscriptionIds,

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

        [Parameter(Mandatory = $true)]
        [int]$MaxRetryCount
    )

    $ArmAccessToken = Get-ManagedIdentityAccessToken -Resource 'https://management.azure.com/'
    $MonitorAccessToken = Get-ManagedIdentityAccessToken -Resource 'https://monitor.azure.com/'
    $IngestionUri = Get-LogsIngestionUri -LogsIngestionEndpoint $LogsIngestionEndpoint -DcrImmutableId $DcrImmutableId -StreamName $StreamName
    $RecordCount = 0
    $QueryCount = 0

    foreach ($SubscriptionId in $SubscriptionIds) {
        $ParsedSubscriptionId = [guid]::Empty
        if (-not [guid]::TryParse($SubscriptionId, [ref]$ParsedSubscriptionId)) {
            throw "SubscriptionIdsJson contains an invalid subscription ID: $SubscriptionId"
        }

        foreach ($Region in $Regions) {
            $QueryCount++
            $EncodedRegion = [Uri]::EscapeDataString($Region)
            $UsageUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Sql/locations/$EncodedRegion/usages?api-version=2023-08-01"
            $UsageResponse = Invoke-AzureRestRequest -Method Get -Uri $UsageUri -AccessToken $ArmAccessToken -MaxRetryCount $MaxRetryCount
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
            $null = Invoke-AzureRestRequest -Method Post -Uri $IngestionUri -AccessToken $MonitorAccessToken -Body $Body -MaxRetryCount $MaxRetryCount
            $RecordCount += $Records.Count
            Write-Information "Ingested $($Records.Count) SQL MI quota records for subscription $SubscriptionId in $Region."
        }
    }

    return [pscustomobject]@{
        QueryCount  = $QueryCount
        RecordCount = $RecordCount
    }
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $SubscriptionIds = ConvertFrom-JsonArrayParameter -Json $SubscriptionIdsJson -ParameterName 'SubscriptionIdsJson'
        $Regions = ConvertFrom-JsonArrayParameter -Json $RegionsJson -ParameterName 'RegionsJson'
        $UsageNames = ConvertFrom-JsonArrayParameter -Json $UsageNamesJson -ParameterName 'UsageNamesJson'

        $Result = Invoke-SqlMiQuotaCollection -SubscriptionIds $SubscriptionIds -Regions $Regions -UsageNames $UsageNames -LogsIngestionEndpoint $LogsIngestionEndpoint -DcrImmutableId $DcrImmutableId -StreamName $StreamName -MaxRetryCount $MaxRetryCount
        Write-Output "Completed $($Result.QueryCount) queries and ingested $($Result.RecordCount) records."
    }
    catch {
        Write-Error -ErrorAction Continue "SQL MI quota collection failed: $($_.Exception.Message)"
        throw
    }
}

#endregion Main Execution