import 'package:dio/dio.dart';
import 'package:dio_smart_logger/dio_smart_logger.dart';

Future<void> main() async {
  final dio = Dio();

  // Attach the logger. Use a ready-made preset:
  //   DioLoggerConfig.development() - verbose logs, cURL, colors
  //   DioLoggerConfig.production()  - errors only, no bodies/cURL (release-safe)
  //   DioLoggerConfig.errorsOnly()  - failures only, with full forensic detail
  // ...or build a DioLoggerConfig by hand for fine-grained control.
  dio.interceptors.add(
    DioLoggerInterceptor(config: DioLoggerConfig.development()),
  );

  // To skip logging for a single request, set the opt-out flag in `extra`:
  //   dio.get(
  //     '/health',
  //     options: Options(extra: {DioLoggerInterceptor.disableLoggingKey: true}),
  //   );

  print('Dio logger interceptor is attached and ready.');
}
