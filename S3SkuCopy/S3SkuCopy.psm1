# S3SkuCopy.psm1
# PowerShell module for high-performance, observable S3 SKU folder copy

function Copy-SkuFolders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Csv,
        [Parameter(Mandatory, Position=1)]
        [string]$Bucket,
        [Parameter(Mandatory, Position=2)]
        [string]$Dest
    )
    
    # Validate input files/paths
    if (!(Test-Path $Csv)) { throw "CSV file not found: $Csv" }
    if ($Bucket -notmatch '^s3://') { throw "Bucket must start with s3://" }
    if (!(Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }

    $csvContent = Import-Csv -Path $Csv
    $skus = $csvContent | ForEach-Object { $_.'Supplier Item #' }

    $logPath = Join-Path $Dest "s3sku-copy-$(Get-Date -Format yyyyMMddHHmmss).log.jsonl"
    $jobs = @()
    $throttle = [System.Environment]::ProcessorCount

    $start = Get-Date
    Write-Host "[INFO] Starting copy of $($skus.Count) SKUs with $throttle parallel jobs..."

    $skus | ForEach-Object -Parallel {
        param($sku, $Bucket, $Dest, $logPath)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $src = "$Bucket$sku/"
        $dst = Join-Path $Dest $sku
        if (!(Test-Path $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }
        $cmd = "aws s3 cp `"$src`" `"$dst`" --recursive --only-show-errors"
        $result = $null
        $status = 'success'
        $errMsg = $null
        try {
            $result = Invoke-Expression $cmd
        } catch {
            $status = 'error'
            $errMsg = $_.Exception.Message
        }
        $sw.Stop()
        $log = [PSCustomObject]@{
            timestamp = (Get-Date).ToString('o')
            sku = $sku
            status = $status
            duration_ms = $sw.ElapsedMilliseconds
            error = $errMsg
        } | ConvertTo-Json -Compress
        Add-Content -Path $logPath -Value $log
        if ($status -eq 'error') { Write-Host "[ERROR] $sku: $errMsg" -ForegroundColor Red }
    } -ArgumentList $Bucket, $Dest, $logPath -ThrottleLimit $throttle

    $elapsed = (Get-Date) - $start
    Write-Host "[INFO] All copy jobs completed in $($elapsed.TotalSeconds) seconds. Log: $logPath"
}

Export-ModuleMember -Function Copy-SkuFolders
