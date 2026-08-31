#Requires -Modules Pester

BeforeAll {
    $RunbookPath = Join-Path $PSScriptRoot '../runbooks/Get-SqlMiQuotaUsage.ps1'
    . $RunbookPath `
        -TenantId '00000000-0000-0000-0000-000000000000' `
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
        -TenantId '00000000-0000-0000-0000-000000000000' `
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

Describe 'Get-AccessibleTenantSubscriptionId' -Tag 'Unit' {
    It 'returns enabled subscriptions from the requested tenant' {
        Mock Invoke-AzureRestRequest {
            return [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        subscriptionId = '00000000-0000-0000-0000-000000000000'
                        tenantId       = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        state          = 'Enabled'
                    },
                    [pscustomobject]@{
                        subscriptionId = '11111111-1111-1111-1111-111111111111'
                        tenantId       = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        state          = 'Enabled'
                    },
                    [pscustomobject]@{
                        subscriptionId = '22222222-2222-2222-2222-222222222222'
                        tenantId       = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                        state          = 'Enabled'
                    },
                    [pscustomobject]@{
                        subscriptionId = '33333333-3333-3333-3333-333333333333'
                        tenantId       = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        state          = 'Disabled'
                    }
                )
            }
        }

        $Result = @(Get-AccessibleTenantSubscriptionId `
                -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
                -ArmAccessToken 'test-token' `
                -MaxRetryCount 0)

        $Result | Should -HaveCount 2
        $Result | Should -Contain '00000000-0000-0000-0000-000000000000'
        $Result | Should -Contain '11111111-1111-1111-1111-111111111111'
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

Describe 'Get-EnabledTenantSubscriptionId' -Tag 'Unit' {
    It 'returns only enabled subscriptions in the requested tenant' {
        Mock Invoke-AzCli {
            return @'
[
  { "id": "00000000-0000-0000-0000-000000000000", "tenantId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "state": "Enabled" },
  { "id": "11111111-1111-1111-1111-111111111111", "tenantId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "state": "Disabled" },
  { "id": "22222222-2222-2222-2222-222222222222", "tenantId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "state": "Enabled" }
]
'@
        }

        $Result = @(Get-EnabledTenantSubscriptionId -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')

        $Result | Should -HaveCount 1
        $Result[0] | Should -Be '00000000-0000-0000-0000-000000000000'
    }
}

Describe 'Get-ConfiguredRunbookContent' -Tag 'Unit' {
    It 'renders deployed values as runbook parameter defaults' {
        $Result = Get-ConfiguredRunbookContent `
            -TemplatePath $RunbookPath `
            -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -RegionsJson '["eastus2","centralus"]' `
            -LogsIngestionEndpoint 'https://configured.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-abc123' `
            -StreamName 'Custom-SqlMiQuota' `
            -UsageNamesJson '["ConfiguredQuota"]'

        $Result | Should -Match ([regex]::Escape("[string]`$TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'"))
        $Result | Should -Match ([regex]::Escape('[string]$RegionsJson = ''["eastus2","centralus"]'''))
        $Result | Should -Match ([regex]::Escape("[string]`$LogsIngestionEndpoint = 'https://configured.ingest.monitor.azure.com'"))
        $Result | Should -Not -Match '__[A-Z0-9_]+__'
        { [scriptblock]::Create($Result) } | Should -Not -Throw
    }
}

Describe 'Resolve-LogAnalyticsWorkspaceConfiguration' -Tag 'Unit' {
    It 'appends the same five-character suffix when redeploying a workspace' {
        $FirstResult = Resolve-LogAnalyticsWorkspaceConfiguration `
            -Mode 'New' `
            -WorkspaceName 'law-sqlmi-quota' `
            -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' `
            -SolutionResourceGroupName 'rg-test'
        $SecondResult = Resolve-LogAnalyticsWorkspaceConfiguration `
            -Mode 'New' `
            -WorkspaceName 'law-sqlmi-quota' `
            -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' `
            -SolutionResourceGroupName 'rg-test'

        $FirstResult.Name | Should -Match '^law-sqlmi-quota-[0-9a-f]{5}$'
        $SecondResult.Name | Should -Be $FirstResult.Name
        $FirstResult.ResourceGroupName | Should -Be 'rg-test'
        $FirstResult.ShouldCreate | Should -BeTrue
    }

    It 'discovers an existing workspace resource group by name' {
        Mock Invoke-AzCli {
            return '[{"name":"law-existing","resourceGroup":"rg-monitoring"}]'
        }

        $Result = Resolve-LogAnalyticsWorkspaceConfiguration `
            -Mode 'Existing' `
            -WorkspaceName 'law-existing' `
            -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' `
            -SolutionResourceGroupName 'rg-test'

        $Result.Name | Should -Be 'law-existing'
        $Result.ResourceGroupName | Should -Be 'rg-monitoring'
        $Result.ShouldCreate | Should -BeFalse
        Should -Invoke Invoke-AzCli -Times 1 -Exactly
    }

    It 'prompts for the mode and workspace name when they are omitted' {
        Mock Read-Host { return 'N' } -ParameterFilter { $Prompt -like 'Use an*' }
        Mock Read-Host { return 'law-prompted' } -ParameterFilter { $Prompt -like 'Enter the base*' }

        $Result = Resolve-LogAnalyticsWorkspaceConfiguration `
            -DeploymentSubscriptionId '00000000-0000-0000-0000-000000000000' `
            -SolutionResourceGroupName 'rg-test'

        $Result.Name | Should -Match '^law-prompted-[0-9a-f]{5}$'
        Should -Invoke Read-Host -Times 2 -Exactly
    }
}

Describe 'Invoke-SqlMiQuotaCollection' -Tag 'Unit' {
    BeforeEach {
        $script:PostedBodies = @()
        Mock Get-ManagedIdentityAccessToken {
            return 'test-token'
        }
        Mock Get-AccessibleTenantSubscriptionId {
            return @(
                '00000000-0000-0000-0000-000000000000',
                '11111111-1111-1111-1111-111111111111'
            )
        }
        Mock Invoke-AzureRestRequest {
            if ($Method -eq 'Get') {
                if ($Uri -match '/providers/Microsoft\.Sql\?') {
                    return [pscustomobject]@{
                        registrationState = 'Registered'
                    }
                }

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

            $script:PostedBodies += $Body
            return $null
        }
    }

    It 'discovers tenant subscriptions and ingests configured counters for each one' {
        $Result = Invoke-SqlMiQuotaCollection `
            -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -Regions @('eastus2') `
            -UsageNames @('SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota') `
            -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-abc123' `
            -StreamName 'Custom-SqlMiQuota' `
            -MaxRetryCount 0 `
            -InformationAction SilentlyContinue

        $Result.QueryCount | Should -Be 2
        $Result.RecordCount | Should -Be 2
        $Result.SkippedSubscriptionCount | Should -Be 0
        $script:PostedBodies | Should -HaveCount 2
        $PostedRecords = ConvertFrom-Json -InputObject $script:PostedBodies[0] -NoEnumerate
        $PostedRecords.GetType().FullName | Should -Be 'System.Object[]'
        $PostedRecords | Should -HaveCount 1
        ($PostedRecords[0] -is [array]) | Should -BeFalse
        $PostedRecords[0].Name | Should -Be 'SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota'
        Should -Invoke Get-AccessibleTenantSubscriptionId -Times 1 -Exactly
        Should -Invoke Get-ManagedIdentityAccessToken -Times 2 -Exactly
        Should -Invoke Invoke-AzureRestRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'Post' }
    }

    It 'skips subscriptions where Microsoft.Sql is not registered' {
        Mock Invoke-AzureRestRequest {
            if ($Method -eq 'Get' -and $Uri -match '/providers/Microsoft\.Sql\?') {
                $RegistrationState = if ($Uri -match '00000000-0000-0000-0000-000000000000') {
                    'NotRegistered'
                }
                else {
                    'Registered'
                }

                return [pscustomobject]@{
                    registrationState = $RegistrationState
                }
            }

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
                        }
                    )
                }
            }

            $script:PostedBodies += $Body
            return $null
        }

        $Result = Invoke-SqlMiQuotaCollection `
            -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -Regions @('eastus2') `
            -UsageNames @('SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota') `
            -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-abc123' `
            -StreamName 'Custom-SqlMiQuota' `
            -MaxRetryCount 0 `
            -WarningAction SilentlyContinue `
            -InformationAction SilentlyContinue

        $Result.QueryCount | Should -Be 1
        $Result.RecordCount | Should -Be 1
        $Result.SkippedSubscriptionCount | Should -Be 1
        $script:PostedBodies | Should -HaveCount 1
        Should -Invoke Invoke-AzureRestRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -match '/locations/'
        }
    }

    It 'continues after provider and usage failures before throwing an aggregate error' {
        Mock Get-AccessibleTenantSubscriptionId {
            return @(
                '00000000-0000-0000-0000-000000000000',
                '11111111-1111-1111-1111-111111111111',
                '22222222-2222-2222-2222-222222222222'
            )
        }
        Mock Invoke-AzureRestRequest {
            if ($Method -eq 'Get' -and $Uri -match '/providers/Microsoft\.Sql\?') {
                if ($Uri -match '00000000-0000-0000-0000-000000000000') {
                    throw 'Provider lookup failed.'
                }

                return [pscustomobject]@{
                    registrationState = 'Registered'
                }
            }

            if ($Method -eq 'Get') {
                if ($Uri -match '11111111-1111-1111-1111-111111111111') {
                    throw 'Usage lookup failed.'
                }

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
                        }
                    )
                }
            }

            $script:PostedBodies += $Body
            return $null
        }

        {
            Invoke-SqlMiQuotaCollection `
                -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
                -Regions @('eastus2') `
                -UsageNames @('SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota') `
                -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc123' `
                -StreamName 'Custom-SqlMiQuota' `
                -MaxRetryCount 0 `
                -WarningAction SilentlyContinue `
                -InformationAction SilentlyContinue
        } | Should -Throw '*completed with 2 failure(s)*'

        $script:PostedBodies | Should -HaveCount 1
        Should -Invoke Invoke-AzureRestRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post'
        }
    }

    It 'continues after an ingestion failure before throwing an aggregate error' {
        $script:PostAttemptCount = 0
        Mock Invoke-AzureRestRequest {
            if ($Method -eq 'Get') {
                if ($Uri -match '/providers/Microsoft\.Sql\?') {
                    return [pscustomobject]@{
                        registrationState = 'Registered'
                    }
                }

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
                        }
                    )
                }
            }

            $script:PostAttemptCount++
            if ($script:PostAttemptCount -eq 1) {
                throw 'Ingestion failed.'
            }

            $script:PostedBodies += $Body
            return $null
        }

        {
            Invoke-SqlMiQuotaCollection `
                -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
                -Regions @('eastus2') `
                -UsageNames @('SubscriptionSQLManagedInstanceStandardSeriesVCoreQuota') `
                -LogsIngestionEndpoint 'https://example.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc123' `
                -StreamName 'Custom-SqlMiQuota' `
                -MaxRetryCount 0 `
                -WarningAction SilentlyContinue `
                -InformationAction SilentlyContinue
        } | Should -Throw '*completed with 1 failure(s)*'

        $script:PostedBodies | Should -HaveCount 1
        Should -Invoke Invoke-AzureRestRequest -Times 2 -Exactly -ParameterFilter {
            $Method -eq 'Post'
        }
    }
}