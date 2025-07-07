# Module manifest for S3SkuCopy
Import-Module "$PSScriptRoot/S3SkuCopy/S3SkuCopy.psd1"

# Example usage:
# pwsh -c 'Import-Module ./S3SkuCopy; Copy-SkuFolders -Csv ./skus.csv -Bucket s3://my-bucket/path/ -Dest ./out'

param(
    [Parameter(Mandatory)]
    [string]$Csv,
    [Parameter(Mandatory)]
    [string]$Bucket,
    [Parameter(Mandatory)]
    [string]$Dest
)

Copy-SkuFolders -Csv $Csv -Bucket $Bucket -Dest $Dest
