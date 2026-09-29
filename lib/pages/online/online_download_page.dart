import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/library_scan_service.dart';
import '../../app/services/music_dl/music_dl_service.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

/// 一首歌的下载状态。
enum _DownloadState { idle, downloading, done, failed }

/// 在线搜索与下载页。
///
/// 搜索、下载都在 NAS 侧的 go-music-dl 上完成：这里只发请求，音频文件不经过
/// 手机。下载完成后按设置触发飞牛音乐扫描，把新文件收录进曲库。
class OnlineDownloadPage extends StatefulWidget {
  const OnlineDownloadPage({super.key});

  @override
  State<OnlineDownloadPage> createState() => _OnlineDownloadPageState();
}

class _OnlineDownloadPageState extends State<OnlineDownloadPage> {
  final TextEditingController _keywordController = TextEditingController();

  List<MusicDlSong> _songs = const [];
  final Map<String, _DownloadState> _states = {};

  bool _loading = false;
  bool _scanning = false;
  bool _loadingMore = false;
  String? _error;
  int _total = 0;
  int _page = 1;
  int _totalPages = 1;

  /// 是否还有下一页可加载。
  bool get _hasMore => _page < _totalPages;

  @override
  void initState() {
    super.initState();
    AppMusicDlSettings.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  String _keyOf(MusicDlSong song) => '${song.source}:${song.id}';

  /// 弹出 go-music-dl 登录框。返回 true 表示已登录成功。
  Future<bool> _promptLogin() async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _MusicDlLoginDialog(),
    );
    return ok ?? false;
  }

  Future<void> _search({bool allowLoginRetry = true}) async {
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _error = null;
      _states.clear();
      _loadingMore = false;
      _page = 1;
      _totalPages = 1;
    });

    try {
      final result = await MusicDlService.instance.searchSongs(keyword);
      if (!mounted) return;
      setState(() {
        _songs = result.songs;
        _total = result.total;
        _page = result.page;
        _totalPages = result.totalPages;
        _loading = false;
      });
    } on MusicDlException catch (error) {
      if (!mounted) return;
      // 服务端开了 --require-login 时未登录会走到这里：弹登录框，成功后自动重试一次。
      if (error.needsLogin && allowLoginRetry && await _promptLogin()) {
        if (!mounted) return;
        await _search(allowLoginRetry: false);
        return;
      }
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _songs = const [];
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败：$error';
        _songs = const [];
        _loading = false;
      });
    }
  }

  /// 加载下一页并追加。
  ///
  /// 默认每页 30 条，而各平台一次能返回几十上百条（实测「晴天」有 72 条），
  /// 没有这个入口用户就只能看到第一页。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;

    setState(() => _loadingMore = true);
    try {
      final result = await MusicDlService.instance.searchSongs(
        _keywordController.text,
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _songs = mergeMusicDlSongs(_songs, result.songs);
        _total = result.total;
        _page = result.page;
        _totalPages = result.totalPages;
        _loadingMore = false;
      });
    } on MusicDlException catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      // 翻页失败不清空已有结果，只提示。
      AppToast.show(context, error.message, type: ToastType.error);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      AppToast.show(context, '加载更多失败：$error', type: ToastType.error);
    }
  }

  Future<void> _download(
    MusicDlSong song, {
    bool allowLoginRetry = true,
  }) async {
    final key = _keyOf(song);
    setState(() => _states[key] = _DownloadState.downloading);
    try {
      final result = await MusicDlService.instance.saveToServer(song);
      if (!mounted) return;
      setState(() => _states[key] = _DownloadState.done);
      AppToast.show(
        context,
        result.skipped
            ? '曲库里已有，跳过：${song.name}'
            : '已下载到 NAS：${result.filename.isEmpty ? song.name : result.filename}',
        type: ToastType.success,
        duration: const Duration(seconds: 3),
      );
      if (AppMusicDlSettings.autoScan.value) {
        await _triggerScan();
      }
    } on MusicDlException catch (error) {
      if (!mounted) return;
      if (error.needsLogin && allowLoginRetry && await _promptLogin()) {
        if (!mounted) return;
        await _download(song, allowLoginRetry: false);
        return;
      }
      if (!mounted) return;
      setState(() => _states[key] = _DownloadState.failed);
      AppToast.show(context, error.message, type: ToastType.error);
    } catch (error) {
      if (!mounted) return;
      setState(() => _states[key] = _DownloadState.failed);
      AppToast.show(context, '下载失败：$error', type: ToastType.error);
    }
  }

  /// 触发飞牛音乐扫描。
  ///
  /// 扫描接口未公开，且官方通常会在约两分钟内自动扫描入库，所以失败只提示
  /// 「稍后自动收录」，不当作下载失败。
  Future<void> _triggerScan() async {
    if (!mounted) return;
    setState(() => _scanning = true);
    final ok = await FeiNiuLibraryScanService.instance.scanAndWait();
    if (!mounted) return;
    setState(() => _scanning = false);
    AppToast.show(
      context,
      ok ? '曲库扫描完成，新歌已入库' : '已下载，飞牛音乐稍后会自动收录',
      type: ok ? ToastType.success : ToastType.info,
      duration: const Duration(seconds: 3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '在线下载',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ValueListenableBuilder<bool>(
        valueListenable: AppMusicDlSettings.enabled,
        builder: (context, enabled, _) {
          if (!enabled) {
            return _buildNotice(
              bottomPadding,
              icon: Icons.cloud_off_outlined,
              title: '在线下载未启用',
              message: '在设置里开启「音乐下载」并填写 go-music-dl 地址后即可搜索下载。',
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _keywordController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '搜索歌名 / 歌手',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '清空',
                      onPressed: () {
                        _keywordController.clear();
                        setState(() => _songs = const []);
                      },
                    ),
                  ),
                ),
              ),
              if (_scanning) const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _buildBody(bottomPadding)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(double bottomPadding) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _buildNotice(
        bottomPadding,
        icon: Icons.error_outline,
        title: '出错了',
        message: _error!,
      );
    }
    if (_songs.isEmpty) {
      return _buildNotice(
        bottomPadding,
        icon: Icons.music_note_outlined,
        title: '还没有结果',
        message: '输入关键词搜索在线音乐；下载会直接写入 NAS 上飞牛音乐的曲库目录。',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(12, 4, 12, bottomPadding),
      // 多一个头部（结果计数）与一个尾部（加载更多）。
      itemCount: _songs.length + 2,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              '共找到 $_total 首，已加载 ${_songs.length} 首',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        if (index == _songs.length + 1) {
          return _buildListFooter();
        }
        return _buildSongTile(_songs[index - 1]);
      },
    );
  }

  /// 列表尾部：还有下一页时给「加载更多」，否则给出到底提示。
  Widget _buildListFooter() {
    final theme = Theme.of(context);
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );

    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (!_hasMore) {
      return Padding(
        padding: EdgeInsets.fromLTRB(0, 12, 0, bottomPadding + 12),
        child: Center(
          child: Text(
            '已加载全部 $_total 首',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(0, 8, 0, bottomPadding + 8),
      child: Center(
        child: FilledButton.tonalIcon(
          icon: const Icon(Icons.expand_more),
          label: Text('加载更多（第 $_page / 共 $_totalPages 页）'),
          onPressed: _loadMore,
        ),
      ),
    );
  }

  Widget _buildSongTile(MusicDlSong song) {
    final state = _states[_keyOf(song)] ?? _DownloadState.idle;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: state == _DownloadState.downloading
            ? null
            : () => _download(song),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: song.cover.isEmpty
                      ? Icon(
                          Icons.music_note,
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : CachedNetworkImage(
                          imageUrl: song.cover,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Icon(
                            Icons.music_note,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (song.artist.isNotEmpty) song.artist,
                        if (song.album.isNotEmpty) song.album,
                        if (song.source.isNotEmpty) song.source,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildTrailing(state, song),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrailing(_DownloadState state, MusicDlSong song) {
    switch (state) {
      case _DownloadState.downloading:
        return const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case _DownloadState.done:
        return Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        );
      case _DownloadState.failed:
        return IconButton(
          icon: Icon(Icons.refresh, color: Theme.of(context).colorScheme.error),
          tooltip: '重试',
          onPressed: () => _download(song),
        );
      case _DownloadState.idle:
        return IconButton(
          icon: const Icon(Icons.download_outlined),
          tooltip: '下载到 NAS 曲库',
          onPressed: () => _download(song),
        );
    }
  }

  Widget _buildNotice(
    double bottomPadding, {
    required IconData icon,
    required String title,
    required String message,
    bool showSettingsButton = true,
  }) {
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 48, 24, bottomPadding),
      children: [
        Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        if (showSettingsButton) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.settings_outlined),
              label: const Text('去设置'),
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.musicDlSettings),
            ),
          ),
        ],
      ],
    );
  }
}

/// go-music-dl 登录框。
///
/// 服务端开启 `--require-login` 后，搜索与下载都需要内置管理员会话。这里让用户
/// 就地登录，成功后调用方自动重试原来的操作，不用跳去设置页再回来。
class _MusicDlLoginDialog extends StatefulWidget {
  const _MusicDlLoginDialog();

  @override
  State<_MusicDlLoginDialog> createState() => _MusicDlLoginDialogState();
}

class _MusicDlLoginDialogState extends State<_MusicDlLoginDialog> {
  late final TextEditingController _usernameController;
  final TextEditingController _passwordController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 用户名与服务端默认值一致（admin）；配置过则沿用上次的。
    final saved = AppMusicDlSettings.username.value;
    _usernameController = TextEditingController(
      text: saved.isEmpty ? 'admin' : saved,
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写用户名与密码');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await MusicDlService.instance.login(
        username: username,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on MusicDlException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '登录失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('登录 go-music-dl'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '搜索与下载需要管理员会话。密码只用于换取 Cookie，不会被保存。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _usernameController,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '用户名',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) {
              if (!_busy) _submit();
            },
            decoration: const InputDecoration(
              labelText: '密码',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }
}
