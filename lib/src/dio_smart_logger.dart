import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_helper_utils/dart_helper_utils.dart';
import 'package:dio/dio.dart';

/// Log severity levels - ordering matters for filtering
enum DioLogLevel {
  /// No logging at all
  none,

  /// Only errors
  error,

  /// Errors + basic request/response info
  info,

  /// Info + headers, query params, extras
  debug,

  /// Debug + full bodies, stack traces
  verbose,
}

/// Configuration for [DioLoggerInterceptor]
class DioLoggerConfig {
  /// Creates an immutable logging configuration.
  ///
  /// Use [level] for coarse-grained verbosity and the specific boolean toggles
  /// for fine-grained output control.
  const DioLoggerConfig({
    this.enabled = true,
    this.level = DioLogLevel.debug,
    // Output
    this.printer,
    this.useColors = true,
    this.useDartDeveloperLog =
        true, // Prevents truncation in Android Studio/VSCode
    this.maxLineWidth = 120,
    // Copy/paste ergonomics
    this.makeSectionsCopyable = true,
    // What to log (null = auto based on level)
    this.logRequest = true,
    this.logResponse = true,
    this.logError = true,
    this.logRequestHeaders,
    this.logRequestQueryParams,
    this.logRequestBody,
    this.logResponseHeaders,
    this.logResponseBody,
    // Error-specific
    this.logErrorRequestSnapshot = true,
    this.logErrorResponseSnapshot = true,
    this.logCallSiteStackTrace = true, // Dio 5.9.0 sourceStackTrace
    this.logErrorStackTrace = false,
    this.maxStackTraceLines = 8,
    // Features
    this.showCurl = true,
    this.showPerformanceMetrics = true,
    this.showStatusCodeMeaning = true,
    // Safety
    this.maskSensitiveData = true,
    this.sensitiveKeys = const [
      'password',
      'passwd',
      'token',
      'access_token',
      'refresh_token',
      'authorization',
      'bearer',
      'cookie',
      'set-cookie',
      'secret',
      'secret_key',
      'api_key',
      'apikey',
      'x-api-key',
      'private_key',
      'credit_card',
      'card_number',
      'cvv',
      'ssn',
    ],
    this.headerBlacklist = const [],
    // Truncation
    this.maxBodyBytes = 32 * 1024, // 32 KB
    this.maxBinaryPreviewBytes = 64,
    // Filtering
    this.requestFilter,
  }) : assert(maxLineWidth >= 20, 'maxLineWidth must be >= 20'),
       assert(maxStackTraceLines >= 1, 'maxStackTraceLines must be >= 1'),
       assert(maxBodyBytes >= 0, 'maxBodyBytes must be >= 0'),
       assert(maxBinaryPreviewBytes >= 0, 'maxBinaryPreviewBytes must be >= 0');

  /// Master switch for this interceptor.
  final bool enabled;

  /// Minimum log severity to emit.
  final DioLogLevel level;

  /// Custom printer function. If null, uses dart:developer log or print
  final void Function(String message)? printer;

  /// Adds ANSI colors for terminal output
  final bool useColors;

  /// Uses dart:developer log to prevent truncation (recommended for IDE consoles)
  final bool useDartDeveloperLog;

  /// Maximum line width before wrapping
  final int maxLineWidth;

  /// When true, multi-line sections (e.g. cURL, JSON bodies) are printed
  /// without the left box prefix (`│`) so they can be copy/pasted directly.
  final bool makeSectionsCopyable;

  // ─────────────────────────────────────────────────────────────────────────────
  // Logging toggles (null = auto based on level)
  // ─────────────────────────────────────────────────────────────────────────────

  /// Enables request logging.
  final bool logRequest;

  /// Enables response logging.
  final bool logResponse;

  /// Enables error logging.
  final bool logError;

  /// Overrides request header logging if not null.
  final bool? logRequestHeaders;

  /// Overrides request query-parameter logging if not null.
  final bool? logRequestQueryParams;

  /// Overrides request body logging if not null.
  final bool? logRequestBody;

  /// Overrides response header logging if not null.
  final bool? logResponseHeaders;

  /// Overrides response body logging if not null.
  final bool? logResponseBody;

  // ─────────────────────────────────────────────────────────────────────────────
  // Error-specific options
  // ─────────────────────────────────────────────────────────────────────────────

  /// Include full request details in error logs
  final bool logErrorRequestSnapshot;

  /// Include response body/headers in error logs (if response exists)
  final bool logErrorResponseSnapshot;

  /// Log where the request was initiated (Dio 5.9.0 sourceStackTrace)
  final bool logCallSiteStackTrace;

  /// Log DioException's stackTrace
  final bool logErrorStackTrace;

  /// Maximum number of stack trace lines to print when enabled.
  final int maxStackTraceLines;

  // ─────────────────────────────────────────────────────────────────────────────
  // Features
  // ─────────────────────────────────────────────────────────────────────────────

  /// Generate cURL command for easy debugging/reproduction
  final bool showCurl;

  /// Show request/response sizes and transfer rate
  final bool showPerformanceMetrics;

  /// Show human-readable explanation of HTTP status codes
  final bool showStatusCodeMeaning;

  // ─────────────────────────────────────────────────────────────────────────────
  // Security
  // ─────────────────────────────────────────────────────────────────────────────

  /// Mask sensitive data in headers, query params, and body
  final bool maskSensitiveData;

  /// Keys to mask (case-insensitive contains match)
  final List<String> sensitiveKeys;

  /// Headers to completely exclude from logs
  final List<String> headerBlacklist;

  // ─────────────────────────────────────────────────────────────────────────────
  // Truncation
  // ─────────────────────────────────────────────────────────────────────────────

  /// Max body size to log (prevents freezing on large responses)
  final int maxBodyBytes;

  /// For binary data, show first N bytes
  final int maxBinaryPreviewBytes;

  // ─────────────────────────────────────────────────────────────────────────────
  // Filtering
  // ─────────────────────────────────────────────────────────────────────────────

  /// Return false to skip logging for specific requests
  final bool Function(RequestOptions options)? requestFilter;

  // ─────────────────────────────────────────────────────────────────────────────
  // Computed properties
  // ─────────────────────────────────────────────────────────────────────────────

  bool get _canLogInfo => enabled && level.index >= DioLogLevel.info.index;

  bool get _canLogDebug => enabled && level.index >= DioLogLevel.debug.index;

  bool get _canLogVerbose =>
      enabled && level.index >= DioLogLevel.verbose.index;

  bool get _canLogErrors => enabled && level.index >= DioLogLevel.error.index;

  /// Returns true when this request should be logged in
  /// [DioLoggerInterceptor.onRequest].
  bool shouldLogRequest(RequestOptions o) =>
      _canLogInfo && logRequest && (requestFilter?.call(o) ?? true);

  /// Returns true when this response should be logged in
  /// [DioLoggerInterceptor.onResponse].
  bool shouldLogResponse(RequestOptions o) =>
      _canLogInfo && logResponse && (requestFilter?.call(o) ?? true);

  /// Returns true when this failure should be logged in
  /// [DioLoggerInterceptor.onError].
  bool shouldLogError(RequestOptions o) =>
      _canLogErrors && logError && (requestFilter?.call(o) ?? true);

  /// Effective setting for request header logging.
  bool get effectiveLogRequestHeaders => logRequestHeaders ?? _canLogDebug;

  /// Effective setting for request query-parameter logging.
  bool get effectiveLogRequestQueryParams =>
      logRequestQueryParams ?? _canLogDebug;

  /// Effective setting for request body logging.
  bool get effectiveLogRequestBody => logRequestBody ?? _canLogVerbose;

  /// Effective setting for response header logging.
  bool get effectiveLogResponseHeaders => logResponseHeaders ?? _canLogDebug;

  /// Effective setting for response body logging.
  bool get effectiveLogResponseBody => logResponseBody ?? _canLogVerbose;
}

// MAIN INTERCEPTOR

/// A highly configurable [Dio] interceptor for request, response, and error logs.
///
/// It prints structured logs with request metadata, response snapshots, and
/// actionable error diagnostics while masking sensitive values.
class DioLoggerInterceptor extends Interceptor {
  /// Creates a logger interceptor with the provided [config].
  ///
  /// If [config] is not supplied, [DioLoggerConfig] defaults are used.
  DioLoggerInterceptor({DioLoggerConfig? config})
    : config = config ?? const DioLoggerConfig(),
      _sensitiveKeyFragmentsLower = (config ?? const DioLoggerConfig())
          .sensitiveKeys
          .map((e) => e.toLowerCase())
          .toList(growable: false),
      _headerBlacklistLower = (config ?? const DioLoggerConfig())
          .headerBlacklist
          .map((e) => e.toLowerCase())
          .toSet();

  /// Runtime configuration that controls output and filtering behavior.
  final DioLoggerConfig config;
  final List<String> _sensitiveKeyFragmentsLower;
  final Set<String> _headerBlacklistLower;

  // Internal keys for storing context in request extras
  static const String _ctxKey = '__ultimate_dio_logger_ctx__';

  // REQUEST

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_shouldCaptureContext(options) && _getCtx(options) == null) {
      options.extra[_ctxKey] = _LogContext.start();
    }

    if (!config.shouldLogRequest(options)) {
      handler.next(options);
      return;
    }

    final ctx = _getCtx(options) ?? _LogContext.start();
    options.extra[_ctxKey] = ctx;

    try {
      final lines = StringBuffer();
      final sanitizedUri = _sanitizeUri(options.uri);

      // ───────────────────────────────────────────────────────────────────────
      // Header
      // ───────────────────────────────────────────────────────────────────────
      _boxTop(
        lines,
        '📤 REQUEST [${ctx.id}] ${options.method}',
        _AnsiColors.cyan,
      );
      _kv(lines, 'URI', sanitizedUri.toString());
      _kv(lines, 'BaseURL', options.baseUrl);
      _kv(lines, 'Path', options.path);

      // ───────────────────────────────────────────────────────────────────────
      // Request Configuration
      // ───────────────────────────────────────────────────────────────────────
      if (config._canLogDebug) {
        _section(lines, 'Configuration');
        _kv(lines, 'ContentType', options.contentType);
        _kv(lines, 'ResponseType', options.responseType.name);
        _kv(lines, 'FollowRedirects', options.followRedirects);
        _kv(lines, 'MaxRedirects', options.maxRedirects);
        _kv(lines, 'PersistentConnection', options.persistentConnection);
        _kv(
          lines,
          'Timeouts',
          'connect=${options.connectTimeout ?? "∞"} | '
              'send=${options.sendTimeout ?? "∞"} | '
              'receive=${options.receiveTimeout ?? "∞"}',
        );
      }

      // ───────────────────────────────────────────────────────────────────────
      // Query Parameters
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogRequestQueryParams &&
          options.queryParameters.isNotEmptyOrNull) {
        _section(lines, 'Query Parameters');
        final sanitizedQuery =
            _sanitizeMap(options.queryParameters) as Map<dynamic, dynamic>;
        _printMap(lines, sanitizedQuery);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Headers
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogRequestHeaders &&
          options.headers.isNotEmptyOrNull) {
        _section(lines, 'Headers');
        final sanitizedHeaders = _sanitizeHeaders(options.headers);
        _printMap(lines, sanitizedHeaders);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Extras
      // ───────────────────────────────────────────────────────────────────────
      final extras = Map<String, dynamic>.from(options.extra)..remove(_ctxKey);
      if (config._canLogDebug && extras.isNotEmptyOrNull) {
        _section(lines, 'Extras');
        _printMap(lines, _sanitizeMap(extras) as Map<dynamic, dynamic>);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Body
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogRequestBody && options.data != null) {
        _section(lines, 'Body');
        _printBody(lines, options.data, isRequest: true);
      }

      // ───────────────────────────────────────────────────────────────────────
      // cURL
      // ───────────────────────────────────────────────────────────────────────
      if (config.showCurl) {
        _section(lines, 'cURL');
        _printMultiline(
          lines,
          _generateCurl(options),
          indent: config.makeSectionsCopyable ? 0 : 2,
          copyable: config.makeSectionsCopyable,
        );
      }

      _boxBottom(lines, _AnsiColors.cyan);
      _emit(lines.toString());
    } catch (e, st) {
      _emit(_internalLoggerError('onRequest', e, st), isError: true);
    } finally {
      handler.next(options);
    }
  }

  // RESPONSE

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final req = response.requestOptions;
    final ctx = _getCtx(req);
    ctx?.stopwatch.stop();
    req.extra.remove(_ctxKey);

    if (!config.shouldLogResponse(req)) {
      handler.next(response);
      return;
    }

    try {
      final duration = ctx?.stopwatch.elapsedMilliseconds ?? 0;
      final lines = StringBuffer();

      // Determine color based on status
      final statusCode = response.statusCode ?? 0;
      final color = statusCode >= 200 && statusCode < 300
          ? _AnsiColors.green
          : statusCode >= 300 && statusCode < 400
          ? _AnsiColors.yellow
          : _AnsiColors.red;

      // ───────────────────────────────────────────────────────────────────────
      // Header
      // ───────────────────────────────────────────────────────────────────────
      _boxTop(
        lines,
        '📥 RESPONSE [${ctx?.id ?? "-"}] ${req.method} → '
        '${response.statusCode} ${response.statusMessage ?? ""}',
        color,
      );
      _kv(lines, 'URI', _sanitizeUri(response.realUri).toString());
      _kv(lines, 'Duration', '$duration ms');

      // ───────────────────────────────────────────────────────────────────────
      // Status Code Meaning (using dart_helper_utils httpStatusMessages)
      // ───────────────────────────────────────────────────────────────────────
      if (config.showStatusCodeMeaning && response.statusCode != null) {
        final standardMsg = httpStatusMessages[response.statusCode];
        if (standardMsg != null) {
          _kv(lines, 'Status', '$statusCode $standardMsg');
        }
      }

      // ───────────────────────────────────────────────────────────────────────
      // Redirect Chain
      // ───────────────────────────────────────────────────────────────────────
      if (response.redirects.isNotEmptyOrNull) {
        _section(lines, 'Redirect Chain (${response.redirects.length})');
        for (var i = 0; i < response.redirects.length; i++) {
          final r = response.redirects[i];
          lines.writeln(
            '│ ${i + 1}. [${r.statusCode}] ${r.method} → ${_sanitizeUri(r.location)}',
          );
        }
        _kv(lines, 'Final URI', _sanitizeUri(response.realUri).toString());
      }

      // ───────────────────────────────────────────────────────────────────────
      // Response Headers
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogResponseHeaders &&
          response.headers.map.isNotEmptyOrNull) {
        _section(lines, 'Headers');
        final headers = <String, String>{};
        response.headers.forEach((k, v) => headers[k] = v.join(', '));
        _printMap(lines, _sanitizeMap(headers) as Map<dynamic, dynamic>);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Performance Metrics
      // ───────────────────────────────────────────────────────────────────────
      if (config.showPerformanceMetrics) {
        _section(lines, 'Performance');
        final responseSize =
            _getContentLength(response.headers) ??
            _estimateSizeFast(
              response.data,
              allowJsonEstimate: config._canLogVerbose,
            );
        final requestSize = _estimateSizeFast(
          req.data,
          allowJsonEstimate: config._canLogVerbose,
        );

        _kv(
          lines,
          'Request Size',
          requestSize == null ? 'unknown' : _formatBytes(requestSize),
        );
        _kv(
          lines,
          'Response Size',
          responseSize == null ? 'unknown' : _formatBytes(responseSize),
        );
        if (duration > 0 && responseSize != null) {
          final rate = (responseSize / 1024) / (duration / 1000);
          _kv(lines, 'Transfer Rate', '${rate.toStringAsFixed(2)} KB/s');
        }
      }

      // ───────────────────────────────────────────────────────────────────────
      // Response Body
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogResponseBody) {
        if (req.responseType == ResponseType.stream) {
          _section(lines, 'Body');
          lines.writeln('│ <Stream> (not logged to avoid consumption)');
        } else if (response.data != null) {
          _section(lines, 'Body');
          _printBody(lines, response.data, isRequest: false);
        }
      }

      _boxBottom(lines, color);
      _emit(lines.toString());
    } catch (e, st) {
      _emit(_internalLoggerError('onResponse', e, st), isError: true);
    } finally {
      handler.next(response);
    }
  }

  // ERROR

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final req = err.requestOptions;
    final ctx = _getCtx(req);
    ctx?.stopwatch.stop();
    req.extra.remove(_ctxKey);

    if (!config.shouldLogError(req)) {
      handler.next(err);
      return;
    }

    try {
      final duration = ctx?.stopwatch.elapsedMilliseconds ?? 0;
      final lines = StringBuffer();

      final statusCode = err.response?.statusCode;
      final statusMsg = err.response?.statusMessage ?? '';
      final statusPart = statusCode != null ? ' → $statusCode $statusMsg' : '';

      // ─────────────────────────────────────────────────────────────────────────
      // Header
      // ─────────────────────────────────────────────────────────────────────────
      _boxTop(
        lines,
        '❌ ERROR [${ctx?.id ?? "-"}] ${req.method}$statusPart',
        _AnsiColors.red,
      );
      _kv(lines, 'URI', _sanitizeUri(req.uri).toString());
      _kv(lines, 'Duration', '$duration ms');
      _kv(lines, 'Type', err.type.name);

      // ─────────────────────────────────────────────────────────────────────────
      // Error Message
      // ─────────────────────────────────────────────────────────────────────────
      if (err.message.isNotBlank) {
        _kv(lines, 'Message', err.message);
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Status Code Meaning (for badResponse)
      // ─────────────────────────────────────────────────────────────────────────
      if (config.showStatusCodeMeaning && statusCode != null) {
        final devMessage = _getStatusCodeMeaning(statusCode);
        final userMessage = _getStatusCodeUserMessage(statusCode);
        if (devMessage != null) {
          _kv(lines, 'Technical', devMessage);
        }
        if (userMessage != null) {
          _kv(lines, 'User Hint', userMessage);
        }
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Root Cause Analysis (Forensic Error Details)
      // ─────────────────────────────────────────────────────────────────────────
      _section(lines, 'Root Cause Analysis');
      _printErrorDetails(lines, err);

      // ─────────────────────────────────────────────────────────────────────────
      // Request Snapshot
      // ─────────────────────────────────────────────────────────────────────────
      if (config.logErrorRequestSnapshot) {
        _section(lines, 'Request Snapshot');
        _kv(lines, 'Method', req.method);
        _kv(lines, 'ContentType', req.contentType);
        _kv(
          lines,
          'Timeouts',
          'connect=${req.connectTimeout ?? "∞"} | '
              'send=${req.sendTimeout ?? "∞"} | '
              'receive=${req.receiveTimeout ?? "∞"}',
        );

        if (req.queryParameters.isNotEmptyOrNull) {
          lines.writeln('│ Query Parameters:');
          _printMap(
            lines,
            _sanitizeMap(req.queryParameters) as Map<dynamic, dynamic>,
            indent: 4,
          );
        }

        if (req.headers.isNotEmptyOrNull) {
          lines.writeln('│ Headers:');
          _printMap(lines, _sanitizeHeaders(req.headers), indent: 4);
        }

        if (req.data != null) {
          lines.writeln('│ Body:');
          _printBody(lines, req.data, isRequest: true, indent: 4);
        }
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Response Snapshot (if available)
      // ─────────────────────────────────────────────────────────────────────────
      if (config.logErrorResponseSnapshot && err.response != null) {
        final res = err.response!;
        _section(lines, 'Response Snapshot');
        _kv(lines, 'Status', '${res.statusCode} ${res.statusMessage ?? ""}');
        _kv(lines, 'Real URI', _sanitizeUri(res.realUri).toString());

        if (res.redirects.isNotEmptyOrNull) {
          lines.writeln('│ Redirects:');
          for (final r in res.redirects) {
            lines.writeln(
              '│   ${r.statusCode} ${r.method} → ${_sanitizeUri(r.location)}',
            );
          }
        }

        if (res.headers.map.isNotEmptyOrNull) {
          lines.writeln('│ Headers:');
          final headers = <String, String>{};
          res.headers.forEach((k, v) => headers[k] = v.join(', '));
          _printMap(
            lines,
            _sanitizeMap(headers) as Map<dynamic, dynamic>,
            indent: 4,
          );
        }

        if (res.data != null) {
          lines.writeln('│ Body:');
          _printBody(lines, res.data, isRequest: false, indent: 4);
        }
      }

      // ─────────────────────────────────────────────────────────────────────────
      // cURL (very useful for reproducing errors)
      // ─────────────────────────────────────────────────────────────────────────
      if (config.showCurl) {
        _section(lines, 'Retry cURL');
        _printMultiline(
          lines,
          _generateCurl(req),
          indent: config.makeSectionsCopyable ? 0 : 2,
          copyable: config.makeSectionsCopyable,
        );
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Call-site Stack Trace (where the request was made)
      // Uses Dio 5.9.0's sourceStackTrace - extremely valuable for debugging
      // ─────────────────────────────────────────────────────────────────────────
      // ignore: invalid_use_of_internal_member
      final sourceTrace = req.sourceStackTrace;
      if (config.logCallSiteStackTrace && sourceTrace != null) {
        _section(lines, 'Call Site (where request was initiated)');
        _printStackTrace(lines, sourceTrace);
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Exception Stack Trace
      // ─────────────────────────────────────────────────────────────────────────
      if (config.logErrorStackTrace) {
        _section(lines, 'Exception Stack Trace');
        _printStackTrace(lines, err.stackTrace);
      }

      _boxBottom(lines, _AnsiColors.red);
      _emit(lines.toString(), isError: true);
    } catch (e, st) {
      _emit(_internalLoggerError('onError', e, st), isError: true);
    } finally {
      handler.next(err);
    }
  }

  // FORENSIC ERROR ANALYSIS

  void _printErrorDetails(StringBuffer lines, DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
        lines.writeln('│ ⏱️ CONNECTION TIMEOUT');
        lines.writeln('│   The connection to the server timed out.');
        lines.writeln(
          '│   Configured timeout: ${err.requestOptions.connectTimeout}',
        );
        lines.writeln(
          '│   Target: ${err.requestOptions.uri.host}:${err.requestOptions.uri.port}',
        );
        _printUnderlyingError(lines, err.error);

      case DioExceptionType.sendTimeout:
        lines.writeln('│ ⏱️ SEND TIMEOUT');
        lines.writeln('│   Request data took too long to send.');
        lines.writeln(
          '│   Configured timeout: ${err.requestOptions.sendTimeout}',
        );
        if (err.requestOptions.data != null) {
          lines.writeln(
            '│   Data size: ${_formatBytes(_estimateSize(err.requestOptions.data))}',
          );
        }
        _printUnderlyingError(lines, err.error);

      case DioExceptionType.receiveTimeout:
        lines.writeln('│ ⏱️ RECEIVE TIMEOUT');
        lines.writeln('│   Server response took too long.');
        lines.writeln(
          '│   Configured timeout: ${err.requestOptions.receiveTimeout}',
        );
        _printUnderlyingError(lines, err.error);

      case DioExceptionType.badCertificate:
        lines.writeln('│ 🔒 BAD CERTIFICATE');
        lines.writeln('│   SSL/TLS certificate validation failed.');
        lines.writeln('│   Host: ${err.requestOptions.uri.host}');
        if (err.error != null) {
          lines.writeln('│   Certificate: ${err.error}');
        }

      case DioExceptionType.badResponse:
        lines.writeln('│ 🚫 BAD RESPONSE');
        lines.writeln('│   Server returned status ${err.response?.statusCode}');

      case DioExceptionType.cancel:
        lines.writeln('│ ❌ REQUEST CANCELLED');
        lines.writeln('│   The request was manually cancelled.');
        if (err.error != null) {
          lines.writeln('│   Reason: ${err.error}');
        }

      case DioExceptionType.connectionError:
        lines.writeln('│ 🔌 CONNECTION ERROR');
        lines.writeln('│   Failed to establish connection.');
        _printUnderlyingError(lines, err.error);

      case DioExceptionType.unknown:
        lines.writeln('│ ❓ UNKNOWN ERROR');
        lines.writeln('│   An unexpected error occurred.');
        _printUnderlyingError(lines, err.error);
    }
  }

  void _printUnderlyingError(StringBuffer lines, Object? error) {
    if (error == null) return;
    final typeName = error.runtimeType.toString();
    final dynamic e = error;

    lines.writeln('│   ┌─ $typeName');

    String? message;
    try {
      message = e.message?.toString();
    } catch (_) {}

    if (message != null && message.trim().isNotEmpty) {
      lines.writeln('│   │ Message: $message');
    } else {
      lines.writeln('│   │ $error');
    }

    try {
      final osError = e.osError;
      if (osError != null) {
        lines.writeln(
          '│   │ OS Error: ${osError.message} (code: ${osError.errorCode})',
        );
      }
    } catch (_) {}

    try {
      final address = e.address;
      if (address != null) {
        lines.writeln('│   │ Address: ${address.host}');
      }
    } catch (_) {}

    try {
      final port = e.port;
      if (port != null) {
        lines.writeln('│   │ Port: $port');
      }
    } catch (_) {}

    try {
      final uri = e.uri;
      if (uri != null) {
        lines.writeln('│   │ URI: $uri');
      }
    } catch (_) {}

    try {
      final source = e.source;
      if (source != null) {
        final s = source.toString();
        lines.writeln(
          '│   │ Source: ${s.length > 100 ? '${s.substring(0, 100)}...' : s}',
        );
      }
    } catch (_) {}

    lines.writeln('│   └─');
  }

  // STATUS CODE MEANINGS (using dart_helper_utils)

  String? _getStatusCodeMeaning(int statusCode) {
    // Uses httpStatusDevMessage from dart_helper_utils for developer-focused messages
    return httpStatusDevMessage[statusCode];
  }

  String? _getStatusCodeUserMessage(int statusCode) {
    // Uses httpStatusUserMessage from dart_helper_utils for user-friendly messages
    return httpStatusUserMessage[statusCode];
  }

  // CURL GENERATOR

  String _generateCurl(RequestOptions options) {
    final components = <String>['curl -X ${options.method}'];

    // Headers
    _sanitizeHeaders(options.headers).forEach((key, value) {
      if (key.toLowerCase() != 'content-length') {
        final escapedValue = _escapeShellArg(value.toString());
        components.add("-H '$key: $escapedValue'");
      }
    });

    // Body
    if (options.data != null && options.method.toUpperCase() != 'GET') {
      if (options.data is FormData) {
        final formData = options.data as FormData;
        for (final field in formData.fields) {
          final key = _escapeShellArg(field.key);
          final value = _isSensitiveKey(field.key)
              ? '***MASKED***'
              : _escapeShellArg(field.value);
          components.add("-F '$key=$value'");
        }
        for (final file in formData.files) {
          final key = _escapeShellArg(file.key);
          final filename = file.value.filename ?? 'file';
          components.add("-F '$key=@$filename'");
        }
      } else if (options.data is Map || options.data is List) {
        final sanitized = _sanitizeMap(options.data);
        final json = _escapeShellArg(_safeJsonEncode(sanitized));
        components.add("--data-raw '$json'");
      } else if (options.data is String) {
        final sanitized = _escapeShellArg(options.data as String);
        components.add("--data-raw '$sanitized'");
      } else if (options.data is Uint8List || options.data is List<int>) {
        components.add('# <binary data omitted>');
      } else if (options.data is Stream) {
        components.add('# <stream data omitted>');
      }
    }

    // URL (sanitized)
    final uri = _sanitizeUri(options.uri);
    components.add("'$uri'");

    return components.join(' \\\n  ');
  }

  // FORMATTING HELPERS

  void _boxTop(StringBuffer sb, String title, String color) {
    final c = config.useColors ? color : '';
    final r = config.useColors ? _AnsiColors.reset : '';
    sb
      ..writeln('')
      ..writeln('$c┌${'─' * (config.maxLineWidth - 2)}┐$r')
      ..writeln(
        '$c│ $title${' ' * math.max(0, config.maxLineWidth - title.length - 4)}│$r',
      )
      ..writeln('$c├${'─' * (config.maxLineWidth - 2)}┤$r');
  }

  void _boxBottom(StringBuffer sb, String color) {
    final c = config.useColors ? color : '';
    final r = config.useColors ? _AnsiColors.reset : '';
    sb.writeln('$c└${'─' * (config.maxLineWidth - 2)}┘$r');
  }

  void _section(StringBuffer sb, String title) {
    sb
      ..writeln('│')
      ..writeln(
        '├─── $title ${'─' * math.max(0, config.maxLineWidth - title.length - 8)}',
      );
  }

  void _kv(StringBuffer sb, String key, Object? value) {
    final str = value?.toString();
    if (str.isBlank) return;
    sb.writeln('│ $key: $str');
  }

  void _printMultiline(
    StringBuffer sb,
    String text, {
    int indent = 2,
    bool copyable = false,
  }) {
    final indentStr = ' ' * indent;
    for (final line in text.split('\n')) {
      if (copyable) {
        sb.writeln('$indentStr$line');
      } else {
        sb.writeln('│$indentStr$line');
      }
    }
  }

  void _printMap(StringBuffer sb, Map<dynamic, dynamic> map, {int indent = 2}) {
    final indentStr = ' ' * indent;
    for (final entry in map.entries) {
      final key = entry.key.toString();
      final value = entry.value.toString();
      sb.writeln('│$indentStr$key: $value');
    }
  }

  void _printBody(
    StringBuffer sb,
    dynamic data, {
    required bool isRequest,
    int indent = 2,
  }) {
    final indentStr = ' ' * indent;
    final prefix = config.makeSectionsCopyable ? '' : '│';

    if (data == null) {
      sb.writeln('$prefix${indentStr}null');
      return;
    }

    // FormData - extract metadata without consuming
    if (data is FormData) {
      sb.writeln('$prefix$indentStr[FormData] boundary: ${data.boundary}');
      if (data.fields.isNotEmpty) {
        sb.writeln('$prefix${indentStr}Fields:');
        for (final field in data.fields) {
          final value = _isSensitiveKey(field.key)
              ? '***MASKED***'
              : field.value;
          sb.writeln('$prefix$indentStr  ${field.key}: $value');
        }
      }
      if (data.files.isNotEmpty) {
        sb.writeln('$prefix${indentStr}Files:');
        for (final file in data.files) {
          sb.writeln(
            '$prefix$indentStr  ${file.key}: ${file.value.filename ?? "unnamed"} '
            '(${_formatBytes(file.value.length)}, ${file.value.contentType})',
          );
        }
      }
      return;
    }

    // Binary data - show preview
    if (data is Uint8List) {
      _printBinaryPreview(sb, data, indent);
      return;
    }
    if (data is List<int>) {
      _printBinaryPreview(sb, Uint8List.fromList(data), indent);
      return;
    }

    // Stream - don't consume
    if (data is Stream) {
      sb.writeln('$prefix$indentStr<Stream> (not logged)');
      return;
    }

    // ResponseBody (from adapter layer)
    if (data is ResponseBody) {
      sb.writeln('$prefix$indentStr<ResponseBody stream> (not logged)');
      return;
    }

    // Map/List - pretty print JSON
    if (data is Map || data is List) {
      final sanitized = _sanitizeMap(data);
      final json = _prettyJson(sanitized);
      final truncated = _truncateIfNeeded(json);
      for (final line in truncated.split('\n')) {
        sb.writeln('$prefix$indentStr$line');
      }
      return;
    }

    // String - try to parse as JSON, otherwise print raw
    if (data is String) {
      if (data.length > config.maxBodyBytes) {
        sb.writeln(
          '$prefix$indentStr<String truncated: ${_formatBytes(data.length)}>',
        );
        final previewLen = math.min(200, data.length);
        sb.writeln('$prefix$indentStr${data.substring(0, previewLen)}...');
        return;
      }

      // Try parsing as JSON
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map || decoded is List) {
          final sanitized = _sanitizeMap(decoded);
          final json = _prettyJson(sanitized);
          final truncated = _truncateIfNeeded(json);
          for (final line in truncated.split('\n')) {
            sb.writeln('$prefix$indentStr$line');
          }
          return;
        }
      } catch (_) {
        // Not JSON, print raw
      }

      final truncated = _truncateIfNeeded(data);
      for (final line in truncated.split('\n')) {
        sb.writeln('$prefix$indentStr$line');
      }
      return;
    }

    // Fallback
    sb.writeln('$prefix$indentStr${data.runtimeType}: $data');
  }

  void _printBinaryPreview(StringBuffer sb, Uint8List bytes, int indent) {
    final indentStr = ' ' * indent;
    final prefix = config.makeSectionsCopyable ? '' : '│';
    sb.writeln('$prefix$indentStr[Binary] ${_formatBytes(bytes.length)}');
    if (bytes.isNotEmpty) {
      final previewLen = math.min(config.maxBinaryPreviewBytes, bytes.length);
      final preview = bytes
          .take(previewLen)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      sb.writeln(
        '$prefix${indentStr}Preview: $preview${bytes.length > previewLen ? '...' : ''}',
      );
    }
  }

  void _printStackTrace(StringBuffer sb, StackTrace stackTrace) {
    final lines = stackTrace.toString().split('\n');
    final take = math.min(config.maxStackTraceLines, lines.length);
    for (var i = 0; i < take; i++) {
      if (lines[i].trim().isNotEmpty) {
        sb.writeln('│   ${lines[i]}');
      }
    }
    if (lines.length > take) {
      sb.writeln('│   ... (${lines.length - take} more lines)');
    }
  }

  // SANITIZATION

  Uri _sanitizeUri(Uri uri) {
    if (!config.maskSensitiveData) return uri;
    if (uri.queryParameters.isEmpty) return uri;

    final sanitizedParams = <String, dynamic>{};
    uri.queryParametersAll.forEach((key, values) {
      if (_isSensitiveKey(key)) {
        sanitizedParams[key] = values.map((_) => '***MASKED***').toList();
      } else {
        sanitizedParams[key] = values;
      }
    });

    return uri.replace(queryParameters: sanitizedParams);
  }

  Map<String, dynamic> _sanitizeHeaders(Map<String, dynamic> headers) {
    final result = <String, dynamic>{};
    for (final entry in headers.entries) {
      final key = entry.key;
      final lowerKey = key.toLowerCase();

      // Skip blacklisted headers
      if (_headerBlacklistLower.contains(lowerKey)) {
        continue;
      }

      final value = entry.value;
      if (config.maskSensitiveData &&
          (_isSensitiveKey(key) || _looksLikeSensitiveValue(value))) {
        result[key] = '***MASKED***';
      } else {
        result[key] = _sanitizeMap(value);
      }
    }
    return result;
  }

  bool _looksLikeSensitiveValue(Object? value) {
    if (!config.maskSensitiveData) return false;
    if (value is! String) return false;
    final v = value.trim();
    if (v.isEmpty) return false;
    final lower = v.toLowerCase();
    if (lower.startsWith('bearer ') || lower.startsWith('basic ')) return true;
    final parts = v.split('.');
    if (parts.length == 3 && parts.every((p) => p.length >= 8)) return true;
    return false;
  }

  dynamic _sanitizeMap(dynamic data, {Set<Object>? seen}) {
    if (!config.maskSensitiveData) return data;
    seen ??= Set<Object>.identity();

    if (data is Map) {
      if (!seen.add(data)) return '<cycle>';
      final result = <dynamic, dynamic>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        if (_isSensitiveKey(key)) {
          result[entry.key] = '***MASKED***';
        } else {
          result[entry.key] = _sanitizeMap(entry.value, seen: seen);
        }
      }
      return result;
    }

    if (data is List) {
      if (!seen.add(data)) return '<cycle>';
      return data.map((e) => _sanitizeMap(e, seen: seen)).toList();
    }

    return data;
  }

  bool _isSensitiveKey(String key) {
    final lowerKey = key.toLowerCase();
    return _sensitiveKeyFragmentsLower.any(lowerKey.contains);
  }

  // UTILITIES

  _LogContext? _getCtx(RequestOptions req) {
    final v = req.extra[_ctxKey];
    return v is _LogContext ? v : null;
  }

  bool _shouldCaptureContext(RequestOptions options) {
    if (!config.enabled) return false;
    if (!(config.requestFilter?.call(options) ?? true)) return false;
    if (!config._canLogErrors && !config._canLogInfo) return false;
    return config.logRequest ||
        config.logResponse ||
        config.logError ||
        config.showPerformanceMetrics;
  }

  int? _getContentLength(Headers headers) {
    try {
      final value = headers.value(Headers.contentLengthHeader);
      if (value == null) return null;
      return int.tryParse(value);
    } catch (_) {
      final values = headers[Headers.contentLengthHeader];
      if (values == null || values.isEmpty) return null;
      return int.tryParse(values.first);
    }
  }

  String _prettyJson(dynamic data) {
    try {
      // Use encodedJsonString from dart_helper_utils for Maps
      if (data is Map) {
        return data.encodedJsonString;
      }
      // For lists and other types, use standard JSON encoder
      return JsonEncoder.withIndent('  ', _jsonFallbackEncodable).convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  Object? _jsonFallbackEncodable(Object? value) {
    if (value is Map) return value.encodableCopy;
    if (value is Set) return value.toList();
    if (value is Iterable) return value.toList();
    if (value is Enum) return value.name;
    if (value is DateTime) return value.toIso8601String();
    return value?.toString();
  }

  String _safeJsonEncode(dynamic data) {
    try {
      return jsonEncode(data, toEncodable: _jsonFallbackEncodable);
    } catch (_) {
      return data.toString();
    }
  }

  String _truncateIfNeeded(String text) {
    if (config.maxBodyBytes <= 0) return text;
    if (text.length <= config.maxBodyBytes) return text;
    return '${text.substring(0, config.maxBodyBytes)}\n... (truncated, total: ${_formatBytes(text.length)})';
  }

  int _estimateSize(dynamic data) {
    if (data == null) return 0;
    if (data is String) return data.length;
    if (data is List<int>) return data.length;
    if (data is Uint8List) return data.length;
    if (data is FormData) return data.length;
    try {
      return jsonEncode(data).length;
    } catch (_) {
      return data.toString().length;
    }
  }

  int? _estimateSizeFast(dynamic data, {required bool allowJsonEstimate}) {
    if (data == null) return 0;
    if (data is String) return data.length;
    if (data is Uint8List) return data.length;
    if (data is List<int>) return data.length;
    if (data is FormData) return data.length;
    if (data is Stream) return null;
    if (data is ResponseBody) return null;
    if ((data is Map || data is List) && !allowJsonEstimate) return null;
    return _estimateSize(data);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _escapeShellArg(String arg) {
    return arg.replaceAll("'", r"'\''").replaceAll('\n', r'\n');
  }

  void _emit(String message, {bool isError = false}) {
    if (config.printer != null) {
      config.printer!(message);
    } else if (config.useDartDeveloperLog) {
      // Using dart:developer prevents truncation in IDE consoles
      dev.log(
        message,
        name: 'DIO',
        level: isError ? 1000 : 0, // 1000 = severe
      );
    } else {
      // Fallback to print (may truncate in some environments)
      print(message);
    }
  }

  String _internalLoggerError(
    String phase,
    Object error,
    StackTrace stackTrace,
  ) {
    return '⚠️ DioLoggerInterceptor failed during $phase: $error\n$stackTrace';
  }
}

// INTERNAL CLASSES

class _LogContext {
  _LogContext(this.id, this.startTime, this.stopwatch);

  factory _LogContext.start() {
    // Generate unique ID: timestamp + random hex
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final randomPart = _random
        .nextInt(1 << 16)
        .toRadixString(16)
        .padLeft(4, '0');
    final id = '$timestamp-$randomPart';
    return _LogContext(id, DateTime.now(), Stopwatch()..start());
  }

  final String id;
  final DateTime startTime;
  final Stopwatch stopwatch;

  static final _random = math.Random();
}

class _AnsiColors {
  static const reset = '\x1B[0m';
  static const red = '\x1B[31m';
  static const green = '\x1B[32m';
  static const yellow = '\x1B[33m';
  static const cyan = '\x1B[36m';
}
