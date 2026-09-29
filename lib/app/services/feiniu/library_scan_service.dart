import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'api_models.dart';

/// 飞牛音乐曲库扫描编排。
///
/// go-music-dl 把文件写进曲库目录后，飞牛音乐需要重新扫描才会把它索引进曲库。
/// 官方通常会在约 120 秒内自动扫描入库，所以这里的显式扫描是**加速**而非必需：
/// 该接口逆向自官方 Web 前端、并非公开文档，失败时必须静默降级为等待自动扫描，
/// 不能让「扫描失败」把已经成功的下载报成失败。
class FeiNiuLibraryScanService {
  FeiNiuLibraryScanService._();

  static final FeiNiuLibraryScanService instance = FeiNiuLibraryScanService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  static const Duration _defaultTimeout = Duration(minutes: 3);
  static const Duration _pollInterval = Duration(seconds: 3);

  /// 曲库根目录列表（`path` 即 NAS 上被索引的目录）。
  Future<List<FeiNiuSharedLibrary>> getLibraries() =>
      _api.getSharedLibraryList();

  /// 触发曲库扫描并等待结束。
  ///
  /// 返回 `false` 表示显式扫描不可用或等待超时——调用方应提示用户
  /// 「文件已下载，飞牛音乐稍后会自动收录」，而不是当作失败。
  Future<bool> scanAndWait({
    Duration timeout = _defaultTimeout,
    Duration interval = _pollInterval,
  }) async {
    try {
      await _api.scanSharedLibrary();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[LibraryScan] 显式扫描不可用，回退等待官方自动扫描: $error');
      }
      return false;
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      final tasks = await _safeTaskList();
      // 拿不到任务列表时无法判断进度，按「官方会自动扫描」处理。
      if (tasks == null) return true;
      if (!_hasPendingScan(tasks)) return true;
    }
    return false;
  }

  Future<List<Map<String, dynamic>>?> _safeTaskList() async {
    try {
      return await _api.getTaskList();
    } catch (error) {
      if (kDebugMode) debugPrint('[LibraryScan] 读取任务列表失败: $error');
      return null;
    }
  }

  /// 任务列表里是否还有未完成的 `fileScan`。
  static bool _hasPendingScan(List<Map<String, dynamic>> tasks) {
    for (final task in tasks) {
      if (task['type']?.toString() != 'fileScan') continue;
      if (task['done'] != true) return true;
    }
    return false;
  }
}
