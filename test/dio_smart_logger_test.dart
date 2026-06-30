import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_logger/dio_smart_logger.dart';
import 'package:test/test.dart';

class _TestRequestHandler extends RequestInterceptorHandler {
  Future<dynamic> get completion => future;
}

class _TestResponseHandler extends ResponseInterceptorHandler {
  Future<dynamic> get completion => future;
}

class _TestErrorHandler extends ErrorInterceptorHandler {
  Future<dynamic> get completion => future;
}

/// Builds an interceptor wired to capture output, with the noisy test defaults
/// (no colors, no dart:developer) applied. Returns the interceptor and the
/// list its printer appends to.
(DioLoggerInterceptor, List<String>) _loggerWith({
  DioLogLevel level = DioLogLevel.verbose,
  bool maskSensitiveData = true,
  bool showCurl = false,
  bool? logRequestBody,
  int maxBodyBytes = 32 * 1024,
}) {
  final logs = <String>[];
  final interceptor = DioLoggerInterceptor(
    config: DioLoggerConfig(
      level: level,
      useColors: false,
      useDartDeveloperLog: false,
      printer: logs.add,
      maskSensitiveData: maskSensitiveData,
      showCurl: showCurl,
      logRequestBody: logRequestBody,
      maxBodyBytes: maxBodyBytes,
    ),
  );
  return (interceptor, logs);
}

/// Runs [options] through [interceptor.onRequest] and returns the joined log.
Future<String> _runRequest(
  DioLoggerInterceptor interceptor,
  List<String> logs,
  RequestOptions options,
) async {
  final handler = _TestRequestHandler();
  interceptor.onRequest(options, handler);
  await handler.completion;
  return logs.join('\n');
}

void main() {
  group('DioLoggerInterceptor', () {
    test('logs request and masks sensitive values', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          enabled: true,
          level: DioLogLevel.verbose,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
        ),
      );

      final options = RequestOptions(
        path: 'https://api.example.com/users',
        method: 'POST',
        headers: {
          'authorization': 'Bearer super-secret-token',
          'x-normal': 'value',
        },
        queryParameters: {'token': 'query-secret', 'page': 1},
        data: {'password': 'my-password', 'name': 'omar'},
      );

      final handler = _TestRequestHandler();
      interceptor.onRequest(options, handler);
      await handler.completion;

      final output = logs.join('\n');
      expect(output, contains('REQUEST'));
      expect(output, contains('***MASKED***'));
      expect(output, isNot(contains('super-secret-token')));
      expect(output, isNot(contains('query-secret')));
      expect(output, isNot(contains('my-password')));
    });

    test('does not log anything when disabled', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          enabled: false,
          level: DioLogLevel.verbose,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
        ),
      );

      final options = RequestOptions(
        path: 'https://api.example.com/ping',
        method: 'GET',
      );

      final requestHandler = _TestRequestHandler();
      interceptor.onRequest(options, requestHandler);
      await requestHandler.completion;

      final responseHandler = _TestResponseHandler();
      interceptor.onResponse(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {'ok': true},
        ),
        responseHandler,
      );
      await responseHandler.completion;

      final errorHandler = _TestErrorHandler();
      interceptor.onError(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: StateError('boom'),
        ),
        errorHandler,
      );
      await expectLater(errorHandler.completion, throwsA(anything));

      expect(logs, isEmpty);
    });

    test('logs response metadata and status', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          enabled: true,
          level: DioLogLevel.debug,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
        ),
      );

      final options = RequestOptions(
        path: 'https://api.example.com/orders',
        method: 'GET',
      );

      final responseHandler = _TestResponseHandler();
      interceptor.onResponse(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          statusMessage: 'OK',
          headers: Headers.fromMap({
            Headers.contentLengthHeader: ['12'],
            Headers.contentTypeHeader: ['application/json'],
          }),
          data: {'result': 'ok'},
        ),
        responseHandler,
      );
      await responseHandler.completion;

      final output = logs.join('\n');
      expect(output, contains('RESPONSE'));
      expect(output, contains('200 OK'));
      expect(output, contains('Performance'));
    });

    test('logs error diagnostics for timeout exceptions', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          enabled: true,
          level: DioLogLevel.error,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
        ),
      );

      final options = RequestOptions(
        path: 'https://api.example.com/payments',
        method: 'POST',
      );

      final errorHandler = _TestErrorHandler();
      interceptor.onError(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
          message: 'Timed out',
          error: TimeoutException('Connection timeout'),
        ),
        errorHandler,
      );
      await expectLater(errorHandler.completion, throwsA(anything));

      final output = logs.join('\n');
      expect(output, contains('ERROR'));
      expect(output, contains('CONNECTION TIMEOUT'));
      expect(output, contains('Root Cause Analysis'));
    });

    test('logs error diagnostics for transform timeout exceptions', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          enabled: true,
          level: DioLogLevel.error,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
        ),
      );

      final options = RequestOptions(
        path: 'https://api.example.com/large-payload',
        method: 'GET',
        transformTimeout: const Duration(seconds: 2),
      );

      final errorHandler = _TestErrorHandler();
      interceptor.onError(
        DioException.transformTimeout(
          timeout: const Duration(seconds: 2),
          requestOptions: options,
        ),
        errorHandler,
      );
      await expectLater(errorHandler.completion, throwsA(anything));

      final output = logs.join('\n');
      expect(output, contains('ERROR'));
      expect(output, contains('TRANSFORM TIMEOUT'));
      expect(output, contains('Root Cause Analysis'));
    });

    test('requestFilter can skip all logs for matching requests', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          enabled: true,
          level: DioLogLevel.verbose,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
          requestFilter: (options) => options.path != '/skip',
        ),
      );

      final options = RequestOptions(path: '/skip', method: 'GET');

      final requestHandler = _TestRequestHandler();
      interceptor.onRequest(options, requestHandler);
      await requestHandler.completion;

      final responseHandler = _TestResponseHandler();
      interceptor.onResponse(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {'ok': true},
        ),
        responseHandler,
      );
      await responseHandler.completion;

      final errorHandler = _TestErrorHandler();
      interceptor.onError(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: StateError('skip'),
        ),
        errorHandler,
      );
      await expectLater(errorHandler.completion, throwsA(anything));

      expect(logs, isEmpty);
    });
  });

  group('sanitization', () {
    test('does not flag shared (non-cyclic) references as a cycle', () async {
      final shared = {'x': 1};
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: {'a': shared, 'b': shared},
        ),
      );

      expect(output, isNot(contains('cycle')));
      // The shared subtree must be rendered under both branches.
      expect('"x": 1'.allMatches(output).length, greaterThanOrEqualTo(2));
    });

    test('still detects and labels true cycles', () async {
      final cyclic = <String, dynamic>{'name': 'root'};
      cyclic['self'] = cyclic;
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: cyclic,
        ),
      );

      expect(output, contains('cycle'));
    });

    test('does not expand nested binary data into a number array', () async {
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/upload',
          method: 'POST',
          data: {
            'file': Uint8List.fromList([1, 2, 3, 4]),
          },
        ),
      );

      expect(output, contains('<binary'));
    });

    test('masks sensitive-looking values under neutral keys in body', () async {
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: {'note': 'Bearer sk_live_supersecretvalue'},
        ),
      );

      expect(output, contains('***MASKED***'));
      expect(output, isNot(contains('sk_live_supersecretvalue')));
    });
  });

  group('body formatting', () {
    test('does not print an unsanitized preview of a large non-JSON '
        'string', () async {
      const secret = 'TOPSECRET_DO_NOT_LEAK';
      final big = '$secret${'x' * (40 * 1024)}'; // non-JSON, > maxBodyBytes
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: big,
        ),
      );

      expect(output, isNot(contains(secret)));
      expect(output, contains('omitted'));
    });

    test('still masks secrets inside a large JSON string body', () async {
      const secret = 'leak-me-not-token-value';
      final big = '{"token":"$secret","filler":"${'y' * (40 * 1024)}"}';
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: big,
        ),
      );

      expect(output, contains('***MASKED***'));
      expect(output, isNot(contains(secret)));
    });

    test('pretty-prints a small JSON string body', () async {
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: '{"a":1,"b":2}',
        ),
      );

      expect(output, contains('"a": 1'));
      expect(output, contains('"b": 2'));
    });

    test('truncating a large body does not split a surrogate pair', () async {
      // Pretty JSON places a high surrogate exactly at the maxBodyBytes cut.
      final (interceptor, logs) = _loggerWith(maxBodyBytes: 11);
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          data: {'e': '😀😀😀😀'},
        ),
      );

      // A mid-emoji cut would leave a lone surrogate, which UTF-8 round-trip
      // turns into U+FFFD; valid output round-trips unchanged.
      expect(utf8.decode(utf8.encode(output)), equals(output));
    });
  });

  group('cURL generation', () {
    test('omits binary request bodies instead of JSON-encoding them', () async {
      final (interceptor, logs) = _loggerWith(showCurl: true);
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/up',
          method: 'POST',
          data: Uint8List.fromList([1, 2, 3, 4, 5]),
        ),
      );

      expect(output, contains('binary data omitted'));
      expect(output, isNot(contains('--data-raw')));
    });

    test('encodes form-urlencoded bodies the way Dio does', () async {
      final (interceptor, logs) = _loggerWith(
        showCurl: true,
        level: DioLogLevel.debug, // hide the Body section, isolate the cURL
      );
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/login',
          method: 'POST',
          contentType: Headers.formUrlEncodedContentType,
          data: {'email': 'a@b.com', 'age': 30},
        ),
      );

      expect(output, contains('email=a%40b.com'));
      expect(output, isNot(contains('"email"')));
    });

    test('encodes JSON bodies as JSON for JSON content types', () async {
      final (interceptor, logs) = _loggerWith(
        showCurl: true,
        level: DioLogLevel.debug,
      );
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/login',
          method: 'POST',
          contentType: Headers.jsonContentType,
          data: {'email': 'a@b.com'},
        ),
      );

      expect(output, contains('"email":"a@b.com"'));
    });

    test('omits the body from cURL when logRequestBody is disabled', () async {
      final logs = <String>[];
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          level: DioLogLevel.verbose,
          useColors: false,
          useDartDeveloperLog: false,
          printer: logs.add,
          showCurl: true,
          logRequestBody: false,
        ),
      );
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/login',
          method: 'POST',
          contentType: Headers.jsonContentType,
          data: {'card_pan': '4242424242424242'},
        ),
      );

      expect(output, contains('curl -X POST'));
      expect(output, isNot(contains('4242424242424242')));
      expect(output, contains('body omitted'));
    });

    test('omits oversized bodies from cURL instead of truncating', () async {
      final (interceptor, logs) = _loggerWith(
        showCurl: true,
        level: DioLogLevel.debug,
        maxBodyBytes: 40,
      );
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'POST',
          contentType: Headers.jsonContentType,
          data: {'data': 'z' * 200},
        ),
      );

      expect(output, contains('exceeds maxBodyBytes'));
      expect(output, isNot(contains('zzzz')));
    });

    test('shell-escapes multipart filenames', () async {
      final (interceptor, logs) = _loggerWith(
        showCurl: true,
        level: DioLogLevel.debug,
      );
      final formData = FormData();
      formData.files.add(
        MapEntry(
          'file',
          MultipartFile.fromString('data', filename: "in'voice.pdf"),
        ),
      );
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/upload',
          method: 'POST',
          data: formData,
        ),
      );

      expect(output, contains(r"in'\''voice.pdf"));
    });

    test('includes the body for GET requests that carry data', () async {
      final (interceptor, logs) = _loggerWith(
        showCurl: true,
        level: DioLogLevel.debug,
      );
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/search',
          method: 'GET',
          data: {'q': 'search'},
        ),
      );

      expect(output, contains('q=search'));
    });
  });

  group('request context', () {
    test('does not pollute RequestOptions.extra with internal state', () async {
      final (interceptor, _) = _loggerWith();
      final options = RequestOptions(
        path: 'https://api.example.com/a',
        method: 'GET',
      );
      final handler = _TestRequestHandler();
      interceptor.onRequest(options, handler);
      await handler.completion;

      expect(options.extra, isEmpty);
    });

    test('still logs user-provided extras', () async {
      final (interceptor, logs) = _loggerWith();
      final output = await _runRequest(
        interceptor,
        logs,
        RequestOptions(
          path: 'https://api.example.com/a',
          method: 'GET',
          extra: {'trace_id': 'abc123'},
        ),
      );

      expect(output, contains('trace_id'));
      expect(output, contains('abc123'));
    });
  });

  group('robustness', () {
    test('a throwing printer never escapes the interceptor', () async {
      final interceptor = DioLoggerInterceptor(
        config: DioLoggerConfig(
          level: DioLogLevel.verbose,
          useColors: false,
          useDartDeveloperLog: false,
          printer: (_) => throw StateError('printer boom'),
        ),
      );
      final options = RequestOptions(
        path: 'https://api.example.com/a',
        method: 'GET',
      );
      final handler = _TestRequestHandler();

      // A logging-sink failure must not break the request chain.
      expect(() => interceptor.onRequest(options, handler), returnsNormally);
      await handler.completion; // request still proceeds
    });
  });

  group('features', () {
    test('logs the HTTP version when the adapter provides it', () async {
      final (interceptor, logs) = _loggerWith(level: DioLogLevel.info);
      final handler = _TestResponseHandler();
      interceptor.onResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(
            path: 'https://api.example.com/a',
            method: 'GET',
          ),
          statusCode: 200,
          data: {'ok': true},
          extra: {HttpClientAdapter.extraKeyHttpVersion: '2'},
        ),
        handler,
      );
      await handler.completion;

      expect(logs.join('\n'), contains('HTTP Version: 2'));
    });

    test('surfaces rate-limit headers in a dedicated section', () async {
      final (interceptor, logs) = _loggerWith(level: DioLogLevel.info);
      final handler = _TestResponseHandler();
      interceptor.onResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(
            path: 'https://api.example.com/a',
            method: 'GET',
          ),
          statusCode: 429,
          headers: Headers.fromMap({
            'retry-after': ['30'],
            'x-ratelimit-remaining': ['0'],
          }),
          data: {'error': 'rate limited'},
        ),
        handler,
      );
      await handler.completion;

      final output = logs.join('\n');
      expect(output, contains('Rate Limit'));
      expect(output, contains('retry-after'));
      expect(output, contains('30'));
    });

    test('per-request opt-out suppresses all logging', () async {
      final (interceptor, logs) = _loggerWith();
      final options = RequestOptions(
        path: 'https://api.example.com/secret',
        method: 'GET',
        extra: {DioLoggerInterceptor.disableLoggingKey: true},
      );
      final handler = _TestRequestHandler();
      interceptor.onRequest(options, handler);
      await handler.completion;

      expect(logs, isEmpty);
    });

    test('production preset is locked down', () {
      final config = DioLoggerConfig.production();
      expect(config.level, DioLogLevel.error);
      expect(config.showCurl, isFalse);
      expect(config.logErrorRequestSnapshot, isFalse);
      expect(config.useColors, isFalse);
    });

    test('development preset is verbose with cURL', () {
      final config = DioLoggerConfig.development();
      expect(config.level, DioLogLevel.verbose);
      expect(config.showCurl, isTrue);
    });

    test('errorsOnly preset logs only errors but keeps forensic detail', () {
      final config = DioLoggerConfig.errorsOnly();
      expect(config.level, DioLogLevel.error);
      expect(config.showCurl, isTrue);
      expect(config.logErrorRequestSnapshot, isTrue);
    });
  });
}
