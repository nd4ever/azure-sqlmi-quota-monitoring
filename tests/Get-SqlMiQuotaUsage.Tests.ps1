#Requires -Modules Pester

BeforeAll {
    $RunbookPath = Join-Path $PSScriptRoot '../runbooks/Get-SqlMiQuotaUsage.ps1'
    . $RunbookPath `
        -SubscriptionIdsJson '["00000000-0000-0000-0000-000000000000"]' `
        -RegionsJson '["eastus2"]' `
        -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' `
        -DcrImmutableId 'dcr-00000000000000000000000000000000' `
        -StreamName 'Custom-SqlMiQuota'

    $DeploymentScriptPath = Join-Path $PSScriptRoot '../scripts/Deploy-Solution.ps1'
    . $DeploymentScriptPath `
        -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' `
        -Location 'eastus2' `
        -ResourceGroupName 'rg-test' `
        -LogAnalyticsWorkspaceName 'law-test' `
        -TableName 'SqlMiQuota_CL' `
        -DataCollectionRuleName 'dcr-test' `
        -AutomationAccountName 'aa-test' `
        -SourceSubscriptionIds @('00000000-0000-0000-0000-000000000000') `
        -Regions @('eastus2')
}

Describe 'ConvertFrom-JsonArrayParameter' -Tag 'Unit' {
    Context 'when JSON contains a valid array' {
        It 'returns every string value' {
            $Result = @(ConvertFrom-JsonArrayParameter -Json '["eastus2","centralus"]' -ParameterName 'RegionsJson')

            $Result | Should -HaveCount 2
            $Result | Should -Contain 'eastus2'
            $Result | Should -Contain 'centralus'
        }
    }

    Context 'when JSON is not a usable array' {
        It 'rejects a scalar value' {
            { ConvertFrom-JsonArrayParameter -Json '"eastus2"' -ParameterName 'RegionsJson' } |
                Should -Throw '*must be a JSON array*'
        }

        It 'rejects an empty array' {
            { ConvertFrom-JsonArrayParameter -Json '[]' -ParameterName 'RegionsJson' } |
                Should -Throw '*at least one non-empty string*'
        }
    }
}

Describe 'ConvertTo-SqlMiQuotaRecord' -Tag 'Unit' {
    It 'maps the Microsoft.Sql usage response to the DCR schema' {
        $Usage = [pscustomobject]@{
            name       = 'SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota'
            properties = [pscustomobject]@{
                currentValue = 24
                displayName  = 'VCore quota for Standard Series SQL Managed Instance'
                limit        = 100
                unit         = 'Count'
            }
        }
        $Timestamp = [datetime]'2026-08-31T12:00:00Z'

        $Result = ConvertTo-SqlMiQuotaRecord -Usage $Usage -SubscriptionId '00000000-0000-0000-0000-000000000000' -Region 'eastus2' -TimeGenerated $Timestamp

        $Result.TimeGenerated | Should -Be '2026-08-31T12:00:00.0000000Z'
        $Result.Name | Should -Be $Usage.name
        $Result.DisplayName | Should -Be $Usage.properties.displayName
        $Result.CurrentValue | Should -Be 24
        $Result.Limit | Should -Be 100
        $Result.Unit | Should -Be 'Count'
        $Result.Region | Should -Be 'eastus2'
        $Result.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
    }
}

Describe 'Get-LogsIngestionUri' -Tag 'Unit' {
    It 'builds a direct DCR ingestion URI without a DCE' {
        $Result = Get-LogsIngestionUri `
            -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com/' `
            -DcrImmutableId 'dcr-abc123' `
            -StreamName 'Custom-SqlMiQuota'

        $Result | Should -Be 'https://example.ingest.monitor.azure.com/dataCollectionRules/dcr-abc123/streams/Custom-SqlMiQuota?api-version=2023-01-01'
    }
}

Describe 'Test-TransientHttpStatusCode' -Tag 'Unit' {
    It 'returns <Expected> for HTTP <StatusCode>' -ForEach @(
        @{ StatusCode = 408; Expected = $true }
        @{ StatusCode = 429; Expected = $true }
        @{ StatusCode = 503; Expected = $true }
        @{ StatusCode = 400; Expected = $false }
        @{ StatusCode = 403; Expected = $false }
    ) {
        Test-TransientHttpStatusCode -StatusCode $StatusCode | Should -Be $Expected
    }
}

Describe 'ConvertTo-JsonArrayParameter' -Tag 'Unit' {
    It 'serializes one value as a flat JSON array' {
        ConvertTo-JsonArrayParameter -Value @('eastus2') | Should -Be '["eastus2"]'
    }

    It 'serializes multiple values as a flat JSON array' {
        ConvertTo-JsonArrayParameter -Value @('eastus2', 'centralus') |
            Should -Be '["eastus2","centralus"]'
    }
}

Describe 'Invoke-SqlMiQuotaCollection' -Tag 'Unit' {
    BeforeEach {
        $script:PostedBody = $null
        Mock Get-ManagedIdentityAccessToken {
            return 'test-token'
        }
        Mock Invoke-AzureRestRequest {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            name       = 'SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota'
                            properties = [pscustomobject]@{
                                currentValue = 12
                                displayName  = 'VCore quota for Standard Series SQL Managed Instance'
                                limit        = 80
                                unit         = 'Count'
                            }
                        },
                        [pscustomobject]@{
                            name       = 'ServerQuota'
                            properties = [pscustomobject]@{
                                currentValue = 1
                                displayName  = 'Regional Server Quota'
                                limit        = 250
                                unit         = 'Count'
                            }
                        }
                    )
                }
            }

            $script:PostedBody = $Body
            return $null
        }
    }

    It 'ingests only configured quota counters as a JSON array' {
        $Result = Invoke-SqlMiQuotaCollection `
            -SubscriptionIds @('00000000-0000-0000-0000-000000000000') `
            -Regions @('eastus2') `
            -UsageNames @('SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota') `
            -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-abc123' `
            -StreamName 'Custom-SqlMiQuota' `
            -MaxRetryCount 0 `
            -InformationAction SilentlyContinue

        $Result.QueryCount | Should -Be 1
        $Result.RecordCount | Should -Be 1
        $PostedRecords = ConvertFrom-Json -InputObject $script:PostedBody -NoEnumerate
        $PostedRecords.GetType().FullName | Should -Be 'System.Object[]'
        $PostedRecords | Should -HaveCount 1
        ($PostedRecords[0] -is [array]) | Should -BeFalse
        $PostedRecords[0].Name | Should -Be 'SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota'
        Should -Invoke Get-ManagedIdentityAccessToken -Times 2 -Exactly
        Should -Invoke Invoke-AzureRestRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' }
    }
}