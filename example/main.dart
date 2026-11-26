import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_logger/dio_smart_logger.dart';

Future<void> main() async {
  final dio = Dio()..httpClientAdapter = _StatusAdapter();
  dio.interceptors.add(
    DioLoggerInterceptor(
      config: const DioLoggerConfig(
        printer: print,
        useColors: false,
        logResponseBody: true,
      ),
    ),
  );

  try {
    await dio.get<Map<String, Object?>>(
      'https://api.example.test/status',
      options: Options(headers: {'Authorization': 'Bearer demo-credential'}),
    );
  } finally {
    dio.close();
  }
}

// Return a JSON response locally so the example can run offline.
class _StatusAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"status":"ok"}',
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
