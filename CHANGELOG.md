# Changelog

## [2.0.0] - 2025-07-07
### Added
- Refactored as cross-platform PowerShell 7 module `S3SkuCopy` with public cmdlet `Copy-SkuFolders`
- Parallel/concurrent S3 copy for large SKU lists (auto-throttle)
- Strict parameter validation, error handling, and JSON-lines logging
- Pester tests for coverage and reliability
- GitHub Actions CI/CD workflow (lint, test, benchmark, release)
- Updated README with usage, diagrams, and benchmarks
