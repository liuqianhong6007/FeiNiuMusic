import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/library_scan_service.dart';

/// 一条预设响应（状态码固定 200，这些用例只关心响应体与 content-type）。
class _FakeResponse {
  const _FakeResponse(this.body, {this.contentType = 'application/json'});

  final String body;
  final String contentType;
}

/// 按路径作答的 Dio 适配器；[throwPaths] 上的路径直接抛网络异常，
/// 用来模拟「读不到任务列表」这类降级分支。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.routes = const {}, this.throwPaths = const {}});

  final Map<String, _FakeResponse> routes;
  final Set<String> throwPaths;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);

    if (throwPaths.contains(options.uri.path)) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }

    final response =
        routes[options.uri.path] ??
        const _FakeResponse('{"code":0,"msg":"","data":{}}');
    return ResponseBody.fromString(
      response.body,
      200,
      headers: {
        Headers.contentTypeHeader: [response.contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const String _listIndex = '/music/api/v1/shared-library/list';
const String _scanAll = '/music/api/v1/shared-library/scan-all';
const String _scanOne = '/music/api/v1/shared-library/scan';
const String _taskList = '/music/api/v1/task/list';

void _installAdapter(_FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(validateStatus: (_) => true, followRedirects: false),
  );
  dio.httpClientAdapter = adapter;
  FeiNiuApiClient.instance.setDioForTest(dio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await FeiNiuApiClient.instance.setBaseUrl('http://nas:5666');
  });

  group('FeiNiuApiClient 曲库接口', () {
    test('getSharedLibraryList 解析 data.list', () async {
      final adapter = _FakeAdapter(
        routes: {
          _listIndex: const _FakeResponse(
            '{"code":0,"msg":"","data":{"list":['
            '{"guid":"g1","path":"/vol1/1000/音乐","name":"音乐"},'
            '{"guid":"g2","path":"/vol2/music","name":"Music"}'
            ']}}',
          ),
        },
      );
      _installAdapter(adapter);

      final libraries = await FeiNiuApiClient.instance.getSharedLibraryList();

      expect(libraries, hasLength(2));
      expect(libraries.first.guid, 'g1');
      expect(libraries.first.path, '/vol1/1000/音乐');
      expect(libraries.first.name, '音乐');

      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, _listIndex);
    });

    test('scanSharedLibrary 不传 guid 时走 scan-all', () async {
      final adapter = _FakeAdapter();
      _installAdapter(adapter);

      await FeiNiuApiClient.instance.scanSharedLibrary();

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, _scanAll);
    });

    test('scanSharedLibrary 传 guid 时走 scan 并带上 guid', () async {
      final adapter = _FakeAdapter();
      _installAdapter(adapter);

      await FeiNiuApiClient.instance.scanSharedLibrary(guid: 'g1');

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, _scanOne);
      expect(request.data, {'guid': 'g1'});
    });

    test('scanSharedLibrary 在服务端返回失败码时抛错', () async {
      final adapter = _FakeAdapter(
        routes: {_scanAll: const _FakeResponse('{"code":1,"msg":"不支持该操作"}')},
      );
      _installAdapter(adapter);

      await expectLater(
        FeiNiuApiClient.instance.scanSharedLibrary(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'toString',
            contains('不支持该操作'),
          ),
        ),
      );
    });

    test('getTaskList 解析 data.list 并忽略非对象条目', () async {
      final adapter = _FakeAdapter(
        routes: {
          _taskList: const _FakeResponse(
            '{"code":0,"msg":"","data":{"list":['
            '{"type":"fileScan","done":false,"ext":{"libraryGUID":"g1"}},'
            '"噪音",'
            '{"type":"other","done":true}'
            ']}}',
          ),
        },
      );
      _installAdapter(adapter);

      final tasks = await FeiNiuApiClient.instance.getTaskList();

      expect(tasks, hasLength(2));
      expect(tasks.first['type'], 'fileScan');
      expect(tasks.first['done'], isFalse);
    });

    test('getTaskList 返回 HTML 登录页时降级为空列表', () async {
      // 真实场景：未登录时服务端渲染 HTML 登录页，content-type 是 text/html，
      // Dio 不会去解析 JSON，_get 拿到的不是 Map，于是返回空列表。
      final adapter = _FakeAdapter(
        routes: {
          _taskList: const _FakeResponse(
            '<html>请先登录</html>',
            contentType: 'text/html; charset=utf-8',
          ),
        },
      );
      _installAdapter(adapter);

      expect(await FeiNiuApiClient.instance.getTaskList(), isEmpty);
    });

    test('getTaskList 遇到 content-type 与内容不符时抛错，但整条流程仍降级', () async {
      // 反向代理把 HTML 错误页标成 application/json：Dio 解析失败抛 DioException。
      // 固化该行为，并确认降级责任落在调用方（_safeTaskList）。
      final adapter = _FakeAdapter(
        routes: {_taskList: const _FakeResponse('<html>bad gateway</html>')},
      );
      _installAdapter(adapter);

      await expectLater(
        FeiNiuApiClient.instance.getTaskList(),
        throwsA(isA<DioException>()),
      );
      expect(
        await FeiNiuLibraryScanService.instance.scanAndWait(
          timeout: const Duration(milliseconds: 200),
          interval: const Duration(milliseconds: 10),
        ),
        isTrue,
      );
    });
  });

  group('FeiNiuLibraryScanService.scanAndWait', () {
    test('没有 fileScan 任务时返回 true', () async {
      final adapter = _FakeAdapter(
        routes: {
          _taskList: const _FakeResponse(
            '{"code":0,"msg":"","data":{"list":[{"type":"other","done":false}]}}',
          ),
        },
      );
      _installAdapter(adapter);

      final ok = await FeiNiuLibraryScanService.instance.scanAndWait(
        timeout: const Duration(milliseconds: 200),
        interval: const Duration(milliseconds: 10),
      );

      expect(ok, isTrue);
      // 触发了扫描，并轮询过任务列表
      expect(adapter.requests.first.uri.path, _scanAll);
      expect(adapter.requests.map((r) => r.uri.path), contains(_taskList));
    });

    test('fileScan 已完成时返回 true', () async {
      final adapter = _FakeAdapter(
        routes: {
          _taskList: const _FakeResponse(
            '{"code":0,"msg":"","data":{"list":['
            '{"type":"fileScan","done":true,"ext":{"libraryGUID":"g1"}}]}}',
          ),
        },
      );
      _installAdapter(adapter);

      expect(
        await FeiNiuLibraryScanService.instance.scanAndWait(
          timeout: const Duration(milliseconds: 200),
          interval: const Duration(milliseconds: 10),
        ),
        isTrue,
      );
    });

    test('扫描接口不可用时降级返回 false（不得当作下载失败）', () async {
      final adapter = _FakeAdapter(
        routes: {_scanAll: const _FakeResponse('{"code":1,"msg":"不支持"}')},
      );
      _installAdapter(adapter);

      final ok = await FeiNiuLibraryScanService.instance.scanAndWait(
        timeout: const Duration(milliseconds: 200),
        interval: const Duration(milliseconds: 10),
      );

      expect(ok, isFalse);
      // 扫描都没触发成功，不应再去轮询任务列表
      expect(
        adapter.requests.map((r) => r.uri.path),
        isNot(contains(_taskList)),
      );
    });

    test('读不到任务列表时按「官方会自动扫描」返回 true', () async {
      final adapter = _FakeAdapter(throwPaths: {_taskList});
      _installAdapter(adapter);

      final ok = await FeiNiuLibraryScanService.instance.scanAndWait(
        timeout: const Duration(milliseconds: 200),
        interval: const Duration(milliseconds: 10),
      );

      expect(ok, isTrue);
    });

    test('任务一直未完成时超时返回 false', () async {
      final adapter = _FakeAdapter(
        routes: {
          _taskList: const _FakeResponse(
            '{"code":0,"msg":"","data":{"list":['
            '{"type":"fileScan","done":false,"ext":{"libraryGUID":"g1"}}]}}',
          ),
        },
      );
      _installAdapter(adapter);

      final ok = await FeiNiuLibraryScanService.instance.scanAndWait(
        timeout: const Duration(milliseconds: 60),
        interval: const Duration(milliseconds: 10),
      );

      expect(ok, isFalse);
      // 确实轮询了多次，而不是一次就放弃
      final polls = adapter.requests
          .where((r) => r.uri.path == _taskList)
          .length;
      expect(polls, greaterThan(1));
    });
  });
}
