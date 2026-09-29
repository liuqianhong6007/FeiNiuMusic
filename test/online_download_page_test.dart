import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/music_dl/music_dl_service.dart';
import 'package:feiniu_music/app/state/settings_music_dl_state.dart';
import 'package:feiniu_music/pages/online/online_download_page.dart';

/// 按 `page` 查询参数返回不同页的适配器。
class _PagedAdapter implements HttpClientAdapter {
  _PagedAdapter(this.pages);

  final Map<int, String> pages;
  final List<int> requestedPages = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = int.tryParse('${options.queryParameters['page'] ?? 1}') ?? 1;
    requestedPages.add(page);
    final body = pages[page] ?? _pageJson(page: page, songs: const []);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _song(String id) => {
  'id': id,
  'source': 'kugou',
  'name': '歌$id',
  'artist': '歌手',
  'album': '',
  'duration': 200,
  'cover': '',
  'extra': {'hash': id},
};

String _pageJson({
  required int page,
  required List<Map<String, dynamic>> songs,
  int total = 0,
  int totalPages = 1,
}) {
  return jsonEncode({
    'keyword': 'x',
    'search_type': 'song',
    'sources': ['kugou'],
    'page': page,
    'page_size': 30,
    'total': total,
    'total_pages': totalPages,
    'songs': songs,
  });
}

/// 推进若干帧。
///
/// 不能用 `pumpAndSettle`：页面外壳带有常驻动画（渐变背景），永远到不了静止，
/// 会直接超时。异步的搜索/翻页在微任务里完成，多推几帧就够了。
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'music_dl_enabled': true,
      'music_dl_base_url': 'http://nas:8080/music',
    });
    AppMusicDlSettings.resetForTest();
  });

  testWidgets('搜索 → 显示结果与「加载更多」→ 点击后追加下一页', (tester) async {
    final adapter = _PagedAdapter({
      1: _pageJson(
        page: 1,
        total: 3,
        totalPages: 2,
        songs: [_song('1'), _song('2')],
      ),
      2: _pageJson(page: 2, total: 3, totalPages: 2, songs: [_song('3')]),
    });
    final dio = Dio(
      BaseOptions(validateStatus: (_) => true, followRedirects: false),
    );
    dio.httpClientAdapter = adapter;
    MusicDlService.instance.setDioForTest(dio);

    await tester.pumpWidget(const MaterialApp(home: OnlineDownloadPage()));
    await _pumpFrames(tester);

    // 搜索
    await tester.enterText(find.byType(TextField), 'x');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _pumpFrames(tester);

    expect(find.text('歌1'), findsOneWidget);
    expect(find.text('歌2'), findsOneWidget);
    expect(find.textContaining('共找到 3 首'), findsOneWidget);
    expect(find.textContaining('已加载 2 首'), findsOneWidget);

    // 还有下一页 → 出现「加载更多」
    expect(find.textContaining('加载更多'), findsOneWidget);

    await tester.tap(find.textContaining('加载更多'));
    await _pumpFrames(tester);

    expect(find.text('歌3'), findsOneWidget);
    // 到末页后按钮换成到底提示
    expect(find.textContaining('加载更多'), findsNothing);
    expect(find.textContaining('已加载全部 3 首'), findsOneWidget);
    expect(adapter.requestedPages, [1, 2]);
  });

  testWidgets('没有下一页时不显示「加载更多」', (tester) async {
    final adapter = _PagedAdapter({
      1: _pageJson(page: 1, total: 1, totalPages: 1, songs: [_song('1')]),
    });
    final dio = Dio(
      BaseOptions(validateStatus: (_) => true, followRedirects: false),
    );
    dio.httpClientAdapter = adapter;
    MusicDlService.instance.setDioForTest(dio);

    await tester.pumpWidget(const MaterialApp(home: OnlineDownloadPage()));
    await _pumpFrames(tester);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _pumpFrames(tester);

    expect(find.text('歌1'), findsOneWidget);
    expect(find.textContaining('加载更多'), findsNothing);
    expect(find.textContaining('已加载全部 1 首'), findsOneWidget);
    expect(adapter.requestedPages, [1]);
  });
}
