import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/music_dl/music_dl_service.dart';
import 'package:feiniu_music/app/state/settings_music_dl_state.dart';

/// 一条预设响应。
class _FakeResponse {
  const _FakeResponse(
    this.body, {
    this.statusCode = 200,
    this.contentType = 'application/json',
  });

  final String body;
  final int statusCode;
  final String contentType;
}

/// 记录请求并按路径作答的 Dio 适配器。
///
/// 搜索会先请求 `/music/api/search`，未命中 [routes] 时返回一个空的 200 HTML
/// 响应；这样才能分别模拟「新服务端有 JSON 接口」与「旧服务端 404 回退 HTML」。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.responseHeaders = const {}, this.routes = const {}});

  final Map<String, List<String>> responseHeaders;
  final Map<String, _FakeResponse> routes;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);

    final response =
        routes[options.uri.path] ??
        const _FakeResponse('', contentType: 'text/html; charset=utf-8');
    return ResponseBody.fromString(
      response.body,
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: [response.contentType],
        // 响应头在两条分支上都要带上（例如登录的 set-cookie）。
        ...responseHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      validateStatus: (_) => true,
      followRedirects: false,
      headers: const {'Accept': 'application/json'},
    ),
  );
  dio.httpClientAdapter = adapter;
  return dio;
}

/// 与 `GET /api/search` 实际返回结构一致的样例。
const String _searchJson = '''
{
  "keyword": "晴天",
  "search_type": "song",
  "sources": ["kugou"],
  "page": 2,
  "page_size": 3,
  "total": 72,
  "total_pages": 24,
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
      "extra": {"hash": "B3A5", "privilege": "10"}
    },
    {
      "id": "456",
      "source": "qq",
      "name": "夜曲",
      "artist": "周杰伦",
      "album": "十一月的萧邦",
      "duration": 0
    },
    {"name": "缺少 id 与 source，应被忽略"}
  ]
}
''';

/// 与 go-music-dl 的 song_list.html 结构一致的最小样例。
const String _searchHtml = '''
<div class="batch-toolbar" id="batch-toolbar" data-current-page="2"
     data-total-pages="3" data-total-count="42" data-page-size="30"></div>
<span class="result-count"><i class="fa"></i> 找到 <span class="count">42</span> 首歌曲</span>
<ul class="result-list">
  <li class="song-card"
      data-id="123" data-source="netease" data-album-id="al1" data-album="叶惠美"
      data-duration="269" data-name="晴天" data-artist="周杰伦"
      data-cover="https://cdn.example/cover.jpg"
      data-extra='{"size":"10.2 MB","bitrate":"320 kbps"}'>
    <div class="song-info"><h3>晴天</h3></div>
  </li>
  <li class="song-card" data-id="456" data-source="qq"
      data-name="夜曲" data-artist="周杰伦" data-extra='{}'></li>
  <li class="song-card" data-name="缺少 id 与 source，应被忽略"></li>
</ul>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppMusicDlSettings.resetForTest();
  });

  group('AppMusicDlSettings.normalizeBaseUrl', () {
    test('未写协议时补 http，未写路径时补默认 /music', () {
      expect(
        AppMusicDlSettings.normalizeBaseUrl('192.168.1.10:8080'),
        'http://192.168.1.10:8080/music',
      );
    });

    test('保留已有 base path 并去掉结尾斜杠', () {
      expect(
        AppMusicDlSettings.normalizeBaseUrl('https://music.example.com/music'),
        'https://music.example.com/music',
      );
      expect(
        AppMusicDlSettings.normalizeBaseUrl('https://music.example.com/dl/'),
        'https://music.example.com/dl',
      );
    });

    test('根路径替换为默认 base path', () {
      expect(
        AppMusicDlSettings.normalizeBaseUrl('http://nas:8080/'),
        'http://nas:8080/music',
      );
    });

    test('空输入与非法输入返回空串', () {
      expect(AppMusicDlSettings.normalizeBaseUrl('   '), '');
      expect(AppMusicDlSettings.normalizeBaseUrl('http://'), '');
    });

    test('不产生多余的问号', () {
      expect(
        AppMusicDlSettings.normalizeBaseUrl('http://nas:8080/music?a=1'),
        isNot(contains('?')),
      );
    });
  });

  group('MusicDlService.searchSongs（JSON 接口）', () {
    test('页码与每页条数传给服务端（「加载更多」依赖它）', () async {
      final adapter = _FakeAdapter(
        routes: {'/music/api/search': const _FakeResponse(_searchJson)},
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      await MusicDlService.instance.searchSongs('x', page: 3, pageSize: 50);

      final params = adapter.requests.single.queryParameters;
      expect(params['page'], 3);
      expect(params['page_size'], 50);
    });

    test('解析 songs 与分页字段', () async {
      final adapter = _FakeAdapter(
        routes: {'/music/api/search': const _FakeResponse(_searchJson)},
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      final result = await MusicDlService.instance.searchSongs('晴天');

      expect(result.songs, hasLength(2));
      expect(result.total, 72);
      expect(result.totalPages, 24);
      expect(result.page, 2);
      expect(result.hasMore, isTrue);

      final first = result.songs.first;
      expect(first.id, 'B3A52A7A958BF0AED0EBFBA2E9A818B7');
      expect(first.source, 'kugou');
      expect(first.name, '晴天');
      expect(first.artist, '周杰伦');
      expect(first.album, '叶惠美');
      expect(first.albumId, '966846');
      expect(first.cover, 'https://cdn.example/cover.jpg');
      // 服务端返回的是秒（int），客户端统一当字符串传给下载接口。
      expect(first.duration, '269');

      // extra 必须被重编码成 JSON 字符串，与 HTML 路径保持同一下游契约。
      final extra = jsonDecode(first.extra) as Map<String, dynamic>;
      expect(extra['hash'], 'B3A5');

      // 没有 extra 的歌不应产生空对象字符串。
      expect(result.songs[1].extra, isEmpty);

      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/music/api/search');
      expect(request.queryParameters['q'], '晴天');
      expect(request.queryParameters['type'], 'song');
    });

    test('旧服务端 404 时回退解析 HTML', () async {
      final adapter = _FakeAdapter(
        routes: {
          '/music/api/search': const _FakeResponse('', statusCode: 404),
          '/music/search': const _FakeResponse(
            _searchHtml,
            contentType: 'text/html; charset=utf-8',
          ),
        },
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      final result = await MusicDlService.instance.searchSongs('周杰伦');

      expect(result.songs, hasLength(2));
      expect(result.total, 42);
      expect(result.totalPages, 3);
      expect(result.songs.first.name, '晴天');

      expect(adapter.requests.map((r) => r.uri.path), [
        '/music/api/search',
        '/music/search',
      ]);
    });

    test('空关键词不发任何请求', () async {
      final adapter = _FakeAdapter(
        routes: {'/music/api/search': const _FakeResponse(_searchJson)},
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      final result = await MusicDlService.instance.searchSongs('   ');

      expect(result.songs, isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('401 时抛出 needsLogin 并清掉会话', () async {
      final adapter = _FakeAdapter(
        routes: {
          '/music/api/search': const _FakeResponse(
            '{"error":"请先登录"}',
            statusCode: 401,
          ),
        },
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');
      await AppMusicDlSettings.setSession('stale-session');

      await expectLater(
        MusicDlService.instance.searchSongs('test'),
        // needsLogin 让页面能弹出登录框并重试，而不是只显示一个错误态。
        throwsA(
          isA<MusicDlException>().having(
            (e) => e.needsLogin,
            'needsLogin',
            isTrue,
          ),
        ),
      );
      expect(AppMusicDlSettings.hasSession.value, isFalse);
      // 鉴权失败不能静默回退到 HTML，否则登录流程会被跳过。
      expect(adapter.requests, hasLength(1));
    });

    test('302 跳登录页同样标记 needsLogin', () async {
      final adapter = _FakeAdapter(
        routes: {'/music/api/search': const _FakeResponse('', statusCode: 302)},
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      await expectLater(
        MusicDlService.instance.searchSongs('test'),
        throwsA(
          isA<MusicDlException>().having(
            (e) => e.needsLogin,
            'needsLogin',
            isTrue,
          ),
        ),
      );
    });

    test('未配置地址时的错误不应被当成需要登录', () async {
      MusicDlService.instance.setDioForTest(_dioWith(_FakeAdapter()));
      // 不调用 setBaseUrl，baseUrl 为空。

      await expectLater(
        MusicDlService.instance.searchSongs('test'),
        throwsA(
          isA<MusicDlException>().having(
            (e) => e.needsLogin,
            'needsLogin',
            isFalse,
          ),
        ),
      );
    });
  });

  group('MusicDlService.saveToServer', () {
    test('用 POST + save_local=1 + 同源写保护头保存到服务端', () async {
      final adapter = _FakeAdapter(
        routes: {
          '/music/download': const _FakeResponse(
            '{"status":"ok","saved":true,"path":"/vol1/music/a.flac","filename":"a.flac","skipped":false}',
          ),
        },
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      const song = MusicDlSong(
        id: '123',
        source: 'netease',
        name: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        albumId: 'al1',
        cover: '',
        duration: '269',
        extra: '{"size":"10.2 MB"}',
      );
      final result = await MusicDlService.instance.saveToServer(song);

      expect(result.saved, isTrue);
      expect(result.skipped, isFalse);
      expect(result.filename, 'a.flac');

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/music/download');
      expect(request.queryParameters['save_local'], '1');
      expect(request.queryParameters['id'], '123');
      expect(request.queryParameters['source'], 'netease');
      // 服务端的同源写保护要求这个头，缺了会返回 forbidden。
      expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
    });

    test('服务端返回 error 时抛出可读错误', () async {
      final adapter = _FakeAdapter(
        routes: {
          '/music/download': const _FakeResponse(
            '{"error":"save_local requires POST"}',
            statusCode: 405,
          ),
        },
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      const song = MusicDlSong(
        id: '1',
        source: 'qq',
        name: 'x',
        artist: 'y',
        album: '',
        albumId: '',
        cover: '',
        duration: '',
        extra: '',
      );
      await expectLater(
        MusicDlService.instance.saveToServer(song),
        throwsA(
          isA<MusicDlException>().having(
            (e) => e.message,
            'message',
            contains('save_local requires POST'),
          ),
        ),
      );
    });
  });

  group('MusicDlService.login', () {
    test('从 Set-Cookie 提取会话并保存', () async {
      final adapter = _FakeAdapter(
        routes: {
          '/music/login': const _FakeResponse(
            '',
            statusCode: 302,
            contentType: 'text/html',
          ),
        },
        responseHeaders: {
          'set-cookie': [
            'music_dl_session=abc123; Path=/music; HttpOnly; SameSite=Lax',
          ],
        },
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      await MusicDlService.instance.login(username: 'admin', password: 'pw');

      expect(AppMusicDlSettings.session, 'abc123');
      expect(AppMusicDlSettings.hasSession.value, isTrue);
      expect(AppMusicDlSettings.username.value, 'admin');
      expect(adapter.requests.single.uri.path, '/music/login');
    });

    test('没有下发 Cookie 时提示凭据错误', () async {
      final adapter = _FakeAdapter(
        routes: {
          '/music/login': const _FakeResponse(
            'login page',
            contentType: 'text/html',
          ),
        },
      );
      MusicDlService.instance.setDioForTest(_dioWith(adapter));
      await AppMusicDlSettings.setBaseUrl('http://nas:8080');

      await expectLater(
        MusicDlService.instance.login(username: 'admin', password: 'bad'),
        throwsA(isA<MusicDlException>()),
      );
      expect(AppMusicDlSettings.hasSession.value, isFalse);
    });
  });

  group('MusicDlSong.key / mergeMusicDlSongs', () {
    MusicDlSong song(String source, String id) => MusicDlSong(
      id: id,
      source: source,
      name: 'n$id',
      artist: 'a',
      album: '',
      albumId: '',
      cover: '',
      duration: '',
      extra: '',
    );

    test('key 由来源与平台内 id 组成，跨平台同名不算重复', () {
      expect(song('kugou', '1').key, 'kugou:1');
      expect(song('qq', '1').key, 'qq:1');
      expect(song('kugou', '1').key == song('qq', '1').key, isFalse);
    });

    test('追加新页时按 key 去重并保持顺序', () {
      final page1 = [song('kugou', '1'), song('qq', '2')];
      // 第 2 页里 'kugou:1' 重复出现（各平台结果会变动），应被丢弃。
      final page2 = [song('kugou', '1'), song('netease', '3')];

      final merged = mergeMusicDlSongs(page1, page2);

      expect(merged.map((s) => s.key).toList(), [
        'kugou:1',
        'qq:2',
        'netease:3',
      ]);
    });

    test('合并保留已有对象的顺序，不受新页顺序影响', () {
      final existing = [song('a', '1'), song('b', '2')];
      final incoming = [song('c', '3'), song('a', '1')];

      final merged = mergeMusicDlSongs(existing, incoming);

      expect(merged.map((s) => s.key).toList(), ['a:1', 'b:2', 'c:3']);
    });

    test('空页合并不影响已有结果', () {
      final existing = [song('a', '1')];
      expect(mergeMusicDlSongs(existing, const []).length, 1);
      expect(mergeMusicDlSongs(const [], existing).length, 1);
      expect(mergeMusicDlSongs(const [], const []), isEmpty);
    });
  });
}
