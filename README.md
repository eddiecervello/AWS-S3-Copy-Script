# AWS S3 SKU Copy - High Performance Edition

## Overview
This module copies specific SKU folders from an S3 bucket to a local directory, efficiently and observably, based on a CSV list. Now cross-platform (PowerShell 7+), concurrent, and production-grade.

## Features
- **CLI UX:** `Copy-SkuFolders.ps1 -Csv <file> -Bucket <s3://..> -Dest <path>`
- **Concurrency:** Auto-throttled parallel copy for large SKU lists
- **Strict Validation:** All params required, robust error handling
- **Observability:** JSON-lines logs (timestamp, sku, status, duration, error)
- **Idempotency:** Safe to resume, only new/changed files copied
- **Tested:** ≥95% Pester coverage, simulated failures
- **CI/CD:** GitHub Actions (Windows, Linux, macOS)

## Quickstart
```sh
# Import module and run
pwsh -c 'Import-Module ./S3SkuCopy; Copy-SkuFolders -Csv ./skus.csv -Bucket s3://my-bucket/path/ -Dest ./out'
```

Or use the wrapper script:
```sh
./Copy-SkuFolders.ps1 -Csv ./skus.csv -Bucket s3://my-bucket/path/ -Dest ./out
```

## Diagram
```plantuml
@startuml
actor User
User -> Copy-SkuFolders: Run with CSV, Bucket, Dest
Copy-SkuFolders -> AWS S3: Parallel aws s3 cp per SKU
Copy-SkuFolders -> Log: Write JSONL per SKU
@enduml
```

## Benchmarks
| SKUs | Serial (old) | Parallel (new) |
|------|--------------|---------------|
| 100  | 10 min       | 2 min         |
| 1000 | 2 hrs        | 12 min        |

## Logs & Observability
- Logs: `s3sku-copy-*.log.jsonl` in dest folder
- Each line: `{timestamp, sku, status, duration_ms, error}`

## Testing
- Run all tests: `Invoke-Pester ./S3SkuCopy/Copy-SkuFolders.Tests.ps1`

## CI/CD
- See `.github/workflows/ci.yml` for full pipeline

## Security
- No AWS secrets or absolute user paths logged
- Coverage <95% aborts deploy

## Changelog
See [CHANGELOG.md](./CHANGELOG.md)
