import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../../state/settings_music_dl_state.dart';

/// go-music-dl 调用失败。
class MusicDlException implements Exception {
  const MusicDlException(this.message, {this.needsLogin = false});

  final String message;

  /// 会话缺失或已失效（服务端返回 401 / 跳登录页）。
  ///
  /// 调用方据此弹登录框并重试，而不是把用户丢在一个「出错了」的死胡同里。
  final bool needsLogin;

  @override
  String toString() => message;
}

/// go-music-dl 搜索结果中的一首在线歌曲。
///
/// 字段直接对应 `/search` 返回 HTML 里 `li.song-card` 上的 `data-*` 属性。
/// [extra] 是平台相关的原始 JSON（体积、码率等），下载时必须原样回传。
class MusicDlSong {
  const MusicDlSong({
    required this.id,
    required this.source,
    required this.name,
    required this.artist,
    required this.album,
    required this.albumId,
    required this.cover,
    required this.duration,
    required this.extra,
  });

  final String id;
  final String source;
  final String name;
  final String artist;
  final String album;
  final String albumId;
  final String cover;
  final String duration;
  final String extra;

  factory MusicDlSong.fromAttributes(Map<String, String> attrs) {
    String read(String key) => attrs[key]?.trim() ?? '';
    return MusicDlSong(
      id: read('data-id'),
      source: read('data-source'),
      name: read('data-name'),
      artist: read('data-artist'),
      album: read('data-album'),
      albumId: read('data-album-id'),
      cover: read('data-cover'),
      duration: read('data-duration'),
      extra: read('data-extra'),
    );
  }

  /// 从 `/api/search` 的 JSON 条目构造。
  ///
  /// [extra] 统一重编码成字符串，与 HTML 的 `data-extra` 保持同一下游契约
  /// （下载时原样回传给服务端）。
  factory MusicDlSong.fromApiJson(Map<String, dynamic> json) {
    String read(String key) => json[key]?.toString().trim() ?? '';
    final rawExtra = json['extra'];
    return MusicDlSong(
      id: read('id'),
      source: read('source'),
      name: read('name'),
      artist: read('artist'),
      album: read('album'),
      albumId: read('album_id'),
      cover: read('cover'),
      duration: read('duration'),
      extra: rawExtra is Map && rawExtra.isNotEmpty ? jsonEncode(rawExtra) : '',
    );
  }

  /// 稳定标识：`来源:平台内 id`。同一首歌在同一平台内不会重复，跨平台允许并存。
  String get key => '$source:$id';

  bool get isUsable => id.isNotEmpty && source.isNotEmpty;
}

/// 合并分页结果：按 [MusicDlSong.key] 去重并保持先后顺序。
///
/// 翻页时同一首歌可能被不同页返回（各平台结果会变动），直接拼接会让列表里出现
/// 重复项；这里保留先到的那条，后到的重复项丢弃。
List<MusicDlSong> mergeMusicDlSongs(
  List<MusicDlSong> existing,
  List<MusicDlSong> incoming,
) {
  final seen = <String>{for (final song in existing) song.key};
  final merged = <MusicDlSong>[...existing];
  for (final song in incoming) {
    if (seen.add(song.key)) merged.add(song);
  }
  return merged;
}

/// 一页搜索结果。
class MusicDlSearchResult {
  const MusicDlSearchResult({
    required this.songs,
    required this.total,
    required this.page,
    required this.totalPages,
  });

  final List<MusicDlSong> songs;
  final int total;
  final int page;
  final int totalPages;

  bool get hasMore => page < totalPages;
}

/// 服务端保存结果（`save_local=1` 的响应）。
class MusicDlSaveResult {
  const MusicDlSaveResult({
    required this.saved,
    required this.skipped,
    required this.path,
    required this.filename,
    this.warning,
    this.webdavError,
  });

  final bool saved;
  final bool skipped;
  final String path;
  final String filename;
  final String? warning;
  final String? webdavError;

  factory MusicDlSaveResult.fromJson(Map<String, dynamic> json) {
    return MusicDlSaveResult(
      saved: json['saved'] == true,
      skipped: json['skipped'] == true,
      path: json['path'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      warning: json['warning'] as String?,
      webdavError: json['webdav_error'] as String?,
    );
  }
}

/// go-music-dl 客户端。
///
/// 搜索没有 JSON 接口，`/search` 返回服务端渲染的 HTML，这里解析
/// `li.song-card` 上的 `data-*` 属性。下载走 `POST /download?save_local=1`：
/// 由 NAS 侧把文件写进飞牛音乐的曲库目录，手机只发请求、不下载音频。
class MusicDlService {
  MusicDlService._();

  static final MusicDlService instance = MusicDlService._();

  /// 保存到服务端的接口带同源写保护：必须是 POST，且必须带这个请求头。
  static const String _writeGuardHeader = 'XMLHttpRequest';

  Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (_) => true,
      // 显式要 JSON：服务端在 Accept 为空或含 text/html 时会把鉴权失败
      // 变成 302 跳登录页，只有 JSON 请求才拿到 401。
      headers: const {'Accept': 'application/json'},
    ),
  );

  @visibleForTesting
  void setDioForTest(Dio dio) => _dio = dio;

  bool get isConfigured => AppMusicDlSettings.baseUrl.value.isNotEmpty;

  String _url(String path) {
    final base = AppMusicDlSettings.baseUrl.value;
    if (base.isEmpty) {
      throw const MusicDlException('尚未配置 go-music-dl 地址');
    }
    return '$base${path.startsWith('/') ? path : '/$path'}';
  }

  Map<String, dynamic> get _headers {
    final session = AppMusicDlSettings.session;
    return {
      'Accept': 'application/json',
      if (session.isNotEmpty) 'Cookie': 'music_dl_session=$session',
    };
  }

  /// 服务是否可用。
  Future<bool> ping() async {
    if (!isConfigured) return false;
    try {
      final response = await _dio.get<dynamic>(
        _url('/healthz'),
        options: Options(headers: _headers),
      );
      return response.statusCode == 200;
    } catch (error) {
      if (kDebugMode) debugPrint('[MusicDl] ping 失败: $error');
      return false;
    }
  }

  /// 是否存在管理员账号（未初始化时返回 true，调用方应提示去 Web 端初始化）。
  Future<bool> isSetupRequired() async {
    try {
      final response = await _dio.get<dynamic>(
        _url('/settings'),
        options: Options(headers: _headers),
      );
      final data = response.data;
      return data is Map && data['setupRequired'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 用内置管理员账号登录，成功后把 `music_dl_session` 存入设置。
  ///
  /// 密码不落盘，只保留 Cookie。
  Future<void> login({
    required String username,
    required String password,
  }) async {
    final response = await _dio.post<dynamic>(
      _url('/login'),
      data: {'username': username, 'password': password, 'next': '/'},
      options: Options(
        headers: _headers,
        contentType: Headers.formUrlEncodedContentType,
      ),
    );

    final cookie = _extractSessionCookie(response.headers);
    if (cookie == null) {
      throw MusicDlException(
        response.statusCode == 200
            ? '用户名或密码不正确'
            : '登录失败（HTTP ${response.statusCode ?? 0}）',
      );
    }
    await AppMusicDlSettings.setSession(cookie);
    await AppMusicDlSettings.setUsername(username);
  }

  /// 搜索单曲。
  ///
  /// 优先走服务端的 `/api/search` JSON 接口；只有旧版本没有该接口（404）时，
  /// 才回退去解析 `/search` 的 HTML。JSON 路径不受上游模板改动影响。
  Future<MusicDlSearchResult> searchSongs(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return const MusicDlSearchResult(
        songs: [],
        total: 0,
        page: 1,
        totalPages: 1,
      );
    }

    final fromJson = await _searchSongsJson(
      trimmed,
      page: page,
      pageSize: pageSize,
    );
    if (fromJson != null) return fromJson;

    if (kDebugMode) {
      debugPrint('[MusicDl] /api/search 不可用，回退解析 HTML');
    }
    return _searchSongsHtml(trimmed, page: page, pageSize: pageSize);
  }

  /// 走 JSON 接口。返回 null 表示服务端没有该接口（需要回退 HTML）。
  Future<MusicDlSearchResult?> _searchSongsJson(
    String keyword, {
    required int page,
    required int pageSize,
  }) async {
    final response = await _dio.get<dynamic>(
      _url('/api/search'),
      queryParameters: {
        'q': keyword,
        'type': 'song',
        'page': page,
        'page_size': pageSize,
      },
      options: Options(headers: _headers),
    );

    // 旧版本没有这个路由：交给 HTML 解析兜底。
    if (response.statusCode == 404) return null;
    // 鉴权失败要抛出（needsLogin），不能静默回退——否则登录流程会被跳过。
    await _throwIfUnauthorized(response.statusCode, response.data);

    final data = response.data;
    if (data is! Map) {
      throw MusicDlException('搜索响应异常（HTTP ${response.statusCode ?? 0}）');
    }
    final json = data.cast<String, dynamic>();
    if (json['error'] != null) {
      throw MusicDlException(json['error'].toString());
    }
    return _parseSearchJson(json, page);
  }

  /// 解析 HTML 搜索结果（旧服务端回退路径）。
  Future<MusicDlSearchResult> _searchSongsHtml(
    String keyword, {
    required int page,
    required int pageSize,
  }) async {
    final response = await _dio.get<String>(
      _url('/search'),
      queryParameters: {
        'q': keyword,
        'type': 'song',
        'page': page,
        'page_size': pageSize,
      },
      options: Options(headers: _headers, responseType: ResponseType.plain),
    );
    await _throwIfUnauthorized(response.statusCode, response.data);
    return _parseSearchResult(response.data ?? '', page);
  }

  /// 让 NAS 侧下载这首歌并写入曲库目录。
  Future<MusicDlSaveResult> saveToServer(MusicDlSong song) async {
    final response = await _dio.post<dynamic>(
      _url('/download'),
      queryParameters: {
        'id': song.id,
        'source': song.source,
        'name': song.name,
        'artist': song.artist,
        if (song.album.isNotEmpty) 'album': song.album,
        if (song.cover.isNotEmpty) 'cover': song.cover,
        if (song.duration.isNotEmpty) 'duration': song.duration,
        if (song.extra.isNotEmpty) 'extra': song.extra,
        'save_local': '1',
      },
      options: Options(
        headers: {..._headers, 'X-Requested-With': _writeGuardHeader},
      ),
    );
    await _throwIfUnauthorized(response.statusCode, response.data);

    final data = response.data;
    if (data is! Map) {
      throw MusicDlException('下载响应异常（HTTP ${response.statusCode ?? 0}）');
    }
    final json = data.cast<String, dynamic>();
    if (json['error'] != null) {
      throw MusicDlException(json['error'].toString());
    }
    return MusicDlSaveResult.fromJson(json);
  }

  /// 重建 go-music-dl 自己的本地音乐索引。
  ///
  /// 注意：这**不是**飞牛音乐的曲库扫描，两者互不相干。
  Future<void> reindexLocalMusic() async {
    final response = await _dio.post<dynamic>(
      _url('/local_music/reindex'),
      options: Options(headers: _headers),
    );
    await _throwIfUnauthorized(response.statusCode, response.data);
  }

  /// 会话失效时清掉本地 Cookie 并抛出可读错误。
  ///
  /// 必须 await 掉 clearSession：它是异步落盘 + 更新通知器的，不等待的话
  /// 调用方拿到的错误和「已退出登录」的状态会不同步。
  Future<void> _throwIfUnauthorized(int? statusCode, dynamic body) async {
    if (statusCode == 401) {
      await AppMusicDlSettings.clearSession();
      final message = body is Map && body['error'] != null
          ? body['error'].toString()
          : '登录已失效，请重新登录';
      throw MusicDlException(message, needsLogin: true);
    }
    if (statusCode == 302 || statusCode == 303) {
      await AppMusicDlSettings.clearSession();
      throw const MusicDlException('登录已失效，请重新登录', needsLogin: true);
    }
  }

  /// 从 `set-cookie` 响应头里取出会话 Cookie 值。
  String? _extractSessionCookie(Headers headers) {
    final raw = headers['set-cookie'];
    if (raw == null) return null;
    for (final entry in raw) {
      for (final part in entry.split(';')) {
        final trimmed = part.trim();
        if (trimmed.startsWith('music_dl_session=')) {
          final value = trimmed.substring('music_dl_session='.length);
          if (value.isNotEmpty) return value;
        }
      }
    }
    return null;
  }

  /// 解析 `/api/search` 的 JSON 响应。
  MusicDlSearchResult _parseSearchJson(
    Map<String, dynamic> json,
    int fallbackPage,
  ) {
    final songs = <MusicDlSong>[];
    final rawSongs = json['songs'];
    if (rawSongs is List) {
      for (final item in rawSongs) {
        if (item is! Map) continue;
        final song = MusicDlSong.fromApiJson(item.cast<String, dynamic>());
        if (song.isUsable) songs.add(song);
      }
    }

    int asInt(String key, int fallback) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? fallback;
      return fallback;
    }

    final totalPages = asInt('total_pages', 1);
    return MusicDlSearchResult(
      songs: songs,
      total: asInt('total', songs.length),
      page: asInt('page', fallbackPage),
      totalPages: totalPages < 1 ? 1 : totalPages,
    );
  }

  MusicDlSearchResult _parseSearchResult(String body, int fallbackPage) {
    final document = html_parser.parse(body);
    final songs = <MusicDlSong>[];
    for (final node in document.querySelectorAll('li.song-card')) {
      final attrs = <String, String>{};
      node.attributes.forEach((key, value) {
        attrs[key.toString()] = value;
      });
      final song = MusicDlSong.fromAttributes(attrs);
      if (song.isUsable) songs.add(song);
    }

    final pagination =
        document.querySelector('.pagination-bar[data-total-pages]') ??
        document.querySelector('#batch-toolbar');
    final totalPages =
        int.tryParse(pagination?.attributes['data-total-pages'] ?? '') ?? 1;
    final page =
        int.tryParse(pagination?.attributes['data-current-page'] ?? '') ??
        fallbackPage;

    final countText = document
        .querySelector('.result-count .count')
        ?.text
        .trim();
    final total = int.tryParse(countText ?? '') ?? songs.length;

    return MusicDlSearchResult(
      songs: songs,
      total: total,
      page: page,
      totalPages: totalPages < 1 ? 1 : totalPages,
    );
  }
}
