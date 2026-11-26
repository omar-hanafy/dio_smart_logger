import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_logger/src/consts.dart';
import 'package:dio_smart_logger/src/extension.dart';

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

  /// Verbose configuration for local development: full bodies, cURL,
  /// performance metrics, and colors.
  factory DioLoggerConfig.development() => const DioLoggerConfig(
    level: DioLogLevel.verbose,
    showCurl: true,
    showPerformanceMetrics: true,
  );

  /// Locked-down configuration for production: errors only, no bodies, no
  /// cURL, no stack traces, no colors. A safe default for release builds.
  factory DioLoggerConfig.production() => const DioLoggerConfig(
    level: DioLogLevel.error,
    useColors: false,
    showCurl: false,
    logErrorRequestSnapshot: false,
    logErrorResponseSnapshot: false,
    logCallSiteStackTrace: false,
    logErrorStackTrace: false,
  );

  /// Logs only failed requests, but with full forensic detail (request and
  /// response snapshots, cURL, and call-site stack trace).
  factory DioLoggerConfig.errorsOnly() =>
      const DioLoggerConfig(level: DioLogLevel.error);

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

  /// Width of the framed log box (the `┌─┐` border and section rules).
  ///
  /// Long values are not wrapped to this width; it only sizes the box border.
  /// Must be >= 20.
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

  /// Log where the request was initiated, using Dio's `sourceStackTrace`.
  ///
  /// Best-effort: this reads an `@internal` Dio field (added in 5.9.0), so a
  /// future Dio release could change or remove it. The value is null-checked
  /// and any failure is contained by the interceptor's own error handling.
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

  /// Max body size to log, in UTF-16 code units (equivalent to bytes for
  /// ASCII content). Prevents freezing on large responses: rendered bodies are
  /// truncated past this size, and oversized cURL bodies are omitted entirely.
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
///
/// The reported `Duration` is measured between this interceptor's `onRequest`
/// and its `onResponse`/`onError`, so it reflects the interceptor's own view of
/// the round trip. Dio runs request and response interceptors in registration
/// order. This interval includes response processing by earlier interceptors.
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

  /// Set `Options(extra: {DioLoggerInterceptor.disableLoggingKey: true})` on a
  /// request to suppress all logging (and timing) for that single request.
  static const String disableLoggingKey = 'dio_smart_logger.disable';

  /// Runtime configuration that controls output and filtering behavior.
  final DioLoggerConfig config;
  static const _masked = '***MASKED***';
  final List<String> _sensitiveKeyFragmentsLower;
  final Set<String> _headerBlacklistLower;

  // Per-request state keyed on RequestOptions identity. An Expando keeps this
  // out of the user-visible `extra` map, and makes a copied RequestOptions
  // (e.g. a retry interceptor's copyWith) get a fresh context instead of
  // sharing a stale, already-stopped stopwatch by reference.
  final Expando<_LogContext> _contexts = Expando<_LogContext>(
    'dio_smart_logger',
  );

  // REQUEST

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_shouldCaptureContext(options) && _getCtx(options) == null) {
      _contexts[options] = _LogContext.start();
    }

    if (_isLoggingDisabled(options) || !config.shouldLogRequest(options)) {
      handler.next(options);
      return;
    }

    final ctx = _getCtx(options) ?? _LogContext.start();
    _contexts[options] = ctx;

    try {
      final lines = StringBuffer();
      final queryMasks = _queryMasks(options);
      final sanitizedUri = _sanitizeUri(options.uri, queryMasks);

      // ───────────────────────────────────────────────────────────────────────
      // Header
      // ───────────────────────────────────────────────────────────────────────
      _boxTop(
        lines,
        '📤 REQUEST [${ctx.id}] ${options.method}',
        _AnsiColors.cyan,
      );
      _kv(lines, 'URI', sanitizedUri.toString());
      _kv(lines, 'BaseURL', _displayUri(options.baseUrl, queryMasks));
      _kv(lines, 'Path', _displayUri(options.path, queryMasks));

      // ───────────────────────────────────────────────────────────────────────
      // Request Configuration
      // ───────────────────────────────────────────────────────────────────────
      if (config._canLogDebug) {
        _section(lines, 'Configuration');
        _kv(
          lines,
          'ContentType',
          _headerValue(Headers.contentTypeHeader, options.contentType),
        );
        _kv(lines, 'ResponseType', options.responseType.name);
        _kv(lines, 'FollowRedirects', options.followRedirects);
        _kv(lines, 'MaxRedirects', options.maxRedirects);
        _kv(lines, 'PersistentConnection', options.persistentConnection);
        _kv(
          lines,
          'Timeouts',
          'connect=${options.connectTimeout ?? "∞"} | '
              'send=${options.sendTimeout ?? "∞"} | '
              'receive=${options.receiveTimeout ?? "∞"} | '
              'transform=${options.transformTimeout ?? "∞"}',
        );
      }

      // ───────────────────────────────────────────────────────────────────────
      // Query Parameters
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogRequestQueryParams &&
          options.queryParameters.isNotEmptyOrNull) {
        _section(lines, 'Query Parameters');
        final sanitizedQuery =
            _sanitizeData(options.queryParameters) as Map<dynamic, dynamic>;
        _printMap(lines, sanitizedQuery);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Headers
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogRequestHeaders &&
          options.headers.isNotEmptyOrNull) {
        _section(lines, 'Headers');
        final sanitizedHeaders = _sanitizeHeaders(options.headers, queryMasks);
        _printMap(lines, sanitizedHeaders);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Extras
      // ───────────────────────────────────────────────────────────────────────
      final extras = options.extra;
      if (config._canLogDebug && extras.isNotEmptyOrNull) {
        _section(lines, 'Extras');
        _printMap(lines, _sanitizeData(extras) as Map<dynamic, dynamic>);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Body
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogRequestBody && options.data != null) {
        _section(lines, 'Body');
        _printBody(lines, options.data, contentType: options.contentType);
      }

      // ───────────────────────────────────────────────────────────────────────
      // cURL
      // ───────────────────────────────────────────────────────────────────────
      if (config.showCurl) {
        _section(lines, 'cURL');
        _printMultiline(
          lines,
          _generateCurl(options, sanitizedUri, queryMasks),
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
    _contexts[req] = null;

    if (_isLoggingDisabled(req) || !config.shouldLogResponse(req)) {
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
      final queryMasks = _queryMasks(req);
      final displayedUri = _sanitizeUri(response.realUri, queryMasks);
      _kv(lines, 'URI', displayedUri);
      _kv(lines, 'Duration', '$duration ms');

      // HTTP protocol version, when the adapter reports it (Dio 5.9.2+, IO).
      final httpVersion = response.extra[HttpClientAdapter.extraKeyHttpVersion];
      if (httpVersion != null) {
        _kv(lines, 'HTTP Version', httpVersion);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Status Code Meaning
      // ───────────────────────────────────────────────────────────────────────
      if (config.showStatusCodeMeaning && response.statusCode != null) {
        final userMsg = httpStatusUserMessages[statusCode];
        if (userMsg != null) {
          _kv(lines, 'Status', userMsg);
        }
      }

      // ───────────────────────────────────────────────────────────────────────
      // Redirect Chain
      // ───────────────────────────────────────────────────────────────────────
      if (response.redirects.isNotEmptyOrNull) {
        _section(lines, 'Redirect Chain (${response.redirects.length})');
        for (var i = 0; i < response.redirects.length; i++) {
          final r = response.redirects[i];
          _kv(
            lines,
            '${i + 1}. [${r.statusCode}] ${r.method}',
            _sanitizeUri(r.location, queryMasks),
          );
        }
        _kv(lines, 'Final URI', displayedUri);
      }

      // ───────────────────────────────────────────────────────────────────────
      // Response Headers
      // ───────────────────────────────────────────────────────────────────────
      if (config.effectiveLogResponseHeaders &&
          response.headers.map.isNotEmptyOrNull) {
        _section(lines, 'Headers');
        _printMap(lines, _sanitizeHeaders(response.headers.map, queryMasks));
      }

      _maybePrintRateLimit(lines, response.headers);

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
          _printBody(
            lines,
            response.data,
            contentType:
                response.headers[Headers.contentTypeHeader]?.firstOrNull,
            responseType: req.responseType,
          );
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
    _contexts[req] = null;

    if (_isLoggingDisabled(req) || !config.shouldLogError(req)) {
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
      final queryMasks = _queryMasks(req);
      final sanitizedUri = _sanitizeUri(req.uri, queryMasks);
      _kv(lines, 'URI', sanitizedUri);
      _kv(lines, 'Duration', '$duration ms');
      _kv(lines, 'Type', err.type.name);

      // ─────────────────────────────────────────────────────────────────────────
      // Error Message
      // ─────────────────────────────────────────────────────────────────────────
      if (err.message.isNotBlank) {
        _kv(lines, 'Message', err.message);
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Status Code Meaning
      // ─────────────────────────────────────────────────────────────────────────
      if (config.showStatusCodeMeaning && statusCode != null) {
        final devMsg = httpStatusDevMessages[statusCode];
        final userMsg = httpStatusUserMessages[statusCode];
        if (devMsg != null) _kv(lines, 'Technical', devMsg);
        if (userMsg != null) _kv(lines, 'User Hint', userMsg);
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Root Cause Analysis (Forensic Error Details)
      // ─────────────────────────────────────────────────────────────────────────
      _section(lines, 'Root Cause Analysis');
      _printErrorDetails(lines, err, queryMasks);

      // Rate-limit headers are high-value on 429/503 errors; surface them
      // regardless of the response-snapshot setting.
      if (err.response != null) {
        _maybePrintRateLimit(lines, err.response!.headers);
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Request Snapshot
      // ─────────────────────────────────────────────────────────────────────────
      if (config.logErrorRequestSnapshot) {
        _section(lines, 'Request Snapshot');
        _kv(lines, 'Method', req.method);
        _kv(
          lines,
          'ContentType',
          _headerValue(Headers.contentTypeHeader, req.contentType),
        );
        _kv(
          lines,
          'Timeouts',
          'connect=${req.connectTimeout ?? "∞"} | '
              'send=${req.sendTimeout ?? "∞"} | '
              'receive=${req.receiveTimeout ?? "∞"} | '
              'transform=${req.transformTimeout ?? "∞"}',
        );

        if (req.queryParameters.isNotEmptyOrNull) {
          lines.writeln('│ Query Parameters:');
          _printMap(
            lines,
            _sanitizeData(req.queryParameters) as Map<dynamic, dynamic>,
            indent: 4,
          );
        }

        if (req.headers.isNotEmptyOrNull) {
          lines.writeln('│ Headers:');
          _printMap(
            lines,
            _sanitizeHeaders(req.headers, queryMasks),
            indent: 4,
          );
        }

        if (req.data != null) {
          lines.writeln('│ Body:');
          _printBody(lines, req.data, contentType: req.contentType, indent: 4);
        }
      }

      // ─────────────────────────────────────────────────────────────────────────
      // Response Snapshot (if available)
      // ─────────────────────────────────────────────────────────────────────────
      if (config.logErrorResponseSnapshot && err.response != null) {
        final res = err.response!;
        _section(lines, 'Response Snapshot');
        _kv(lines, 'Status', '${res.statusCode} ${res.statusMessage ?? ""}');
        _kv(lines, 'Real URI', _sanitizeUri(res.realUri, queryMasks));

        if (res.redirects.isNotEmptyOrNull) {
          lines.writeln('│ Redirects:');
          for (final r in res.redirects) {
            lines.writeln(
              '│   ${r.statusCode} ${r.method} → ${_sanitizeUri(r.location, queryMasks)}',
            );
          }
        }

        if (res.headers.map.isNotEmptyOrNull) {
          lines.writeln('│ Headers:');
          _printMap(
            lines,
            _sanitizeHeaders(res.headers.map, queryMasks),
            indent: 4,
          );
        }

        if (res.data != null) {
          lines.writeln('│ Body:');
          _printBody(
            lines,
            res.data,
            contentType: res.headers[Headers.contentTypeHeader]?.firstOrNull,
            responseType: req.responseType,
            indent: 4,
          );
        }
      }

      // ─────────────────────────────────────────────────────────────────────────
      // cURL (very useful for reproducing errors)
      // ─────────────────────────────────────────────────────────────────────────
      if (config.showCurl) {
        _section(lines, 'Retry cURL');
        _printMultiline(
          lines,
          _generateCurl(req, sanitizedUri, queryMasks),
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

  void _printErrorDetails(
    StringBuffer lines,
    DioException err,
    _QueryMasks? queryMasks,
  ) {
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
        _printUnderlyingError(lines, err.error, queryMasks);

      case DioExceptionType.sendTimeout:
        lines.writeln('│ ⏱️ SEND TIMEOUT');
        lines.writeln('│   Request data took too long to send.');
        lines.writeln(
          '│   Configured timeout: ${err.requestOptions.sendTimeout}',
        );
        if (err.requestOptions.data != null) {
          final size = _estimateSizeFast(
            err.requestOptions.data,
            allowJsonEstimate: false,
          );
          if (size != null) {
            lines.writeln('│   Data size: ${_formatBytes(size)}');
          }
        }
        _printUnderlyingError(lines, err.error, queryMasks);

      case DioExceptionType.receiveTimeout:
        lines.writeln('│ ⏱️ RECEIVE TIMEOUT');
        lines.writeln('│   Server response took too long.');
        lines.writeln(
          '│   Configured timeout: ${err.requestOptions.receiveTimeout}',
        );
        _printUnderlyingError(lines, err.error, queryMasks);

      case DioExceptionType.transformTimeout:
        lines.writeln('│ ⏱️ TRANSFORM TIMEOUT');
        lines.writeln('│   Response data transformation took too long.');
        lines.writeln('│   (e.g. background JSON decoding of a large payload)');
        lines.writeln(
          '│   Configured timeout: ${err.requestOptions.transformTimeout}',
        );
        _printUnderlyingError(lines, err.error, queryMasks);

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
        _printUnderlyingError(lines, err.error, queryMasks);

      case DioExceptionType.unknown:
        lines.writeln('│ ❓ UNKNOWN ERROR');
        lines.writeln('│   An unexpected error occurred.');
        _printUnderlyingError(lines, err.error, queryMasks);
    }
  }

  void _printUnderlyingError(
    StringBuffer lines,
    Object? error,
    _QueryMasks? queryMasks,
  ) {
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
    } else if (error is! FormatException) {
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
      if (uri is Uri || uri is String) {
        lines.writeln('│   │ URI: ${_displayUri(uri.toString(), queryMasks)}');
      }
    } catch (_) {}

    // Parser input can contain a raw request or response body.
    if (!config.maskSensitiveData &&
        config.logErrorRequestSnapshot &&
        config.logErrorResponseSnapshot) {
      try {
        final source = e.source;
        if (source != null) {
          final s = source.toString();
          lines.writeln(
            '│   │ Source: ${s.length > 100 ? '${s.substring(0, 100)}...' : s}',
          );
        }
      } catch (_) {}
    }

    lines.writeln('│   └─');
  }

  // CURL GENERATOR

  String _generateCurl(
    RequestOptions options,
    Uri uri,
    _QueryMasks? queryMasks,
  ) {
    final method = options.method;
    final methodArg = RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(method)
        ? method
        : "'${_escapeShellArg(method)}'";
    final components = <String>['curl -X $methodArg'];

    // Headers. curl recomputes Content-Length from the actual body, so a
    // stale value carried in the request options would corrupt the command.
    _sanitizeHeaders(options.headers, queryMasks).forEach((key, value) {
      if (key.toLowerCase() != 'content-length') {
        components.add("-H '${_escapeShellArg('$key: $value')}'");
      }
    });

    // The URL must precede any trailing body-omission comment.
    components.add("'${_escapeShellArg(uri.toString())}'");

    // Dio sends a body whenever data is non-null, including GET requests.
    if (options.data != null) {
      components.addAll(_curlBodyArgs(options));
    }

    return components.join(' \\\n  ');
  }

  /// Builds the cURL body argument(s), mirroring how Dio serializes the
  /// request body so the command reproduces the real request.
  List<String> _curlBodyArgs(RequestOptions options) {
    final Object? data = options.data;
    if (data == null) return const [];

    // Honor an explicit request-body opt-out: if the user turned body logging
    // off, keep it out of the reproducible command too.
    if (config.logRequestBody == false) {
      return const ['# <body omitted: request body logging disabled>'];
    }

    // FormData -> repeated -F flags (never finalize the stream).
    if (data is FormData) {
      final parts = <String>[];
      for (final field in data.fields) {
        final key = _escapeShellArg(field.key);
        final value = _shouldMask(field.key, field.value)
            ? _masked
            : field.value;
        parts.add("--form-string '$key=${_escapeShellArg(value)}'");
      }
      for (final file in data.files) {
        final key = _escapeShellArg(file.key);
        final name = file.value.filename ?? 'file';
        final filename = _escapeShellArg(
          _shouldMask(file.key, name) ? _masked : name,
        );
        parts.add("-F '$key=@$filename'");
      }
      return parts;
    }

    // Binary/stream must be matched before List (Uint8List is a List<int>).
    if ((data is TypedData || data is List<int>) &&
        !_isJsonNumberList(data, options.contentType)) {
      return const ['# <binary data omitted>'];
    }
    if (data is Stream) {
      return const ['# <stream data omitted>'];
    }

    final body = _curlEncodeBody(data, options);
    if (body == null || body.isEmpty) return const [];

    // A reproducible command needs a complete body; truncating produces an
    // invalid request, so oversized bodies are omitted entirely.
    if (config.maxBodyBytes > 0 && body.length > config.maxBodyBytes) {
      return [
        '# <body omitted: ${_formatBytes(body.length)} exceeds maxBodyBytes>',
      ];
    }

    return ["--data-raw '${_escapeShellArg(body)}'"];
  }

  /// Serializes [data] the way Dio's default request transformer
  /// ([Transformer.defaultTransformRequest]) would, so the cURL body matches
  /// the bytes actually sent on the wire.
  String? _curlEncodeBody(Object data, RequestOptions options) {
    if (data is String) {
      return _renderStringBody(data, options.contentType, pretty: false);
    }

    // JSON content type -> JSON encode.
    if (Transformer.isJsonMimeType(options.contentType)) {
      return _safeJsonEncode(data is List<num> ? data : _sanitizeData(data));
    }

    // Otherwise Dio url-encodes a Map<String, dynamic>.
    if (data is Map) {
      final sanitized = _sanitizeData(data);
      if (sanitized is Map) {
        return Transformer.urlEncodeMap(
          sanitized.map((k, v) => MapEntry(k.toString(), v)),
          options.listFormat,
        );
      }
    }

    // Lists and other shapes: best-effort JSON.
    if (data is Map || data is List) {
      return _safeJsonEncode(_sanitizeData(data));
    }

    return data.toString();
  }

  // FORMATTING HELPERS

  void _boxTop(StringBuffer sb, String title, String color) {
    final c = config.useColors ? color : '';
    final r = config.useColors ? _AnsiColors.reset : '';
    final titleWidth = _visualWidth(title);
    sb
      ..writeln('')
      ..writeln('$c┌${'─' * (config.maxLineWidth - 2)}┐$r')
      ..writeln(
        '$c│ $title${' ' * math.max(0, config.maxLineWidth - titleWidth - 4)}│$r',
      )
      ..writeln('$c├${'─' * (config.maxLineWidth - 2)}┤$r');
  }

  void _boxBottom(StringBuffer sb, String color) {
    final c = config.useColors ? color : '';
    final r = config.useColors ? _AnsiColors.reset : '';
    sb.writeln('$c└${'─' * (config.maxLineWidth - 2)}┘$r');
  }

  /// Estimates the visual column width of [text] in a monospace terminal.
  ///
  /// Emoji and wide Unicode characters occupy 2 columns, zero-width modifiers
  /// (variation selectors, ZWJ) occupy 0 columns.
  static int _visualWidth(String text) {
    var width = 0;
    for (final rune in text.runes) {
      if (_isZeroWidth(rune)) continue;
      width += _isWideChar(rune) ? 2 : 1;
    }
    return width;
  }

  static bool _isZeroWidth(int rune) =>
      // Variation selectors
      (rune >= 0xFE00 && rune <= 0xFE0F) ||
      // Zero-width joiner / non-joiner
      rune == 0x200D ||
      rune == 0x200C ||
      // Combining diacritical marks (common ranges)
      (rune >= 0x0300 && rune <= 0x036F) ||
      // Skin tone modifiers
      (rune >= 0x1F3FB && rune <= 0x1F3FF);

  static bool _isWideChar(int rune) =>
      // Miscellaneous symbols & pictographs, emoticons, transport symbols, etc.
      (rune >= 0x1F300 && rune <= 0x1FAFF) ||
      // Dingbats (heavy check mark, cross mark, etc.)
      (rune >= 0x2700 && rune <= 0x27BF) ||
      // Miscellaneous technical (hourglass, watch, etc.)
      (rune >= 0x2300 && rune <= 0x23FF) ||
      // Enclosed alphanumerics supplement (circled numbers, etc.)
      (rune >= 0x1F100 && rune <= 0x1F1FF) ||
      // CJK unified ideographs
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      // Fullwidth forms
      (rune >= 0xFF01 && rune <= 0xFF60);

  void _section(StringBuffer sb, String title) {
    final titleWidth = _visualWidth(title);
    sb
      ..writeln('│')
      ..writeln(
        '├─── $title ${'─' * math.max(0, config.maxLineWidth - titleWidth - 8)}',
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
    Object? data, {
    String? contentType,
    ResponseType? responseType,
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
          final value = _shouldMask(field.key, field.value)
              ? _masked
              : field.value;
          sb.writeln('$prefix$indentStr  ${field.key}: $value');
        }
      }
      if (data.files.isNotEmpty) {
        sb.writeln('$prefix${indentStr}Files:');
        for (final file in data.files) {
          final name = file.value.filename ?? 'unnamed';
          final filename = _shouldMask(file.key, name) ? _masked : name;
          sb.writeln(
            '$prefix$indentStr  ${file.key}: $filename '
            '(${_formatBytes(file.value.length)}, ${file.value.contentType})',
          );
        }
      }
      return;
    }

    // Binary data - show preview
    if (data is List<int> &&
        (responseType == ResponseType.bytes ||
            !_isJsonNumberList(data, contentType))) {
      _printBinaryPreview(sb, data, indent);
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
      final sanitized = _isJsonNumberList(data, contentType)
          ? data
          : _sanitizeData(data);
      final json = _prettyJson(sanitized);
      final truncated = _truncateIfNeeded(json);
      for (final line in truncated.split('\n')) {
        sb.writeln('$prefix$indentStr$line');
      }
      return;
    }

    if (data is String) {
      final text = _renderStringBody(
        data,
        contentType,
        pretty: true,
        decodedJson: responseType == ResponseType.json,
      );
      for (final line in text.split('\n')) {
        sb.writeln('$prefix$indentStr$line');
      }
      return;
    }

    // Fallback
    sb.writeln('$prefix$indentStr${data.runtimeType}: $data');
  }

  // Dio sends Uint8List as bytes even when the request declares JSON.
  bool _isJsonNumberList(Object data, String? contentType) =>
      data is List<num> &&
      data is! Uint8List &&
      Transformer.isJsonMimeType(contentType);

  String _renderStringBody(
    String text,
    String? contentType, {
    required bool pretty,
    bool decodedJson = false,
  }) {
    if (!pretty && !config.maskSensitiveData) return text;

    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') ||
        trimmed.startsWith('[') ||
        (trimmed.startsWith('"') && Transformer.isJsonMimeType(contentType))) {
      var redacted = false;
      try {
        final decoded = jsonDecode(
          text,
          reviver: (key, value) {
            if ((config.maskSensitiveData &&
                    key is String &&
                    _isSensitiveKey(key)) ||
                _looksLikeSensitiveValue(value)) {
              redacted = true;
              return _masked;
            }
            return value;
          },
        );
        if (pretty) return _truncateIfNeeded(_prettyJson(decoded));
        // Preserve the exact wire spelling when nothing needed masking.
        return redacted ? jsonEncode(decoded) : text;
      } on FormatException {
        if (!decodedJson &&
            config.maskSensitiveData &&
            Transformer.isJsonMimeType(contentType)) {
          return '<malformed JSON omitted>';
        }
      }
    }

    final mime = contentType?.split(';').first.trim().toLowerCase();
    if (mime == Headers.formUrlEncodedContentType) {
      final safe = _sanitizeEncodedFields(text);
      return pretty ? _truncateIfNeeded(safe) : safe;
    }
    if (_looksLikeSensitiveValue(text)) return _masked;

    // Omit oversized opaque text in full: an arbitrary prefix may contain
    // credentials. Structured values above have already been sanitized.
    if (pretty && text.length > config.maxBodyBytes) {
      return '<String body omitted: ${_formatBytes(text.length)}>';
    }
    return text;
  }

  void _printBinaryPreview(StringBuffer sb, List<int> bytes, int indent) {
    final indentStr = ' ' * indent;
    final prefix = config.makeSectionsCopyable ? '' : '│';
    sb.writeln('$prefix$indentStr[Binary] ${_formatBytes(bytes.length)}');
    if (bytes.isNotEmpty) {
      final previewLen = math.min(config.maxBinaryPreviewBytes, bytes.length);
      final preview = bytes
          .take(previewLen)
          .map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0'))
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

  // A redirect or exception can copy serialized query fields onto a different
  // URL. Match those fields by decoded name and value so parameter reordering,
  // escaping and path changes still use the original per-element redaction.
  _QueryMasks? _queryMasks(RequestOptions options) {
    final query = options.queryParameters;
    if (!config.maskSensitiveData ||
        !query.values.any(
          (value) => value is List || value is ListParam || value is Map,
        )) {
      return const {};
    }
    final display = <String, dynamic>{
      for (final entry in query.entries)
        entry.key: _sanitizeData(entry.value, forQuery: true),
    };
    final original = Transformer.urlEncodeQueryMap(query, options.listFormat);
    final masked = Transformer.urlEncodeQueryMap(display, options.listFormat);
    if (original == masked) return const {};

    // Joined maps can contain literal URI delimiters. Once a credential has
    // split across fields or into a fragment, individual fields are ambiguous.
    if (original.contains('#') ||
        '&'.allMatches(original).length != '&'.allMatches(masked).length) {
      return null;
    }
    final Map<String, List<String>> originalFields;
    final Map<String, List<String>> maskedFields;
    try {
      originalFields = Uri(query: original).queryParametersAll;
      maskedFields = Uri(query: masked).queryParametersAll;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    final replacements = <(String, String), String>{};
    for (final entry in originalFields.entries) {
      final values = entry.value;
      final safe = maskedFields[entry.key];
      if (safe == null || safe.length != values.length) {
        if (_isSensitiveKey(entry.key)) continue;
        return null;
      }
      for (var i = 0; i < values.length; i++) {
        if (safe[i] != values[i]) {
          replacements[(entry.key, values[i])] = safe[i];
        }
      }
    }
    return replacements;
  }

  String _displayUri(String text, _QueryMasks? queryMasks) {
    if (!config.maskSensitiveData || text.isEmpty) return text;
    final uri = Uri.tryParse(text);
    return uri == null
        ? '<invalid URI>'
        : _sanitizeUri(uri, queryMasks).toString();
  }

  Uri _sanitizeUri(Uri uri, _QueryMasks? queryMasks) {
    if (!config.maskSensitiveData) return uri;
    final userInfo = uri.userInfo.isEmpty ? null : _masked;
    if (queryMasks == null) {
      return uri.replace(
        userInfo: userInfo,
        query: uri.hasQuery ? _masked : null,
        fragment: uri.hasFragment ? _masked : null,
      );
    }
    // Dio can append query parameters after an existing fragment.
    final fragment = uri.fragment;
    final fieldsStart = fragment.indexOf('?') + 1;
    return uri.replace(
      userInfo: userInfo,
      query: uri.hasQuery
          ? _sanitizeEncodedFields(uri.query, queryMasks)
          : null,
      fragment: uri.hasFragment
          ? fragment.substring(0, fieldsStart) +
                _sanitizeEncodedFields(
                  fragment.substring(fieldsStart),
                  queryMasks,
                )
          : null,
    );
  }

  // Preserve repeated fields, their order and original encoding. Decode only
  // for matching, so a URI or form with no sensitive fields keeps its spelling.
  String _sanitizeEncodedFields(
    String fields, [
    _QueryMasks queryMasks = const {},
  ]) {
    if (!config.maskSensitiveData || fields.isEmpty) return fields;
    return fields
        .split('&')
        .map((field) {
          final separator = field.indexOf('=');
          if (separator < 0) return field;
          final encodedKey = field.substring(0, separator);
          try {
            final key = Uri.decodeQueryComponent(encodedKey);
            final value = Uri.decodeQueryComponent(
              field.substring(separator + 1),
            );
            final projected = queryMasks[(key, value)];
            final maskWholeField =
                _isSensitiveKey(key) ||
                _looksLikeSensitiveValue(projected ?? value);
            final safe = maskWholeField ? _masked : projected;
            if (safe != null) {
              return '$encodedKey=${Uri.encodeQueryComponent(safe)}';
            }
          } on ArgumentError {
            return _masked;
          } on FormatException {
            return _masked;
          }
          return field;
        })
        .join('&');
  }

  bool _shouldMask(String key, Object? value) =>
      config.maskSensitiveData &&
      (_isSensitiveKey(key) || _looksLikeSensitiveValue(value));

  Map<String, Object?> _sanitizeHeaders(
    Map<String, Object?> headers, [
    _QueryMasks? queryMasks = const {},
  ]) => {
    for (final entry in headers.entries)
      entry.key: ?_headerValue(entry.key, entry.value, queryMasks),
  };

  Object? _headerValue(
    String key,
    Object? value, [
    _QueryMasks? queryMasks = const {},
  ]) {
    final name = key.toLowerCase();
    if (value == null || _headerBlacklistLower.contains(name)) return null;
    if (config.maskSensitiveData && _isSensitiveKey(key)) return _masked;

    Object? sanitize(Object? item) {
      if ((item is String || item is Uri) &&
          (name == 'location' ||
              name == 'content-location' ||
              name == 'referer')) {
        return _looksLikeSensitiveValue(item)
            ? _masked
            : _displayUri(item.toString(), queryMasks);
      }
      return _sanitizeData(item);
    }

    return value is Iterable ? value.map(sanitize).join(', ') : sanitize(value);
  }

  static final _credentialsPrefix = RegExp(
    r'^(bearer|basic) ',
    caseSensitive: false,
  );
  static final _jwtPattern = RegExp(
    r'^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$',
  );

  bool _looksLikeSensitiveValue(Object? value) {
    if (!config.maskSensitiveData || value is! String) return false;
    final trimmed = value.trim();
    return _credentialsPrefix.hasMatch(trimmed) ||
        _jwtPattern.hasMatch(trimmed);
  }

  dynamic _sanitizeData(
    dynamic data, {
    Set<Object>? seen,
    bool forQuery = false,
  }) {
    if (!config.maskSensitiveData) return data;
    seen ??= Set<Object>.identity();

    // Binary payloads must never be expanded into number arrays.
    if (data is TypedData) {
      return forQuery ? data : '<binary: ${_formatBytes(data.lengthInBytes)}>';
    }

    if (data is ListParam) {
      if (!seen.add(data)) return '<cycle>';
      try {
        final values = data.value
            .map((v) => _sanitizeData(v, seen: seen, forQuery: forQuery))
            .toList();
        return ListParam(values, data.format);
      } finally {
        seen.remove(data);
      }
    }

    if (data is Map) {
      // Track the current path, not a global visited set, so a value shared
      // across sibling branches (a DAG) is not mistaken for a cycle.
      if (!seen.add(data)) return '<cycle>';
      try {
        final result = <dynamic, dynamic>{};
        for (final entry in data.entries) {
          final key = entry.key.toString();
          if (_isSensitiveKey(key)) {
            result[entry.key] = _masked;
          } else {
            result[entry.key] = _sanitizeData(
              entry.value,
              seen: seen,
              forQuery: forQuery,
            );
          }
        }
        return result;
      } finally {
        seen.remove(data);
      }
    }

    if (data is List) {
      if (!seen.add(data)) return '<cycle>';
      try {
        return data
            .map((e) => _sanitizeData(e, seen: seen, forQuery: forQuery))
            .toList();
      } finally {
        seen.remove(data);
      }
    }

    // Value-based redaction for sensitive-looking leaves (e.g. "Bearer ..."
    // or a JWT) even when the surrounding key is neutral.
    if (_looksLikeSensitiveValue(data)) {
      return _masked;
    }

    return data;
  }

  bool _isSensitiveKey(String key) {
    final lowerKey = key.toLowerCase();
    return _sensitiveKeyFragmentsLower.any(lowerKey.contains);
  }

  // UTILITIES

  _LogContext? _getCtx(RequestOptions req) => _contexts[req];

  /// Whether the caller opted this single request out via [disableLoggingKey].
  bool _isLoggingDisabled(RequestOptions o) =>
      o.extra[disableLoggingKey] == true;

  bool _shouldCaptureContext(RequestOptions options) {
    if (!config.enabled) return false;
    if (_isLoggingDisabled(options)) return false;
    if (!(config.requestFilter?.call(options) ?? true)) return false;
    if (!config._canLogErrors && !config._canLogInfo) return false;
    return config.logRequest ||
        config.logResponse ||
        config.logError ||
        config.showPerformanceMetrics;
  }

  // Common rate-limiting/throttling response headers (lowercased).
  static const Set<String> _rateLimitHeaders = {
    'retry-after',
    'x-ratelimit-limit',
    'x-ratelimit-remaining',
    'x-ratelimit-reset',
    'x-rate-limit-limit',
    'x-rate-limit-remaining',
    'x-rate-limit-reset',
    'ratelimit-limit',
    'ratelimit-remaining',
    'ratelimit-reset',
  };

  /// Surfaces rate-limit headers (when present) in their own section,
  /// independent of the header-logging level since they are high-value
  /// diagnostics on `429`/`503` responses.
  void _maybePrintRateLimit(StringBuffer lines, Headers headers) {
    final found = _sanitizeHeaders({
      for (final entry in headers.map.entries)
        if (_rateLimitHeaders.contains(entry.key.toLowerCase()) &&
            entry.value.isNotEmpty)
          entry.key: entry.value,
    });
    if (found.isEmpty) return;
    _section(lines, 'Rate Limit');
    found.forEach((key, value) => _kv(lines, key, value));
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
      // Use standard JSON encoder with custom fallback for non-JSON-safe values.
      return JsonEncoder.withIndent('  ', _jsonFallbackEncodable).convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  Object? _jsonFallbackEncodable(Object? value) {
    return _toJsonEncodable(value);
  }

  dynamic _toJsonEncodable(dynamic value, {Set<Object>? seen}) {
    seen ??= Set<Object>.identity();

    if (value == null || value is String || value is num || value is bool) {
      return value;
    }

    if (value is Enum) return value.name;
    if (value is DateTime) return value.toIso8601String();
    // Must precede the Iterable branch: typed binary is an Iterable<int>.
    if (value is TypedData) {
      return '<binary: ${_formatBytes(value.lengthInBytes)}>';
    }

    if (value is Map) {
      if (!seen.add(value)) return '<cycle>';
      try {
        final map = <String, dynamic>{};
        for (final entry in value.entries) {
          map[entry.key.toString()] = _toJsonEncodable(entry.value, seen: seen);
        }
        return map;
      } finally {
        seen.remove(value);
      }
    }

    if (value is Set) {
      if (!seen.add(value)) return '<cycle>';
      try {
        return value.map((e) => _toJsonEncodable(e, seen: seen)).toList();
      } finally {
        seen.remove(value);
      }
    }

    if (value is Iterable) {
      if (!seen.add(value)) return '<cycle>';
      try {
        return value.map((e) => _toJsonEncodable(e, seen: seen)).toList();
      } finally {
        seen.remove(value);
      }
    }

    return value.toString();
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
    var cut = config.maxBodyBytes;
    // Don't slice through a surrogate pair, which would emit a lone surrogate.
    if (_isHighSurrogate(text.codeUnitAt(cut - 1))) cut -= 1;
    return '${text.substring(0, cut)}\n... (truncated, total: ${_formatBytes(text.length)})';
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

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
    // A logging sink must never break the request. If a custom printer (or any
    // sink) throws, fall back to dart:developer and, failing that, swallow.
    try {
      if (config.printer != null) {
        config.printer!(message);
        return;
      }
      if (config.useDartDeveloperLog) {
        // Using dart:developer prevents truncation in IDE consoles.
        dev.log(
          message,
          name: 'DIO',
          level: isError ? 1000 : 0, // 1000 = severe
        );
        return;
      }
      // Fallback to print (may truncate in some environments).
      print(message);
    } catch (e, st) {
      try {
        dev.log(
          'DioLoggerInterceptor output sink threw: $e',
          name: 'DIO',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      } catch (_) {
        // Nothing left to do - never rethrow from the logger.
      }
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

typedef _QueryMasks = Map<(String, String), String>;

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
