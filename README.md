# dio_smart_logger 📡

A production-focused logging interceptor for [Dio](https://pub.dev/packages/dio) with structured output, sensitive data masking, cURL generation, and detailed error diagnostics.

[![pub package](https://img.shields.io/pub/v/dio_smart_logger.svg)](https://pub.dev/packages/dio_smart_logger)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## ✨ Features

- **Structured Output:** Clean, easy-to-read request, response, and error logs.
- **Configurable Levels:** Fine-grained control with `none`, `error`, `info`, `debug`, and `verbose` levels.
- **Security First:** Built-in sensitive data masking for headers, query params, and request/response bodies.
- **cURL Generation:** Ready-to-use cURL commands for easy request reproduction.
- **Performance Metrics:** Track request duration, payload size, and transfer rate.
- **Advanced Error Diagnostics:** Detailed root-cause analysis mapped by `DioExceptionType`.
- **Flexibility:** Optional request filtering and custom printer callbacks.

## 📦 Installation

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  dio_smart_logger: ^0.2.0 # Or the latest version
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

## 🛠️ Advanced Configuration

You can tailor the logger to your specific needs. Here's a comprehensive setup:

```dart
const loggerConfig = DioLoggerConfig(
  enabled: true,
  level: DioLogLevel.verbose, // Log everything
  showCurl: true,
  showPerformanceMetrics: true,
  logErrorStackTrace: true,
  maxBodyBytes: 64 * 1024, // Truncate bodies larger than 64KB
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

## 🔒 Security Notes

- **Auto-Masking:** By default, common sensitive keys (like passwords, tokens, API keys) are masked with `***MASKED***`.
- **Custom Secrets:** You can extend the list of masked keys for your project:
  ```dart
  DioLoggerConfig(
    sensitiveKeys: ['my_custom_secret', 'social_security_number'],
  )
  ```
- **Header Blacklist:** Completely suppress specific headers from being logged using the `headerBlacklist` parameter.

## 💡 Example

Check out the [`example/main.dart`](example/main.dart) file for a runnable setup with a mock adapter.

Run the example from the terminal:

```bash
dart run example/main.dart
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
