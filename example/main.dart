import 'package:dio/dio.dart';
import 'package:dio_smart_logger/dio_smart_logger.dart';

Future<void> main() async {
  final dio = Dio();

  dio.interceptors.add(
    DioLoggerInterceptor(
      config: const DioLoggerConfig(
        enabled: true,
        level: DioLogLevel.debug,
        showCurl: true,
      ),
    ),
  );

  print('Dio logger interceptor is attached and ready.');
}
