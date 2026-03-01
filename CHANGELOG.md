# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-03-01

### Added
- Inlined `consts.dart` and `extension.dart` to replace `dart_helper_utils` dependency.
- Visual width calculation for box-drawing alignment with emoji/wide characters.

### Fixed
- JWT-detection heuristic now requires base64url characters, reducing false positives
  on package names, bundle IDs, and version strings.
- Box-drawing alignment no longer breaks when titles contain emoji or wide characters.
- Error-path data-size estimation avoids expensive `jsonEncode`; uses fast estimation
  with graceful fallback.

### Changed
- Removed `dart_helper_utils` dependency; all needed utilities are now internal.
- Removed unused `httpStatusMessages` map and dead string extension members.
- Renamed internal context key to match package name.
- Redirect chain entries now use consistent `_kv` formatting helper.

## [0.1.1] - 2026-02-28
- Updated `dart_helper_utils` to `^6.0.0` to keep dependencies current.
- No API changes.

## [0.1.0] - 2026-02-28
- First stable release.
- Promoted features from `0.1.0-dev.1` without API changes.

## [0.1.0-dev.1] - 2026-02-28
- Initial pre-release.
- Added `DioLoggerInterceptor`, `DioLoggerConfig`, and `DioLogLevel`.
- Added structured request, response, and error logging with masking.
- Added cURL generation, performance metrics, and status code guidance.
- Added request filtering and configurable output controls.
- Added package tests, example app, and CI/publishing workflows.
