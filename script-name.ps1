$DEST_DIR = "C:\Your\Local\Path\"
$csvContent = Import-Csv -Path "path-to-your-csv-file.csv"

foreach ($row in $csvContent) {
    $sku = $row.'Supplier Item #'
    # First exclude all, then include the specific SKU, to ensure only updated/new files are downloaded
    aws s3 cp "$BUCKET_PATH$sku/" "$DEST_DIR$sku\" --recursive --exclude "*" --include "$sku/*"
}
