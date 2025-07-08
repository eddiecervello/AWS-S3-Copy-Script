# S3SkuCopy.psm1
# PowerShell module for high-performance, observable S3 SKU folder copy

function Copy-SkuFolders {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$Csv,
        [Parameter(Mandatory, Position=1)]
        [ValidateScript({$_ -match '^s3://'})]
        [string]$Bucket,
        [Parameter(Mandatory, Position=2)]
        [string]$Dest,
        [Parameter()]
        [ValidateRange(1, 32)]
        [int]$MaxConcurrency = [System.Environment]::ProcessorCount,
        [Parameter()]
        [string]$ColumnName = 'Supplier Item #',
        [Parameter()]
        [switch]$DryRun,
        [Parameter()]
        [switch]$SkipExisting,
        [Parameter()]
        [ValidateSet('Minimal', 'Normal', 'Verbose')]
        [string]$OutputLevel = 'Normal'
    )
    
    # Create destination directory if it doesn't exist
    if (!(Test-Path $Dest)) { 
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null 
        if ($OutputLevel -eq 'Verbose') {
            Write-Host "[INFO] Created destination directory: $Dest" -ForegroundColor Green
        }
    }

    # Import CSV and extract SKUs
    try {
        $csvContent = Import-Csv -Path $Csv
        
        # Validate column exists
        if ($ColumnName -notin $csvContent[0].PSObject.Properties.Name) {
            throw "Column '$ColumnName' not found in CSV. Available columns: $($csvContent[0].PSObject.Properties.Name -join ', ')"
        }
        
        # Extract and sanitize SKUs
        $skus = $csvContent | ForEach-Object { $_.$ColumnName } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { 
            $sanitized = $_.Trim()
            # Basic path traversal protection
            $sanitized = $sanitized -replace '\.\./|\.\.\\', ''
            # Remove potentially dangerous characters
            $sanitized = $sanitized -replace '[<>:"|?*]', '_'
            return $sanitized
        } | Where-Object { $_ -and $_.Length -gt 0 } | Sort-Object -Unique
        
        if ($skus.Count -eq 0) {
            throw "No valid SKUs found in column '$ColumnName' in CSV file: $Csv"
        }
        
        if ($OutputLevel -ne 'Minimal') {
            Write-Host "[INFO] Found $($skus.Count) unique SKUs in column '$ColumnName'" -ForegroundColor Green
        }
    } catch {
        throw "Error processing CSV file: $($_.Exception.Message)"
    }

    # Setup logging and tracking
    $logPath = Join-Path $Dest "s3sku-copy-$(Get-Date -Format yyyyMMddHHmmss).log.jsonl"
    $start = Get-Date
    $completed = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    
    # Handle dry run mode
    if ($DryRun) {
        Write-Host "[DRY RUN] Would copy $($skus.Count) SKUs from $Bucket to $Dest" -ForegroundColor Yellow
        Write-Host "[DRY RUN] Max concurrency: $MaxConcurrency" -ForegroundColor Yellow
        Write-Host "[DRY RUN] Column name: $ColumnName" -ForegroundColor Yellow
        Write-Host "[DRY RUN] Skip existing: $SkipExisting" -ForegroundColor Yellow
        
        foreach ($sku in $skus) {
            Write-Host "[DRY RUN] Would copy: $Bucket$sku/ -> $(Join-Path $Dest $sku)" -ForegroundColor Yellow
        }
        return
    }
    
    if ($OutputLevel -ne 'Minimal') {
        Write-Host "[INFO] Starting copy of $($skus.Count) SKUs with $MaxConcurrency parallel jobs..." -ForegroundColor Green
        Write-Host "[INFO] Log file: $logPath" -ForegroundColor Green
    }

    # Process SKUs in parallel
    $skus | ForEach-Object -Parallel {
        param($sku, $Bucket, $Dest, $logPath, $SkipExisting, $OutputLevel, $completed)
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $src = "$Bucket$sku/"
        $dst = Join-Path $Dest $sku
        $status = 'success'
        $errMsg = $null
        $filesTransferred = 0
        $bytesTransferred = 0
        $skipped = $false
        
        try {
            # Check if destination exists and skip if requested
            if ($SkipExisting -and (Test-Path $dst) -and (Get-ChildItem $dst -Recurse -File).Count -gt 0) {
                $status = 'skipped'
                $skipped = $true
                if ($OutputLevel -eq 'Verbose') {
                    Write-Host "[SKIP] $sku: Directory already exists and contains files" -ForegroundColor Yellow
                }
            } else {
                # Create destination directory
                if (!(Test-Path $dst)) { 
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null 
                }
                
                # Execute AWS S3 copy command with proper escaping
                $awsArgs = @(
                    's3', 'cp',
                    $src,
                    $dst,
                    '--recursive',
                    '--only-show-errors'
                )
                $result = & aws @awsArgs 2>&1
                
                # Count transferred files (approximate)
                if (Test-Path $dst) {
                    $files = Get-ChildItem $dst -Recurse -File
                    $filesTransferred = $files.Count
                    $bytesTransferred = ($files | Measure-Object -Property Length -Sum).Sum
                }
                
                if ($OutputLevel -eq 'Verbose') {
                    Write-Host "[SUCCESS] $sku: $filesTransferred files ($([math]::Round($bytesTransferred/1MB, 2)) MB)" -ForegroundColor Green
                }
            }
        } catch {
            $status = 'error'
            $errMsg = $_.Exception.Message
            Write-Host "[ERROR] $sku: $errMsg" -ForegroundColor Red
        }
        
        $sw.Stop()
        
        # Create log entry
        $logEntry = [PSCustomObject]@{
            timestamp = (Get-Date).ToString('o')
            sku = $sku
            status = $status
            duration_ms = $sw.ElapsedMilliseconds
            files_transferred = $filesTransferred
            bytes_transferred = $bytesTransferred
            error = $errMsg
        }
        
        # Write to log file
        $logJson = $logEntry | ConvertTo-Json -Compress
        Add-Content -Path $logPath -Value $logJson
        
        # Add to completed collection for progress tracking
        $completed.Add($logEntry)
        
        # Progress reporting
        if ($OutputLevel -eq 'Normal' -and $completed.Count % 10 -eq 0) {
            Write-Host "[PROGRESS] Completed $($completed.Count) of $($using:skus.Count) SKUs" -ForegroundColor Cyan
        }
    } -ArgumentList $Bucket, $Dest, $logPath, $SkipExisting, $OutputLevel, $completed -ThrottleLimit $MaxConcurrency

    # Generate summary report
    $elapsed = (Get-Date) - $start
    $results = $completed.ToArray()
    $successCount = ($results | Where-Object { $_.status -eq 'success' }).Count
    $errorCount = ($results | Where-Object { $_.status -eq 'error' }).Count
    $skippedCount = ($results | Where-Object { $_.status -eq 'skipped' }).Count
    $totalFiles = ($results | Measure-Object -Property files_transferred -Sum).Sum
    $totalBytes = ($results | Measure-Object -Property bytes_transferred -Sum).Sum
    
    if ($OutputLevel -ne 'Minimal') {
        Write-Host "\n[SUMMARY] Copy operation completed in $([math]::Round($elapsed.TotalSeconds, 2)) seconds" -ForegroundColor Green
        Write-Host "[SUMMARY] Success: $successCount, Errors: $errorCount, Skipped: $skippedCount" -ForegroundColor Green
        Write-Host "[SUMMARY] Total files transferred: $totalFiles ($([math]::Round($totalBytes/1MB, 2)) MB)" -ForegroundColor Green
        Write-Host "[SUMMARY] Log file: $logPath" -ForegroundColor Green
    }
    
    # Return summary object
    return [PSCustomObject]@{
        TotalSkus = $skus.Count
        SuccessCount = $successCount
        ErrorCount = $errorCount
        SkippedCount = $skippedCount
        TotalFiles = $totalFiles
        TotalBytes = $totalBytes
        Duration = $elapsed
        LogPath = $logPath
    }
}

Export-ModuleMember -Function Copy-SkuFolders
