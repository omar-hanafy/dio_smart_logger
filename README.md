# dio_smart_logger 📡

A production-focused logging interceptor for [Dio](https://pub.dev/packages/dio) with structured output, sensitive data masking, cURL generation, and detailed error diagnostics.

[![pub package](https://img.shields.io/pub/v/dio_smart_logger.svg)](https://pub.dev/packages/dio_smart_logger)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## ✨ Features

- **Structured Output:** Clean, easy-to-read request, response, and error logs.
- **Configurable Levels:** Fine-grained control with `none`, `error`, `info`, `debug`, and `verbose` levels.
- **Data masking** covers headers, query parameters, and fields in structured request and response bodies.
- **cURL output** shows the request with placeholders for masked values.
- **Performance Metrics:** Track request duration, payload size, and transfer rate.
- **Advanced Error Diagnostics:** Detailed root-cause analysis mapped by `DioExceptionType`.
- **Flexibility:** Optional request filtering and custom printer callbacks.
- **Ready-made Presets:** `DioLoggerConfig.development()`, `.production()`, and `.errorsOnly()`.
- **Per-request Opt-out:** Skip logging for a single request via a request `extra` flag.
- **Protocol & Rate-limit Insight:** Logs the negotiated HTTP version and surfaces rate-limit headers.

## 📦 Installation

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  dio_smart_logger: ^0.3.1
```

Then run:

```bash
dart pub get
```

*Or, using Flutter:*

```bash
flutter pub add dio_smart_logger
```

## 🚀 Quick Start

Attach the interceptor to your Dio instance:

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

### Presets

Choose one preset for your interceptor.

| Preset | Output |
| --- | --- |
| `DioLoggerConfig.development()` | Verbose request and response logs with cURL and colors. |
| `DioLoggerConfig.production()` | Errors only, with snapshots, cURL, stack traces, and colors disabled. |
| `DioLoggerConfig.errorsOnly()` | Failed requests with request and response snapshots, cURL, and a call-site stack trace when available. |

```dart
dio.interceptors.add(DioLoggerInterceptor(config: DioLoggerConfig.development()));
```

Register the logger after any interceptor that adds headers you want to see.
Dio calls both request and response interceptors in registration order.
`Duration` starts in the logger's request callback and ends in its response or
error callback, so it includes time spent in earlier response interceptors.

## 🛠️ Advanced Configuration

You can tailor the logger to your specific needs. Here's a comprehensive setup:

```dart
const loggerConfig = DioLoggerConfig(
  enabled: true,
  level: DioLogLevel.verbose, // Log everything
  showCurl: true,
  showPerformanceMetrics: true,
  logErrorStackTrace: true,
  maxBodyBytes: 64 * 1024, // Limit rendered body text in UTF-16 code units
  requestFilter: _logOnlyApiHost, // Filter which requests to log
);

bool _logOnlyApiHost(RequestOptions options) {
  // Only log requests going to 'api.example.com'
  return options.uri.host == 'api.example.com';
}

dio.interceptors.add(DioLoggerInterceptor(config: loggerConfig));
```

### Custom Printer

If you want to route logs to a specific destination (like Crashlytics, a file, or a custom logging system) instead of the console, use the `printer` callback:

```dart
final logs = <String>[];

final interceptor = DioLoggerInterceptor(
  config: DioLoggerConfig(
    printer: (String message) {
      logs.add(message);
      // Send to Crashlytics, Datadog, etc.
    },
    useColors: false, // Usually you don't want ANSI colors in external loggers
  ),
);
```

### Skipping a Single Request

To suppress logging for one specific request (e.g. a noisy health check or a sensitive endpoint), set the opt-out flag in its `extra`:

```dart
dio.get(
  '/health',
  options: Options(extra: {DioLoggerInterceptor.disableLoggingKey: true}),
);
```

## 🔒 Security Notes

- With masking enabled (the default), a key containing a sensitive fragment such as `password` or `token` has its value replaced by `***MASKED***`. Matching is case-insensitive.
- String values in structured data are also checked for patterns such as `Bearer …`, `Basic …`, and JWT-like strings. For endpoints with secrets embedded in free-form text or URL paths, use `requestFilter` or the per-request opt-out.
- Setting `sensitiveKeys` replaces the default list. To keep the defaults and add a project-specific key, spread them into the new list.

  ```dart
  final config = DioLoggerConfig(
    sensitiveKeys: [
      ...const DioLoggerConfig().sensitiveKeys,
      'membership_number',
    ],
  );
  ```

- Use `headerBlacklist` to omit named headers from header output. Header names match case-insensitively. The logger masks URI credentials and sensitive query parameters in `Location`, `Content-Location`, and `Referer`. Add other headers carrying private URLs to the blacklist.

## 💡 Example

The example makes a `GET /status` request through Dio. An in-memory adapter
returns a JSON response with status `200`. The terminal shows the
`Authorization` header as `***MASKED***` and shows `"status": "ok"` in the response body. [Example source](example/main.dart)

Run it from the package root.

```bash
dart run example/main.dart
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
