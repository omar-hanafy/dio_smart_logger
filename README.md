# dio_smart_logger

A production-focused logging interceptor for [Dio](https://pub.dev/packages/dio)
with structured output, sensitive data masking, cURL generation, and detailed
error diagnostics.

[![pub package](https://img.shields.io/pub/v/dio_smart_logger.svg)](https://pub.dev/packages/dio_smart_logger)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Features

- Structured request, response, and error logs
- Configurable log levels: `none`, `error`, `info`, `debug`, `verbose`
- Sensitive data masking for headers, query params, and bodies
- cURL generation for request reproduction
- Performance metrics: duration, payload size, transfer rate
- Error root-cause details by `DioExceptionType`
- Optional request filtering and custom printer callback

## Installation

Add the dependency:

```yaml
dependencies:
  dio_smart_logger: ^0.1.0-dev.1
```

Then run:

```bash
dart pub get
```

## Quick Start

```dart
import 'package:dio/dio.dart';
import 'package:dio_smart_logger/dio_smart_logger.dart';

final dio = Dio();

dio.interceptors.add(
  DioLoggerInterceptor(
    config: const DioLoggerConfig(
      enabled: true,
      level: DioLogLevel.debug,
      showCurl: true,
      maskSensitiveData: true,
    ),
  ),
);
```

## Common Configuration

```dart
const loggerConfig = DioLoggerConfig(
  enabled: true,
  level: DioLogLevel.verbose,
  showCurl: true,
  showPerformanceMetrics: true,
  logErrorStackTrace: true,
  maxBodyBytes: 64 * 1024,
  requestFilter: _logOnlyApiHost,
);

bool _logOnlyApiHost(RequestOptions options) {
  return options.uri.host == 'api.example.com';
}
```

## Custom Printer

Use `printer` to route logs anywhere:

```dart
final logs = <String>[];

final interceptor = DioLoggerInterceptor(
  config: DioLoggerConfig(
    printer: logs.add,
    useColors: false,
  ),
);
```

## Security Notes

- By default, sensitive keys are masked.
- You can extend `sensitiveKeys` for project-specific secrets.
- You can suppress specific headers with `headerBlacklist`.

## Public API

- `DioLoggerInterceptor`
- `DioLoggerConfig`
- `DioLogLevel`

## Example

See `example/main.dart` for a runnable setup with a mock adapter.

Run it with:

```bash
dart run example/main.dart
```

## Release Flow

This repository is designed for:

1. First release published manually from local machine.
2. Later releases published automatically from tag pushes using
   GitHub OIDC Trusted Publisher.

The automated workflow expects tags in the format:

```text
dio_smart_logger-v<version>
```

## License

MIT - see [LICENSE](LICENSE).

