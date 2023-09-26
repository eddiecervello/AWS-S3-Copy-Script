AWS S3 Copy Script
==================

This script allows users to copy specific folders from an S3 bucket to a local directory based on SKU values from a CSV file.

Prerequisites
-------------

1.  AWS CLI: Ensure you have the AWS CLI installed and configured with the necessary access rights.
2.  PowerShell: The script is written in PowerShell.

Setup
-----

1.  Clone this repository to your local machine.

```bash
    git clone <repository-url>
```

3.  Navigate to the directory.

```bash
    cd <repository-dir>
```

4.  Configure your AWS CLI if you haven't done so.

```
aws configure
```

How to Use
----------

1.  Update the `$BUCKET_PATH` variable in the script to point to your S3 bucket path.

2.  Update the `$DEST_DIR` variable to point to your desired local destination directory.

3.  Ensure your CSV file is formatted with a column named `Supplier Item #` that contains the SKUs.

4.  Run the script with:

    `.\script-name.ps1`

Script Content
--------------

```powershell$BUCKET_PATH = "s3://your-bucket-name/Path/"
$DEST_DIR = "C:\Your\Local\Path\"
$csvContent = Import-Csv -Path "path-to-your-csv-file.csv"

foreach ($row in $csvContent) {
    $sku = $row.'Supplier Item #'
    # First exclude all, then include the specific SKU, to ensure only updated/new files are downloaded
    aws s3 cp "$BUCKET_PATH$sku/" "$DEST_DIR$sku\" --recursive --exclude "*" --include "$sku/*"
}
```

Replace placeholders like `your-bucket-name`, `Your\Local\Path\`, and `path-to-your-csv-file.csv` with your actual values before using.

Issues
------

If you encounter any issues, please open an issue in this repository.
