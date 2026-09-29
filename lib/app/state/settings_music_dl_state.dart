import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// go-music-dl 集成设置。
///
/// go-music-dl 部署在飞牛 NAS 上（fnOS 应用包）。手机端只负责发起请求：
/// 搜索与下载都在 NAS 侧完成，音频文件直接落到飞牛音乐的曲库目录，再由飞牛
/// 音乐扫描入库，因此 App 不承载音频文件，也不需要存储权限。
///
/// [baseUrl] 是 go-music-dl Web 服务的根地址（含 base path，默认 `/music`），
/// 例如 `http://192.168.1.10:8080/music` 或反代后的
/// `https://music.example.com/music`。
///
/// [session] 是内置管理员登录后拿到的 `music_dl_session` Cookie 值。开启
/// `--require-login` 后业务接口都要求登录，所以 App 需要持有它。这里只存
/// Cookie 值，不保存管理员密码。
class AppMusicDlSettings {
  static const String _prefsEnabled = 'music_dl_enabled';
  static const String _prefsBaseUrl = 'music_dl_base_url';
  static const String _prefsUsername = 'music_dl_username';
  static const String _prefsSession = 'music_dl_session';
  static const String _prefsAutoScan = 'music_dl_auto_scan';

  /// go-music-dl 的默认 Web base path（可用 `--base-path` 改动）。
  static const String defaultBasePath = '/music';

  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static final ValueNotifier<String> baseUrl = ValueNotifier('');
  static final ValueNotifier<String> username = ValueNotifier('');

  /// 下载完成后是否自动触发飞牛音乐扫描入库。
  static final ValueNotifier<bool> autoScan = ValueNotifier(true);

  /// 是否已持有可用的登录会话。
  static final ValueNotifier<bool> hasSession = ValueNotifier(false);

  static String _session = '';
  static String get session => _session;

  static Future<void>? _loading;
  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    baseUrl.value = prefs.getString(_prefsBaseUrl) ?? '';
    username.value = prefs.getString(_prefsUsername) ?? '';
    _session = prefs.getString(_prefsSession) ?? '';
    hasSession.value = _session.isNotEmpty;
    autoScan.value = prefs.getBool(_prefsAutoScan) ?? true;
  }

  /// 功能是否可直接使用（已启用且配置了地址）。
  static bool get isReady => enabled.value && baseUrl.value.isNotEmpty;

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  static Future<void> setBaseUrl(String value) async {
    final normalized = normalizeBaseUrl(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsBaseUrl, normalized);
    baseUrl.value = normalized;
  }

  static Future<void> setUsername(String value) async {
    final trimmed = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsUsername, trimmed);
    username.value = trimmed;
  }

  static Future<void> setAutoScan(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoScan, value);
    autoScan.value = value;
  }

  static Future<void> setSession(String cookieValue) async {
    final trimmed = cookieValue.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSession, trimmed);
    _session = trimmed;
    hasSession.value = trimmed.isNotEmpty;
  }

  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsSession);
    _session = '';
    hasSession.value = false;
  }

  /// 归一化用户输入的地址：
  /// - 去掉首尾空白与结尾斜杠；
  /// - 未写协议时补 `http://`；
  /// - 未写路径时补默认 base path `/music`。
  ///
  /// 返回空串表示输入不可用。
  static String normalizeBaseUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) {
      value = 'http://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return '';

    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isEmpty) {
      path = defaultBasePath;
    }

    // 重新构造而不是 replace(query: '')：后者会把空 query 渲染成一个多余的 `?`。
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    enabled.value = false;
    baseUrl.value = '';
    username.value = '';
    _session = '';
    hasSession.value = false;
    autoScan.value = true;
  }
}
