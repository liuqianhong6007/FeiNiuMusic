import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/library_scan_service.dart';
import 'package:feiniu_music/app/services/music_dl/music_dl_service.dart';
import 'package:feiniu_music/app/state/settings_music_dl_state.dart';

/// 一条按路径作答的响应（这些用例都返回 200 + JSON）。
class _Route {
  const _Route(this.body);

  final String body;
}

class _Recorder implements HttpClientAdapter {
  _Recorder(this.routes);

  final Map<String, _Route> routes;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final route =
        routes[options.uri.path] ??
        const _Route('{"code":0,"msg":"","data":{}}');
    return ResponseBody.fromString(
      route.body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_Recorder recorder) {
  final dio = Dio(
    BaseOptions(
      validateStatus: (_) => true,
      followRedirects: false,
      headers: const {'Accept': 'application/json'},
    ),
  );
  dio.httpClientAdapter = recorder;
  return dio;
}

/// 模拟 `/api/search` 返回的一首歌，`extra` 携带平台特有的取流参数。
const String _searchJson = '''
{
  "keyword": "晴天", "search_type": "song", "sources": ["kugou"],
  "page": 1, "page_size": 30, "total": 1, "total_pages": 1,
  "songs": [
    {
      "id": "B3A52A7A958BF0AED0EBFBA2E9A818B7",
      "source": "kugou",
      "name": "晴天",
      "artist": "周杰伦",
      "album": "叶惠美",
      "album_id": "966846",
      "duration": 269,
      "cover": "https://cdn.example/cover.jpg",
      "extra": {"hash": "H1", "privilege": "10"}
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppMusicDlSettings.resetForTest();
  });

  test('闭环客户端链路：搜索 → 下载到 NAS → 触发曲库扫描', () async {
    // 两个客户端各自有独立的 Dio 与 base path，因此分别注入录制器。
    final musicDl = _Recorder({
      '/music/api/search': const _Route(_searchJson),
      '/music/download': const _Route(
        '{"status":"ok","saved":true,'
        '"path":"/vol1/1000/音乐/周杰伦 - 晴天.flac",'
        '"filename":"周杰伦 - 晴天.flac","skipped":false}',
      ),
    });
    final feiNiu = _Recorder({
      '/music/api/v1/shared-library/scan-all': const _Route(
        '{"code":0,"msg":"","data":{}}',
      ),
      '/music/api/v1/task/list': const _Route(
        '{"code":0,"msg":"","data":{"list":['
        '{"type":"fileScan","done":true,"ext":{"libraryGUID":"g1"}}]}}',
      ),
    });

    MusicDlService.instance.setDioForTest(_dioWith(musicDl));
    FeiNiuApiClient.instance.setDioForTest(_dioWith(feiNiu));
    await AppMusicDlSettings.setBaseUrl('http://nas:8080');
    await FeiNiuApiClient.instance.setBaseUrl('http://nas:5666');

    // ---- 1. 搜索 ----
    final result = await MusicDlService.instance.searchSongs('晴天');
    expect(result.songs, hasLength(1));
    final song = result.songs.single;
    expect(song.id, 'B3A52A7A958BF0AED0EBFBA2E9A818B7');
    expect(song.source, 'kugou');

    // ---- 2. 下载到 NAS ----
    final saved = await MusicDlService.instance.saveToServer(song);
    expect(saved.saved, isTrue);
    expect(saved.skipped, isFalse);
    expect(saved.filename, '周杰伦 - 晴天.flac');

    final downloadRequest = musicDl.requests.firstWhere(
      (r) => r.uri.path == '/music/download',
    );
    expect(downloadRequest.method, 'POST');
    expect(downloadRequest.queryParameters['save_local'], '1');
    expect(downloadRequest.queryParameters['id'], song.id);
    expect(downloadRequest.queryParameters['source'], 'kugou');
    expect(downloadRequest.queryParameters['name'], '晴天');
    expect(downloadRequest.queryParameters['album'], '叶惠美');
    expect(downloadRequest.queryParameters['duration'], '269');
    // 服务端口令写入要求这个头，缺了会 403/405。
    expect(downloadRequest.headers['X-Requested-With'], 'XMLHttpRequest');

    // 关键接缝：搜索拿到的 extra 必须能被下载接口原样解析回同一个对象。
    // 若这里编码/转义错了，服务端会因为拿不到平台取流参数而下载失败。
    final extraRaw = downloadRequest.queryParameters['extra'];
    expect(extraRaw, isA<String>());
    expect(jsonDecode(extraRaw as String), {'hash': 'H1', 'privilege': '10'});

    // ---- 3. 触发飞牛音乐曲库扫描 ----
    final scanOk = await FeiNiuLibraryScanService.instance.scanAndWait(
      timeout: const Duration(milliseconds: 200),
      interval: const Duration(milliseconds: 10),
    );
    expect(scanOk, isTrue);

    // 扫描打在飞牛音乐 API 上，而不是 go-music-dl 上——两者是不同服务。
    expect(
      feiNiu.requests.map((r) => r.uri.path),
      containsAll(<String>[
        '/music/api/v1/shared-library/scan-all',
        '/music/api/v1/task/list',
      ]),
    );
    expect(
      musicDl.requests.any((r) => r.uri.path.contains('shared-library')),
      isFalse,
    );
  });

  test('扫描失败不影响「下载已成功」的结论', () async {
    final musicDl = _Recorder({
      '/music/api/search': const _Route(_searchJson),
      '/music/download': const _Route(
        '{"status":"ok","saved":true,"path":"/x/y.flac","filename":"y.flac","skipped":false}',
      ),
    });
    // 扫描接口返回未公开/不支持：模拟官方接口变动。
    final feiNiu = _Recorder({
      '/music/api/v1/shared-library/scan-all': const _Route(
        '{"code":1,"msg":"not supported"}',
      ),
    });

    MusicDlService.instance.setDioForTest(_dioWith(musicDl));
    FeiNiuApiClient.instance.setDioForTest(_dioWith(feiNiu));
    await AppMusicDlSettings.setBaseUrl('http://nas:8080');
    await FeiNiuApiClient.instance.setBaseUrl('http://nas:5666');

    final song = (await MusicDlService.instance.searchSongs('晴天')).songs.single;
    final saved = await MusicDlService.instance.saveToServer(song);
    expect(saved.saved, isTrue);

    final scanOk = await FeiNiuLibraryScanService.instance.scanAndWait(
      timeout: const Duration(milliseconds: 100),
      interval: const Duration(milliseconds: 10),
    );
    // 扫描加速失败 → 走「官方稍后自动收录」提示，而不是把下载报成失败。
    expect(scanOk, isFalse);
    expect(saved.saved, isTrue);
  });
}
