import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_logger/dio_smart_logger.dart';
import 'package:test/test.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.response);

  final ResponseBody response;
  late final RequestOptions request;
  late final List<int> requestBytes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    requestBytes =
        await requestStream?.expand<int>((chunk) => chunk).toList() ?? [];
    return response;
  }

  @override
  void close({bool force = false}) {}
}

class _EndpointException implements Exception {
  const _EndpointException(this.uri);

  final Uri uri;
  String get message => 'The resource is unavailable';
}

Dio _client(
  _RecordingAdapter adapter,
  List<String> logs, {
  String baseUrl = 'https://api.example',
  bool maskSensitiveData = true,
  bool? logRequestBody,
  bool errorSnapshots = true,
  List<String> headerBlacklist = const [],
}) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl))
    ..httpClientAdapter = adapter
    ..interceptors.add(
      DioLoggerInterceptor(
        config: DioLoggerConfig(
          level: DioLogLevel.verbose,
          useColors: false,
          printer: logs.add,
          maskSensitiveData: maskSensitiveData,
          logRequestBody: logRequestBody,
          logErrorRequestSnapshot: errorSnapshots,
          logErrorResponseSnapshot: errorSnapshots,
          headerBlacklist: headerBlacklist,
        ),
      ),
    );
  addTearDown(dio.close);
  return dio;
}

void _expectHidden(String log, List<String> markers) {
  expect(markers.where(log.contains), isEmpty, reason: 'visible log markers');
}

void _expectInBodyAndCurl(String requestLog, String text) {
  final curlStart = requestLog.indexOf('curl -X');
  expect(curlStart, greaterThanOrEqualTo(0));
  expect(requestLog.substring(0, curlStart), contains(text));
  expect(requestLog.substring(curlStart), contains(text));
}

void main() {
  test('masks URI credentials and query values through redirects', () async {
    final target = Uri.parse(
      'https://reader:redirect-pass-marker@cache.example/final'
      '?token=redirect-token-marker&note=Bearer%20redirect-value-marker'
      '&tab=details',
    );
    final adapter = _RecordingAdapter(
      ResponseBody.fromString('complete', 200)
        ..redirects = [RedirectRecord(302, 'GET', target)],
    );
    final logs = <String>[];
    final dio = _client(
      adapter,
      logs,
      baseUrl: 'https://reader:base-pass-marker@api.example',
    );

    final response = await dio.get<String>(
      '/events?token=embedded-token-marker&view=compact',
      queryParameters: {
        'note': ['public-note', 'Bearer query-value-marker'],
      },
    );

    final uri = adapter.request.uri;
    expect(uri.userInfo, 'reader:base-pass-marker');
    expect(uri.queryParameters['token'], 'embedded-token-marker');
    expect(uri.queryParametersAll['note'], [
      'public-note',
      'Bearer query-value-marker',
    ]);
    expect(response.realUri, target);
    expect(response.data, 'complete');
    final output = logs.join('\n');
    _expectHidden(output, [
      'base-pass-marker',
      'embedded-token-marker',
      'query-value-marker',
      'redirect-pass-marker',
      'redirect-token-marker',
      'redirect-value-marker',
    ]);
    expect(logs.first, contains('view=compact'));
    expect(logs.first, contains('public-note'));
    expect(logs.last, contains('tab=details'));
  });

  test('masks URI-valued headers and omits blacklisted content type', () async {
    const referrer = 'https://example.test/ref?token=referrer-marker&tab=sent';
    const location = '/result?token=location-marker&tab=received';
    const contentType = 'application/x-marker-type';
    final adapter = _RecordingAdapter(
      ResponseBody.fromString(
        'ok',
        201,
        headers: {
          'location': [location],
          'content-location': [location],
        },
      ),
    );
    final logs = <String>[];
    final dio = _client(adapter, logs, headerBlacklist: ['Content-Type']);

    final response = await dio.post<String>(
      '/submit',
      data: 'sample',
      options: Options(
        contentType: contentType,
        headers: {'referer': referrer},
      ),
    );

    expect(adapter.request.headers['referer'], referrer);
    expect(adapter.request.contentType, contentType);
    expect(response.headers.value('location'), location);
    _expectHidden(logs.join('\n'), [
      'referrer-marker',
      'location-marker',
      contentType,
    ]);
    expect(logs.first, contains('tab=sent'));
    expect(logs.last, contains('tab=received'));
  });

  test('masks individual values before Dio serializes query lists', () async {
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);
    await dio.get<String>(
      '/search',
      queryParameters: {
        'note': ['ordinary', 'Bearer csv-marker'],
        'more': const ListParam([
          'another',
          'Basic wrapped-marker',
        ], ListFormat.multi),
      },
      options: Options(listFormat: ListFormat.csv),
    );
    expect(
      adapter.request.uri.queryParameters['note'],
      'ordinary,Bearer csv-marker',
    );
    expect(adapter.request.uri.queryParametersAll['more'], [
      'another',
      'Basic wrapped-marker',
    ]);
    for (final log in logs) {
      _expectHidden(log, ['csv-marker', 'wrapped-marker']);
      expect(log, contains('ordinary'));
      expect(log, contains('another'));
    }
  });

  test(
    'masks structured query fields that Dio appends after a fragment',
    () async {
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);
      await dio.get<String>(
        '/article#comments',
        queryParameters: {'note': 'Bearer fragment-marker', 'view': 'recent'},
      );
      expect(adapter.request.uri.fragment, contains('fragment-marker'));
      for (final log in logs) {
        _expectHidden(log, ['fragment-marker']);
        expect(log, contains('#comments?'));
        expect(log, contains('view=recent'));
      }
    },
  );

  test('masks named fields inside maps joined into a query value', () async {
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);
    await dio.get<String>(
      '/search',
      queryParameters: {
        'q': [
          {'token': 'nested-field-marker', 'label': 'listed'},
        ],
      },
      options: Options(listFormat: ListFormat.csv),
    );
    expect(
      adapter.request.uri.queryParameters['q'],
      contains('nested-field-marker'),
    );
    for (final log in logs) {
      _expectHidden(log, ['nested-field-marker']);
      expect(log, contains('listed'));
    }
  });

  test(
    'keeps nested CSV field separators from exposing masked values',
    () async {
      for (final separator in ['#', '&', '%26', '=', '?', '+', '%FF']) {
        final inputs = {
          'q': [
            {'password': 'first${separator}private-tail', 'label': 'entry'},
          ],
        };
        final forwarded = RequestOptions(
          path: 'https://cdn.example/search',
          queryParameters: inputs,
          listFormat: ListFormat.csv,
        ).uri;
        final adapter = _RecordingAdapter(
          ResponseBody.fromString(
            'ok',
            200,
            headers: {
              'content-location': [forwarded.toString()],
            },
          )..redirects = [RedirectRecord(302, 'GET', forwarded)],
        );
        final logs = <String>[];
        final dio = _client(adapter, logs);
        final response = await dio.get<String>(
          '/search',
          queryParameters: inputs,
          options: Options(listFormat: ListFormat.csv),
        );
        expect(response.realUri, forwarded);
        expect(adapter.request.queryParameters, inputs);
        expect(logs.first, contains('REQUEST'));
        expect(logs.last, contains('RESPONSE'));
        _expectHidden(logs.join('\n'), ['private-tail']);
      }
    },
  );

  test(
    'masks an outer sensitive query key with ambiguous joined values',
    () async {
      for (final separator in ['#', '&']) {
        final inputs = {
          'token': [
            {'label': 'first${separator}outer-private-tail'},
          ],
        };
        final forwarded = RequestOptions(
          path: 'https://cdn.example/search',
          queryParameters: inputs,
          listFormat: ListFormat.csv,
        ).uri;
        final adapter = _RecordingAdapter(
          ResponseBody.fromString(
            'ok',
            200,
            headers: {
              'location': [forwarded.toString()],
            },
          )..redirects = [RedirectRecord(302, 'GET', forwarded)],
        );
        final logs = <String>[];
        final dio = _client(adapter, logs);
        final response = await dio.get<String>(
          '/search',
          queryParameters: inputs,
          options: Options(listFormat: ListFormat.csv),
        );
        expect(response.realUri, forwarded);
        expect(adapter.request.queryParameters, inputs);
        expect(logs.first, contains('REQUEST'));
        expect(logs.last, contains('RESPONSE'));
        _expectHidden(logs.join('\n'), ['outer-private-tail']);
      }
    },
  );

  for (final status in [200, 429]) {
    test(
      'masks credentials assembled across an SSV list on HTTP $status',
      () async {
        final adapter = _RecordingAdapter(
          ResponseBody.fromString('result', status),
        );
        final logs = <String>[];
        final dio = _client(adapter, logs);
        final request = dio.get<String>(
          '/search',
          queryParameters: {
            'q': ['Bearer', 'assembled-marker', 'Basic other'],
          },
          options: Options(listFormat: ListFormat.ssv),
        );
        if (status == 429) {
          await expectLater(request, throwsA(isA<DioException>()));
        } else {
          await request;
        }
        expect(
          adapter.request.uri.queryParameters['q'],
          contains('Bearer assembled-marker'),
        );
        expect(
          logs.last,
          contains(status == 200 ? 'RESPONSE' : 'Request Snapshot'),
        );
        _expectHidden(logs.join('\n'), ['assembled-marker']);
      },
    );
  }

  test('keeps safe neighbors after a credential in a joined query', () async {
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);
    final values = ['Bearer leading-marker', 'visible-neighbor'];
    await dio.get<String>(
      '/search',
      queryParameters: {
        'q': values,
        'token': ['Bearer secret-marker', 'hidden-neighbor'],
      },
      options: Options(listFormat: ListFormat.csv),
    );
    expect(
      adapter.request.uri.queryParameters['q'],
      'Bearer leading-marker,visible-neighbor',
    );
    expect(
      adapter.request.uri.queryParameters['token'],
      contains('hidden-neighbor'),
    );
    for (final log in logs) {
      _expectHidden(log, [
        'leading-marker',
        'secret-marker',
        'hidden-neighbor',
      ]);
      expect(log, contains('visible-neighbor'));
    }
  });

  test(
    'masks a forwarded joined query in redirect and header diagnostics',
    () async {
      final target = Uri.parse(
        'https://cdn.example/search/?page=1&note=ordinary,Bearer+copied-marker',
      );
      final adapter = _RecordingAdapter(
        ResponseBody.fromString(
          'ok',
          200,
          headers: {
            'content-location': [target.toString()],
          },
        )..redirects = [RedirectRecord(301, 'GET', target)],
      );
      final logs = <String>[];
      final dio = _client(adapter, logs);
      final fields = {
        'note': ['ordinary', 'Bearer copied-marker'],
      };
      final response = await dio.get<String>(
        '/search',
        queryParameters: fields,
        options: Options(listFormat: ListFormat.csv),
      );
      expect(response.realUri, target);
      expect(response.headers.value('content-location'), target.toString());
      final redirected = logs.last;
      _expectHidden(redirected, ['copied-marker']);
      expect(redirected, contains('ordinary'));
      expect(redirected, contains('page=1'));
    },
  );

  test(
    'masks a forwarded joined query in transport error diagnostics',
    () async {
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);
      final fields = {
        'note': ['ordinary', 'Bearer copied-marker'],
      };
      await expectLater(
        dio.get<String>(
          '/search',
          queryParameters: fields,
          options: Options(
            listFormat: ListFormat.csv,
            responseDecoder: (_, options, _) =>
                throw _EndpointException(options.uri),
          ),
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'cause',
            isA<_EndpointException>(),
          ),
        ),
      );
      expect(logs.last, contains('The resource is unavailable'));
      _expectHidden(logs.last, ['copied-marker']);
      expect(logs.last, contains('ordinary'));
    },
  );

  test('handles Uri and iterable request header values', () async {
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);
    final referrer = Uri.parse(
      'https://example.test?q=page&token=typed-uri-marker',
    );
    final labels = {'demo', 'Bearer iterable-marker'};
    await dio.get<String>(
      '/labels',
      options: Options(headers: {'referer': referrer, 'x-labels': labels}),
    );
    expect(adapter.request.headers['referer'], referrer);
    expect(adapter.request.headers['x-labels'], labels);
    _expectHidden(logs.first, ['typed-uri-marker', 'iterable-marker']);
    expect(logs.first, contains('q=page'));
    expect(logs.first, contains('demo'));
  });

  test('retains a decoded JSON string that starts with a bracket', () async {
    const notice = '[notice] delivery complete';
    final adapter = _RecordingAdapter(
      ResponseBody.fromString(
        jsonEncode(notice),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final logs = <String>[];
    final dio = _client(adapter, logs);
    final response = await dio.get<dynamic>('/notice');
    expect(response.data, notice);
    expect(logs.last, contains(notice));
  });

  test('masks encoded JSON consistently in request body and cURL', () async {
    const encoded =
        '{"account":{"password":"json-password-marker"},'
        '"items":[{"note":"Basic json-value-marker"}],"page":"public-json"}';
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);

    await dio.post<String>(
      '/json',
      data: encoded,
      options: Options(contentType: Headers.jsonContentType),
    );

    expect(utf8.decode(adapter.requestBytes), encoded);
    _expectHidden(logs.first, ['json-password-marker', 'json-value-marker']);
    _expectInBodyAndCurl(logs.first, 'public-json');
  });

  test(
    'recognizes JSON strings even when sent with a form content type',
    () async {
      const body = '{"password":"mislabeled-json-marker","item":"public-item"}';
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);

      await dio.post<String>(
        '/legacy',
        data: body,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      expect(utf8.decode(adapter.requestBytes), body);
      _expectHidden(logs.first, ['mislabeled-json-marker']);
      _expectInBodyAndCurl(logs.first, 'public-item');
    },
  );

  test('retains bracketed plain text in logs and cURL', () async {
    const body = '[notice] delivery complete';
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);
    await dio.post<String>(
      '/plain',
      data: body,
      options: Options(contentType: 'text/plain'),
    );
    expect(utf8.decode(adapter.requestBytes), body);
    _expectInBodyAndCurl(logs.first, body);
  });

  test('masks pre-encoded form values and preserves repeated keys', () async {
    const encoded =
        'token=form-token-marker&topic=first-public&topic=second-public'
        '&note=Bearer+form-value-marker';
    final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
    final logs = <String>[];
    final dio = _client(adapter, logs);

    await dio.post<String>(
      '/form',
      data: encoded,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'authorization': 'Bearer request-header-marker'},
      ),
    );

    expect(utf8.decode(adapter.requestBytes), encoded);
    expect(
      adapter.request.headers['authorization'],
      'Bearer request-header-marker',
    );
    _expectHidden(logs.first, [
      'form-token-marker',
      'form-value-marker',
      'request-header-marker',
    ]);
    _expectInBodyAndCurl(logs.first, 'first-public');
    _expectInBodyAndCurl(logs.first, 'second-public');
  });

  for (final mask in [true, false]) {
    test('honors maskSensitiveData=$mask for multipart fields', () async {
      final body = FormData.fromMap({
        'password': 'multipart-key-marker',
        'note': 'Bearer multipart-value-marker',
        'label': 'public-field',
        'attachment': MultipartFile.fromString(
          'file-content-marker',
          filename: 'receipt.txt',
        ),
      });
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs, maskSensitiveData: mask);

      await dio.post<String>('/multipart', data: body);

      final sent = utf8.decode(adapter.requestBytes);
      for (final original in [
        'multipart-key-marker',
        'Bearer multipart-value-marker',
        'file-content-marker',
      ]) {
        expect(sent, contains(original));
      }
      final requestLog = logs.first;
      _expectHidden(requestLog, ['file-content-marker']);
      if (mask) {
        _expectHidden(requestLog, [
          'multipart-key-marker',
          'multipart-value-marker',
        ]);
      } else {
        _expectInBodyAndCurl(requestLog, 'multipart-key-marker');
        _expectInBodyAndCurl(requestLog, 'Bearer multipart-value-marker');
      }
      _expectInBodyAndCurl(requestLog, 'public-field');
      _expectInBodyAndCurl(requestLog, 'receipt.txt');
    });
  }

  for (final status in [200, 429]) {
    test(
      'applies header rules to every response section on HTTP $status',
      () async {
        final adapter = _RecordingAdapter(
          ResponseBody.fromString(
            'response-text',
            status,
            headers: {
              'x-review': ['public-header-value', 'Bearer mixed-header-marker'],
              'x-private-header': ['blacklisted-header-marker'],
              'x-ratelimit-limit': ['blacklisted-rate-marker'],
              'x-ratelimit-remaining': ['7', 'Basic remaining-value-marker'],
              'retry-after': ['12'],
            },
          ),
        );
        final logs = <String>[];
        final dio = _client(
          adapter,
          logs,
          headerBlacklist: ['X-Private-Header', 'X-RateLimit-Limit'],
        );

        final request = dio.get<String>('/headers');
        Response<dynamic>? response;
        try {
          response = await request;
          expect(status, 200);
        } on DioException catch (error) {
          expect(status, 429);
          expect(error.type, DioExceptionType.badResponse);
          response = error.response;
        }
        expect(response?.data, 'response-text');
        expect(response?.headers['x-review'], [
          'public-header-value',
          'Bearer mixed-header-marker',
        ]);
        expect(
          response?.headers.value('x-ratelimit-limit'),
          'blacklisted-rate-marker',
        );
        final log = logs.last;
        expect(log, contains(status == 200 ? 'RESPONSE' : 'Response Snapshot'));
        expect(log, contains('Rate Limit'));
        _expectHidden(log.toLowerCase(), [
          'x-private-header',
          'blacklisted-header-marker',
          'x-ratelimit-limit',
          'blacklisted-rate-marker',
          'mixed-header-marker',
          'remaining-value-marker',
        ]);
        expect(log, contains('public-header-value'));
        expect(log, contains('retry-after: 12'));
      },
    );
  }

  test(
    'passes upload and response streams through to their consumers',
    () async {
      final adapter = _RecordingAdapter(
        ResponseBody.fromBytes(utf8.encode('download-stream-marker'), 200),
      );
      final logs = <String>[];
      final dio = _client(adapter, logs);
      final upload = Stream<List<int>>.value(
        utf8.encode('upload-stream-marker'),
      );

      final response = await dio.post<ResponseBody>(
        '/stream',
        data: upload,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.stream,
        ),
      );

      expect(utf8.decode(adapter.requestBytes), 'upload-stream-marker');
      final downloaded = await response.data!.stream
          .expand<int>((chunk) => chunk)
          .toList();
      expect(utf8.decode(downloaded), 'download-stream-marker');
      expect(logs.first, contains('Stream'));
      expect(logs.last, contains('Stream'));
      _expectHidden(logs.join('\n'), [
        'upload-stream-marker',
        'download-stream-marker',
      ]);
    },
  );

  group('payload and diagnostic contracts', () {
    test('renders an application/json List<int> as an array', () async {
      const numbers = [300, 1025, -9];
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);

      await dio.post<String>(
        '/numbers',
        data: numbers,
        options: Options(contentType: Headers.jsonContentType),
      );

      expect(jsonDecode(utf8.decode(adapter.requestBytes)), numbers);
      final array = RegExp(r'\[\s*300,\s*1025,\s*-9\s*\]');
      final request = logs.first.split('curl -X');
      expect(request, hasLength(2));
      expect(request.first, matches(array));
      expect(request.last, matches(array));
    });

    test('renders typed numeric arrays that Dio sends as JSON', () async {
      final numbers = Int32List.fromList([300, 1025, -9]);
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);
      await dio.post<String>(
        '/typed',
        data: numbers,
        options: Options(contentType: Headers.jsonContentType),
      );
      expect(jsonDecode(utf8.decode(adapter.requestBytes)), numbers);
      _expectInBodyAndCurl(logs.first, '1025');
    });

    test('previews typed upload bytes and response bytes', () async {
      final adapter = _RecordingAdapter(
        ResponseBody.fromBytes([0xaa, 0xbb], 200),
      );
      final logs = <String>[];
      final dio = _client(adapter, logs);

      final response = await dio.post<List<int>>(
        '/bytes',
        data: Uint8List.fromList([0xfe, 0xff]),
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.bytes,
        ),
      );

      expect(adapter.requestBytes, [0xfe, 0xff]);
      expect(response.data, [0xaa, 0xbb]);
      expect(logs.first, contains('Preview: fe ff'));
      expect(logs.last, contains('Preview: aa bb'));
      expect(logs.first, isNot(contains('--data-raw')));
    });

    test(
      'keeps the URL in the cURL command when its body is omitted',
      () async {
        final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
        final logs = <String>[];
        final dio = _client(adapter, logs, logRequestBody: false);
        await dio.post<String>('/notes', data: 'omitted-body-marker');

        expect(utf8.decode(adapter.requestBytes), 'omitted-body-marker');
        final curl = logs.first.substring(logs.first.indexOf('curl -X'));
        // Join continued lines and inspect only the command before any comment.
        final command = curl
            .replaceAll('\\\n', ' ')
            .split('\n')
            .first
            .split(' #')
            .first;
        expect(command, contains('https://api.example/notes'));
        expect(command, isNot(contains('--data-raw')));
        _expectHidden(logs.first, ['omitted-body-marker']);
      },
    );

    test('quotes an apostrophe in a URL used by cURL', () async {
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);
      await dio.get<String>("/authors/O'Brien");

      expect(adapter.request.uri.pathSegments.last, "O'Brien");
      final curl = logs.first.substring(logs.first.indexOf('curl -X'));
      expect(curl, contains(r"'https://api.example/authors/O'\''Brien'"));
    });

    test(
      'keeps a decoder source out of errors when snapshots are disabled',
      () async {
        const payload = 'opaque-response-marker';
        final adapter = _RecordingAdapter(
          ResponseBody.fromString(payload, 200),
        );
        final logs = <String>[];
        final dio = _client(adapter, logs, errorSnapshots: false);
        final request = dio.get<String>(
          '/decode',
          options: Options(
            responseDecoder: (bytes, _, _) => throw FormatException(
              'Unrecognized record',
              utf8.decode(bytes),
            ),
          ),
        );

        await expectLater(
          request,
          throwsA(
            isA<DioException>().having(
              (exception) => exception.error,
              'underlying error',
              isA<FormatException>().having(
                (error) => error.source,
                'source',
                payload,
              ),
            ),
          ),
        );
        expect(logs.last, contains('FormatException'));
        _expectHidden(logs.last, [payload]);
      },
    );

    test('masks a structured URI on an underlying error', () async {
      final error = _EndpointException(
        Uri.parse(
          'https://upstream.example/report?token=diagnostic-token-marker&view=public',
        ),
      );
      final adapter = _RecordingAdapter(ResponseBody.fromString('ok', 200));
      final logs = <String>[];
      final dio = _client(adapter, logs);
      final request = dio.get<String>(
        '/lookup',
        options: Options(responseDecoder: (_, _, _) => throw error),
      );

      await expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (exception) => exception.error,
            'underlying error',
            same(error),
          ),
        ),
      );
      expect(error.uri.queryParameters['token'], 'diagnostic-token-marker');
      expect(logs.last, contains('upstream.example/report'));
      expect(logs.last, contains('view=public'));
      _expectHidden(logs.last, ['diagnostic-token-marker']);
    });
  });
}
