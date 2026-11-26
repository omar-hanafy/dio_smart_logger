# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - 2026-11-26

### Fixed

- Mask URI credentials and sensitive query values in request details, redirects,
  the `Location`, `Content-Location`, and `Referer` headers, error diagnostics,
  and cURL output.
- Apply masking to pre-encoded JSON, URL-encoded forms, and multipart fields in
  body logs and cURL output. Multipart fields honor `maskSensitiveData: false`.
- Honor the header blacklist and mask individual header values in response
  logs, error snapshots, and rate-limit diagnostics. The parser’s raw `source` field is omitted
  when masking is enabled or either error snapshot is disabled.
- Render integer lists sent as JSON as arrays. Keep the URL in generated cURL
  commands when the body is omitted, and quote URLs containing apostrophes.

## [0.3.0] - 2026-06-30

### Added
- `dio` 5.10 support: the new `DioExceptionType.transformTimeout` gets a dedicated
  forensic block, and `transform` is shown in the "Timeouts" summary.
- Configuration presets: `DioLoggerConfig.development()`, `.production()`, and
  `.errorsOnly()`.
- Per-request opt-out: set
  `Options(extra: {DioLoggerInterceptor.disableLoggingKey: true})` to skip all
  logging for a single request.
- HTTP protocol version logging on responses, when the adapter reports it
  (`Response.extra`, dio 5.9.2+ on the IO adapter).
- A "Rate Limit" section that surfaces `retry-after` and `x-ratelimit-*` /
  `ratelimit-*` headers on responses and errors.

### Changed
- Raised the minimum `dio` constraint to `^5.10.0`.
- cURL generation now mirrors Dio's request transformer: `x-www-form-urlencoded`
  bodies are URL-encoded (previously always JSON), GET bodies are included, the
  body honors an explicit `logRequestBody: false`, and oversized bodies are
  omitted instead of logged in full.
- Per-request state moved off `RequestOptions.extra` to an internal `Expando`, so
  the logger no longer writes entries into your `extra` map, and a retried request
  is timed fresh instead of reporting a stale duration.

### Fixed
- **Security:** sensitive-looking values (e.g. `Bearer` tokens and JWTs) are now
  masked in bodies and query parameters even under non-obvious keys.
- **Security:** large non-JSON string bodies are no longer previewed unsanitized.
- Binary (`Uint8List`/typed) data is no longer expanded into a number array in
  bodies or cURL.
- Values shared across sibling branches are no longer mislabeled as `<cycle>`.
- A throwing custom `printer` can no longer escape the interceptor and disrupt the
  request.
- Body truncation no longer splits a surrogate pair.

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
