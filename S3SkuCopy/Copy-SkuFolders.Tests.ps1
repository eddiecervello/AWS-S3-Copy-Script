# S3SkuCopy Pester Tests
BeforeAll {
    Import-Module "$PSScriptRoot/S3SkuCopy.psd1" -Force
    
    # Mock AWS CLI for testing
    function script:Invoke-Expression {
        param($Command)
        if ($Command -match 'aws s3 cp.*--only-show-errors') {
            # Simulate successful copy
            return
        }
        throw "Unexpected command: $Command"
    }
}

Describe 'Copy-SkuFolders' {
    BeforeEach {
        # Create temp directory for tests
        $script:TempDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive "test-$(Get-Random)")
        $script:TempCsv = Join-Path $script:TempDir 'test.csv'
        $script:TempDest = Join-Path $script:TempDir 'dest'
    }
    
    AfterEach {
        # Cleanup
        if (Test-Path $script:TempDir) {
            Remove-Item $script:TempDir -Recurse -Force
        }
    }
    
    Context 'Parameter Validation' {
        It 'Fails on missing CSV file' {
            { Copy-SkuFolders -Csv 'nonexistent.csv' -Bucket 's3://bucket/' -Dest $script:TempDest } | 
                Should -Throw -ExpectedMessage "CSV file not found: nonexistent.csv"
        }
        
        It 'Fails on invalid bucket format' {
            # Create valid CSV
            '"Supplier Item #"' | Out-File $script:TempCsv
            '"SKU001"' | Out-File $script:TempCsv -Append
            
            { Copy-SkuFolders -Csv $script:TempCsv -Bucket 'bucket/' -Dest $script:TempDest } | 
                Should -Throw -ExpectedMessage "Bucket must start with s3://"
        }
        
        It 'Creates destination directory if it does not exist' {
            # Create valid CSV
            '"Supplier Item #"' | Out-File $script:TempCsv
            '"SKU001"' | Out-File $script:TempCsv -Append
            
            $script:TempDest | Should -Not -Exist
            
            Mock Invoke-Expression { return } -Verifiable
            
            Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest
            
            $script:TempDest | Should -Exist
        }
    }
    
    Context 'CSV Processing' {
        It 'Reads SKUs from CSV with correct column name' {
            # Create CSV with SKUs
            @'
"Supplier Item #","Description"
"SKU001","Item 1"
"SKU002","Item 2"
"SKU003","Item 3"
'@ | Out-File $script:TempCsv
            
            Mock Invoke-Expression { return } -Verifiable
            
            Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest
            
            # Verify SKU directories were created
            (Get-ChildItem $script:TempDest -Directory).Count | Should -Be 3
            Join-Path $script:TempDest 'SKU001' | Should -Exist
            Join-Path $script:TempDest 'SKU002' | Should -Exist
            Join-Path $script:TempDest 'SKU003' | Should -Exist
        }
        
        It 'Handles empty CSV gracefully' {
            # Create empty CSV with only headers
            '"Supplier Item #","Description"' | Out-File $script:TempCsv
            
            Mock Invoke-Expression { return } -Verifiable
            
            { Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest } | 
                Should -Not -Throw
        }
    }
    
    Context 'Logging' {
        It 'Creates JSON log file with correct format' {
            # Create CSV with one SKU
            @'
"Supplier Item #"
"SKU001"
'@ | Out-File $script:TempCsv
            
            Mock Invoke-Expression { return } -Verifiable
            
            Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest
            
            # Check log file exists
            $logFiles = Get-ChildItem $script:TempDest -Filter '*.log.jsonl'
            $logFiles.Count | Should -Be 1
            
            # Verify log content
            $logContent = Get-Content $logFiles[0].FullName | ConvertFrom-Json
            $logContent.sku | Should -Be 'SKU001'
            $logContent.status | Should -Be 'success'
            $logContent.timestamp | Should -Not -BeNullOrEmpty
            $logContent.duration_ms | Should -BeGreaterThan 0
        }
        
        It 'Logs errors when AWS command fails' {
            # Create CSV with one SKU
            @'
"Supplier Item #"
"SKU001"
'@ | Out-File $script:TempCsv
            
            # Mock to simulate AWS error
            Mock Invoke-Expression { throw "AWS error: NoSuchBucket" } -Verifiable
            
            Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest
            
            # Check error was logged
            $logFiles = Get-ChildItem $script:TempDest -Filter '*.log.jsonl'
            $logContent = Get-Content $logFiles[0].FullName | ConvertFrom-Json
            $logContent.status | Should -Be 'error'
            $logContent.error | Should -Match 'AWS error'
        }
    }
    
    Context 'Performance' {
        It 'Respects processor count for throttling' {
            # Create CSV with multiple SKUs
            $csvContent = '"Supplier Item #"' + "`n"
            1..20 | ForEach-Object { $csvContent += '"SKU{0:D3}"' -f $_ + "`n" }
            $csvContent | Out-File $script:TempCsv
            
            Mock Invoke-Expression { Start-Sleep -Milliseconds 100 } -Verifiable
            
            $start = Get-Date
            Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest
            $duration = (Get-Date) - $start
            
            # With parallel processing, should be faster than serial
            # 20 SKUs * 100ms = 2 seconds serial, should be much less with parallel
            $duration.TotalSeconds | Should -BeLessThan 2
        }
    }
    
    Context 'Error Handling' {
        It 'Continues processing other SKUs when one fails' {
            # Create CSV with multiple SKUs
            @'
"Supplier Item #"
"SKU001"
"SKU_FAIL"
"SKU003"
'@ | Out-File $script:TempCsv
            
            # Mock to fail only for specific SKU
            Mock Invoke-Expression {
                param($Command)
                if ($Command -match 'SKU_FAIL') {
                    throw "Access Denied"
                }
                return
            } -Verifiable
            
            Copy-SkuFolders -Csv $script:TempCsv -Bucket 's3://test-bucket/' -Dest $script:TempDest
            
            # Verify other SKUs were processed
            Join-Path $script:TempDest 'SKU001' | Should -Exist
            Join-Path $script:TempDest 'SKU003' | Should -Exist
            
            # Check log has mixed results
            $logFiles = Get-ChildItem $script:TempDest -Filter '*.log.jsonl'
            $logs = Get-Content $logFiles[0].FullName | ForEach-Object { $_ | ConvertFrom-Json }
            ($logs | Where-Object { $_.status -eq 'success' }).Count | Should -Be 2
            ($logs | Where-Object { $_.status -eq 'error' }).Count | Should -Be 1
        }
    }
}

Describe 'Module Manifest' {
    It 'Has valid module manifest' {
        Test-ModuleManifest -Path "$PSScriptRoot/S3SkuCopy.psd1" | Should -Not -BeNullOrEmpty
    }
    
    It 'Exports Copy-SkuFolders function' {
        $module = Import-Module "$PSScriptRoot/S3SkuCopy.psd1" -PassThru -Force
        $module.ExportedFunctions.Keys | Should -Contain 'Copy-SkuFolders'
    }
}