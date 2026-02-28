import 'dart:async';

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
}
