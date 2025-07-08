# S3SkuCopy.psm1
# PowerShell module for high-performance, observable S3 SKU folder copy

function Copy-SkuFolders {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateScript({
            if (-not (Test-Path $_ -PathType Leaf)) { throw "CSV file not found: $_" }
            $ext = [System.IO.Path]::GetExtension($_)
            if ($ext -notin @('.csv', '.txt')) { throw "File must be CSV format: $_" }
            $fileInfo = Get-Item $_
            if ($fileInfo.Length -gt 100MB) { throw "File too large (max 100MB): $_" }
            return $true
        })]
        [string]$Csv,
        [Parameter(Mandatory, Position=1)]
        [ValidateScript({
            if ($_ -notmatch '^s3://[a-z0-9][a-z0-9.-]*[a-z0-9]/?') { 
                throw "Invalid S3 bucket format: $_" 
            }
            if ($_.Length -gt 100) { throw "Bucket path too long: $_" }
            return $true
        })]
        [string]$Bucket,
        [Parameter(Mandatory, Position=2)]
        [ValidateScript({
            $resolvedPath = try { Resolve-Path $_ -ErrorAction Stop } catch { $_ }
            if ($resolvedPath -match '\.\./|\.\.\\'|\.\.' -or $resolvedPath -match '\*|\?|<|>|\||:') {
                throw "Invalid destination path: $_"
            }
            return $true
        })]
        [string]$Dest,
        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxConcurrency = [Math]::Min([System.Environment]::ProcessorCount, 10),
        [Parameter()]
        [ValidateScript({
            if ($_ -notmatch '^[a-zA-Z0-9 _#-]+$') { throw "Column name contains invalid characters: $_" }
            if ($_.Length -gt 50) { throw "Column name too long: $_" }
            return $true
        })]
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

    # Import CSV and extract SKUs with enhanced security validation
    try {
        # Validate CSV file path security
        $csvPath = Resolve-Path $Csv -ErrorAction Stop
        if ($csvPath.Path -notmatch '^[A-Z]:\\' -and $csvPath.Path -notmatch '^/') {
            throw "Invalid file path format: $Csv"
        }
        
        # Check file size (limit to 100MB for security)
        $fileInfo = Get-Item $csvPath
        if ($fileInfo.Length -gt 100MB) {
            throw "CSV file too large (max 100MB): $($fileInfo.Length / 1MB) MB"
        }
        
        # Validate column name to prevent injection
        if ($ColumnName -notmatch '^[a-zA-Z0-9 _#-]+$') {
            throw "Column name contains invalid characters: $ColumnName"
        }
        
        $csvContent = Import-Csv -Path $csvPath -ErrorAction Stop
        
        # Check if CSV is empty
        if (-not $csvContent -or $csvContent.Count -eq 0) {
            throw "CSV file is empty or contains no data rows"
        }
        
        # Limit number of rows for security
        if ($csvContent.Count -gt 50000) {
            throw "CSV file too large (max 50,000 rows): $($csvContent.Count) rows"
        }
        
        # Validate column exists
        if ($ColumnName -notin $csvContent[0].PSObject.Properties.Name) {
            $availableCols = $csvContent[0].PSObject.Properties.Name | Where-Object { $_.Length -lt 100 }
            throw "Column '$ColumnName' not found in CSV. Available columns: $($availableCols -join ', ')"
        }
        
        # Extract and sanitize SKUs with enhanced validation
        $skus = $csvContent | ForEach-Object { $_.$ColumnName } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { 
            $sku = $_.Trim()
            
            # Security validation
            if ($sku.Length -eq 0) { return $null }
            if ($sku.Length -gt 100) { 
                Write-Warning "SKU too long, skipping: $($sku.Substring(0, 20))..."
                return $null 
            }
            
            # Check for path traversal attempts
            if ($sku -match '\.\./|\.\.\\'|\.\.' -or $sku -match '/|\\') {
                Write-Warning "SKU contains invalid path characters, skipping: $sku"
                return $null
            }
            
            # Only allow alphanumeric, hyphens, underscores, and periods
            if ($sku -notmatch '^[a-zA-Z0-9._-]+$') {
                Write-Warning "SKU contains invalid characters, skipping: $sku"
                return $null
            }
            
            return $sku
        } | Where-Object { $_ -and $_.Length -gt 0 } | Sort-Object -Unique
        
        if ($skus.Count -eq 0) {
            throw "No valid SKUs found in column '$ColumnName' in CSV file: $Csv"
        }
        
        # Limit number of SKUs for security
        if ($skus.Count -gt 10000) {
            throw "Too many SKUs (max 10,000): $($skus.Count)"
        }
        
        if ($OutputLevel -ne 'Minimal') {
            Write-Host "[INFO] Found $($skus.Count) unique valid SKUs in column '$ColumnName'" -ForegroundColor Green
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
                
                # Validate source and destination paths for security
                if ($src -notmatch '^s3://[a-z0-9][a-z0-9.-]*[a-z0-9]/[a-zA-Z0-9._/-]*$') {
                    throw "Invalid S3 source path format: $src"
                }
                
                $resolvedDst = Resolve-Path $dst -ErrorAction SilentlyContinue
                if ($resolvedDst -and $resolvedDst.Path -match '\.\./|\.\.\\'|\.\.' ) {
                    throw "Invalid destination path: $dst"
                }
                
                # Execute AWS S3 copy command with proper escaping and validation
                $awsArgs = @(
                    's3', 'cp',
                    $src,
                    $dst,
                    '--recursive',
                    '--only-show-errors',
                    '--no-follow-symlinks'  # Security: don't follow symlinks
                )
                
                # Execute with timeout and proper error handling
                $process = Start-Process -FilePath 'aws' -ArgumentList $awsArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $env:TEMP\aws_out.txt -RedirectStandardError $env:TEMP\aws_err.txt
                
                if ($process.ExitCode -ne 0) {
                    $errorOutput = if (Test-Path $env:TEMP\aws_err.txt) { Get-Content $env:TEMP\aws_err.txt -Raw } else { "Unknown error" }
                    throw "AWS CLI failed (exit code $($process.ExitCode)): $errorOutput"
                }
                
                $result = if (Test-Path $env:TEMP\aws_out.txt) { Get-Content $env:TEMP\aws_out.txt -Raw } else { "" }
                
                # Cleanup temp files
                Remove-Item $env:TEMP\aws_out.txt -ErrorAction SilentlyContinue
                Remove-Item $env:TEMP\aws_err.txt -ErrorAction SilentlyContinue
                
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
