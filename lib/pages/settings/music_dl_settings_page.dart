import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../components/index.dart';
import '../../app/services/music_dl/music_dl_service.dart';

/// go-music-dl 集成设置。
///
/// go-music-dl 跑在飞牛 NAS 上，App 只负责调它的接口：搜索、下载都在 NAS 侧
/// 完成，文件直接落进飞牛音乐的曲库目录。这里配置它的 Web 地址与管理员账号。
class MusicDlSettingsPage extends StatefulWidget {
  const MusicDlSettingsPage({super.key});

  @override
  State<MusicDlSettingsPage> createState() => _MusicDlSettingsPageState();
}

class _MusicDlSettingsPageState extends State<MusicDlSettingsPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _testing = false;
  bool _loggingIn = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = AppMusicDlSettings.baseUrl.value;
    _usernameController.text = AppMusicDlSettings.username.value;
    AppMusicDlSettings.ensureLoaded().then((_) {
      if (!mounted) return;
      setState(() {
        _urlController.text = AppMusicDlSettings.baseUrl.value;
        _usernameController.text = AppMusicDlSettings.username.value;
      });
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _saveBaseUrl() async {
    final input = _urlController.text.trim();
    final normalized = AppMusicDlSettings.normalizeBaseUrl(input);
    if (normalized.isEmpty) {
      AppToast.show(
        context,
        '请输入有效地址，例如 http://192.168.1.10:8080',
        type: ToastType.error,
      );
      return;
    }
    await AppMusicDlSettings.setBaseUrl(normalized);
    if (!mounted) return;
    _urlController.text = normalized;
    AppToast.show(context, '已保存：$normalized', type: ToastType.success);
    setState(() {});
  }

  Future<void> _testConnection() async {
    await _saveBaseUrl();
    if (!mounted) return;
    // 未启用也允许测试，但提示一下，避免用户以为连不上。
    if (!AppMusicDlSettings.enabled.value) {
      AppToast.show(context, '提示：功能尚未启用', type: ToastType.info);
    }
    setState(() => _testing = true);
    final ok = await MusicDlService.instance.ping();
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.show(
      context,
      ok ? '连接成功，go-music-dl 可用' : '连接失败，请检查地址与端口',
      type: ok ? ToastType.success : ToastType.error,
    );
  }

  Future<void> _login() async {
    await _saveBaseUrl();
    if (!mounted) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      AppToast.show(context, '请填写管理员用户名与密码', type: ToastType.error);
      return;
    }
    setState(() => _loggingIn = true);
    try {
      await MusicDlService.instance.login(
        username: username,
        password: password,
      );
      if (!mounted) return;
      _passwordController.clear();
      AppToast.show(context, '登录成功', type: ToastType.success);
    } on MusicDlException catch (error) {
      if (!mounted) return;
      AppToast.show(context, error.message, type: ToastType.error);
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '登录失败：$error', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _logout() async {
    await AppMusicDlSettings.clearSession();
    if (!mounted) return;
    AppToast.show(context, '已退出登录', type: ToastType.info);
    setState(() {});
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
        title: '音乐下载',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '总开关',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppMusicDlSettings.enabled,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '启用在线搜索与下载',
                    subtitle: '在 App 内搜索在线音乐，并让 NAS 下载到飞牛音乐曲库',
                    value: enabled,
                    onChanged: AppMusicDlSettings.setEnabled,
                  );
                },
              ),
            ],
          ),
          AppSettingSection(
            title: '服务地址',
            children: [
              _TextFieldTile(
                controller: _urlController,
                label: 'go-music-dl 地址',
                hint: 'http://192.168.1.10:8080/music',
                helper:
                    '默认 base path 为 /music；只填 IP 时会自动补全。'
                    '外网请填反代后的 https 地址。',
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _saveBaseUrl(),
              ),
              _ActionTile(
                title: '保存地址',
                icon: Icons.save_outlined,
                onTap: _saveBaseUrl,
              ),
              _ActionTile(
                title: '测试连接',
                icon: Icons.wifi_tethering,
                busy: _testing,
                onTap: _testConnection,
              ),
            ],
          ),
          AppSettingSection(
            title: '管理员登录',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppMusicDlSettings.hasSession,
                builder: (context, hasSession, _) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Row(
                      children: [
                        Icon(
                          hasSession
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 18,
                          color: hasSession
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            hasSession ? '已登录，会话有效' : '未登录',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              _TextFieldTile(
                controller: _usernameController,
                label: '用户名',
                hint: 'admin',
              ),
              _TextFieldTile(
                controller: _passwordController,
                label: '密码',
                hint: '仅用于换取会话，不会保存',
                obscureText: true,
              ),
              _ActionTile(
                title: '登录',
                icon: Icons.login,
                busy: _loggingIn,
                onTap: _login,
              ),
              _ActionTile(title: '退出登录', icon: Icons.logout, onTap: _logout),
            ],
          ),
          AppSettingSection(
            title: '下载后处理',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppMusicDlSettings.autoScan,
                builder: (context, autoScan, _) {
                  return AppSettingSwitchTile(
                    title: '自动触发曲库扫描',
                    subtitle:
                        '下载完成后调用飞牛音乐扫描接口，让它尽快收录新歌。'
                        '该接口未公开，失败时官方仍会在约两分钟内自动扫描。',
                    value: autoScan,
                    onChanged: AppMusicDlSettings.setAutoScan,
                  );
                },
              ),
            ],
          ),
          AppSettingSection(
            title: '部署前提',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Text(
                  '1. go-music-dl 的下载目录必须指向飞牛音乐的曲库目录（或其子目录），'
                  '否则新文件不会被收录。\n'
                  '2. 必须在 go-music-dl 设置里开启「下载时内嵌元数据（封面/歌词）」：'
                  '飞牛音乐只识别音频文件内嵌的标签，外挂 cover.jpg 不生效。\n'
                  '3. 开启 --require-login 后业务接口都需要登录，'
                  '请在上方用管理员账号登录一次。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 设置页里的文本输入行。
class _TextFieldTile extends StatelessWidget {
  const _TextFieldTile({
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.obscureText = false,
    this.keyboardType,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            obscureText: obscureText,
            keyboardType: keyboardType,
            onSubmitted: onSubmitted,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 6),
            Text(
              helper!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 设置页里的动作行（带忙碌态）。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.title,
    required this.icon,
    required this.onTap,
    this.busy = false,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AppSettingTile(
      title: title,
      leading: Icon(icon, size: 20),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right_rounded),
      onTap: busy ? null : onTap,
    );
  }
}
