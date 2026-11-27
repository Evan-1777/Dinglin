import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/apple_primitives.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store});
  final AppStore store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _pairCodeCtrl;
  late final TextEditingController _deviceNameCtrl;
  late final TextEditingController _dndStartCtrl;
  late final TextEditingController _dndEndCtrl;
  late final TextEditingController _snoozeCtrl;
  late final TextEditingController _retentionCtrl;

  bool _pairMode = false;
  bool _dndEnabled = false;
  bool _busy = false;
  bool _dirtyGateway = false;
  bool _dirtyPolicy = false;

  static final _hhmmRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  @override
  void initState() {
    super.initState();
    final s = widget.store;
    _urlCtrl = TextEditingController(text: s.serverUrl);
    _tokenCtrl = TextEditingController(text: s.authToken);
    _pairCodeCtrl = TextEditingController();
    _deviceNameCtrl = TextEditingController(
      text: s.platform.platformName == 'web' ? 'Web 工作台' : 'Android 设备',
    );
    _dndEnabled = s.settings.dndEnabled;
    _dndStartCtrl = TextEditingController(text: s.settings.dndStart);
    _dndEndCtrl = TextEditingController(text: s.settings.dndEnd);
    _snoozeCtrl =
        TextEditingController(text: '${s.settings.defaultSnoozeMinutes}');
    _retentionCtrl = TextEditingController(text: '${s.settings.retentionDays}');
    widget.store.addListener(_syncFromStore);
  }

  void _syncFromStore() {
    if (!mounted) return;
    final s = widget.store;
    if (!_dirtyGateway) {
      if (_urlCtrl.text != s.serverUrl) _urlCtrl.text = s.serverUrl;
      if (_tokenCtrl.text != s.authToken) _tokenCtrl.text = s.authToken;
    }
    if (!_dirtyPolicy) {
      var changed = false;
      if (_dndEnabled != s.settings.dndEnabled) {
        _dndEnabled = s.settings.dndEnabled;
        changed = true;
      }
      if (_dndStartCtrl.text != s.settings.dndStart) {
        _dndStartCtrl.text = s.settings.dndStart;
      }
      if (_dndEndCtrl.text != s.settings.dndEnd) {
        _dndEndCtrl.text = s.settings.dndEnd;
      }
      final snoozeStr = '${s.settings.defaultSnoozeMinutes}';
      if (_snoozeCtrl.text != snoozeStr) _snoozeCtrl.text = snoozeStr;
      final retentionStr = '${s.settings.retentionDays}';
      if (_retentionCtrl.text != retentionStr) _retentionCtrl.text = retentionStr;
      if (changed) setState(() {});
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncFromStore);
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _pairCodeCtrl.dispose();
    _deviceNameCtrl.dispose();
    _dndStartCtrl.dispose();
    _dndEndCtrl.dispose();
    _snoozeCtrl.dispose();
    _retentionCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      if (_pairMode) {
        await widget.store.connectWithPairingCode(
          url: _urlCtrl.text,
          code: _pairCodeCtrl.text,
          deviceName: _deviceNameCtrl.text,
        );
      } else {
        await widget.store.connectWithToken(
          url: _urlCtrl.text,
          token: _tokenCtrl.text,
        );
      }
      _dirtyGateway = false;
    } catch (e) {
      widget.store.showToast(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnectGateway() async {
    final ok = await showAppleConfirmDialog(
      context,
      title: '断开网关',
      message: '确认断开当前网关连接并清除本机凭据？',
      confirmLabel: '断开',
    );
    if (!ok) return;
    try {
      _dirtyGateway = false;
      await widget.store.disconnect();
    } catch (e) {
      widget.store.showToast(e.toString(), isError: true);
    }
  }

  Future<void> _savePolicy() async {
    final start = _dndStartCtrl.text.trim();
    final end = _dndEndCtrl.text.trim();
    if (!_hhmmRe.hasMatch(start) || !_hhmmRe.hasMatch(end)) {
      widget.store.showToast('免打扰时间格式须为 HH:MM', isError: true);
      return;
    }
    final snooze = int.tryParse(_snoozeCtrl.text.trim()) ?? 0;
    if (snooze < 1 || snooze > 1440) {
      widget.store.showToast('默认贪睡须在 1–1440 分钟之间', isError: true);
      return;
    }
    final retention = int.tryParse(_retentionCtrl.text.trim()) ?? 0;
    if (retention < 1 || retention > 3650) {
      widget.store.showToast('保留天数须在 1–3650 天之间', isError: true);
      return;
    }
    final next = widget.store.settings.copyWith(
      dndEnabled: _dndEnabled,
      dndStart: start,
      dndEnd: end,
      defaultSnoozeMinutes: snooze,
      retentionDays: retention,
    );
    try {
      await widget.store.saveSettings(next);
      _dirtyPolicy = false;
    } catch (e) {
      widget.store.showToast(e.toString(), isError: true);
    }
  }

  Future<void> _openSourceEditorDialog({DinglinSource? existing}) async {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final slugCtrl = TextEditingController(text: existing?.slug ?? '');
    final cbCtrl = TextEditingController(text: existing?.callbackUrl ?? '');
    var kind = existing?.kind ?? 'webhook';
    var color = existing?.color ?? '#007AFF';

    final created = await showAppleAdaptiveModal<dynamic>(
      context: context,
      title: isEdit ? '编辑消息来源' : '新建消息来源',
      showClose: true,
      maxWidth: 420,
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!isEdit) ...[
                AppleSegmentedControl<String>(
                  value: kind,
                  options: const [
                    (value: 'webhook', label: 'Webhook'),
                    (value: 'agent', label: 'Agent / MCP'),
                  ],
                  onChanged: (v) => setLocal(() => kind = v),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: nameCtrl,
                decoration: appleInputDecoration(t, hint: '来源名称'),
              ),
              if (!isEdit) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: slugCtrl,
                  decoration: appleInputDecoration(t, hint: '来源标识'),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: cbCtrl,
                decoration: appleInputDecoration(t, hint: '回调 URL'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final hex in const [
                    '#007AFF',
                    '#34C759',
                    '#FF9500',
                    '#FF3B30',
                    '#AF52DE',
                  ])
                    ApplePressable(
                      onTap: () => setLocal(() => color = hex),
                      pressedScale: 0.9,
                      builder: (context, _, _) => Container(
                        width: 24,
                        height: 24,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: parseHexColor(hex),
                          shape: BoxShape.circle,
                          border: color == hex
                              ? Border.all(color: t.inkPrimary, width: 2)
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) {
                        widget.store.showToast('请输入来源名称', isError: true);
                        return;
                      }
                      try {
                        if (isEdit) {
                          await widget.store.updateSource(
                            existing.id,
                            name: name,
                            color: color,
                            callbackUrl: cbCtrl.text.trim(),
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                        } else {
                          final res = await widget.store.createSource(
                            name: name,
                            slug: slugCtrl.text.trim(),
                            kind: kind,
                            color: color,
                            callbackUrl: cbCtrl.text.trim(),
                          );
                          if (ctx.mounted) Navigator.pop(ctx, res);
                        }
                      } catch (e) {
                        widget.store.showToast(e.toString(), isError: true);
                      }
                    },
                    child: Text(isEdit ? '保存' : '创建'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    nameCtrl.dispose();
    slugCtrl.dispose();
    cbCtrl.dispose();

    if (!isEdit && created != null && mounted) {
      await _showTokenDialog(
        title: '来源凭据（仅展示一次）',
        token: created.token as String,
        secret: created.callbackSecret as String,
      );
    }
  }

  Future<void> _openSourceSnippetDialog(DinglinSource src) async {
    final rawBase = widget.store.serverUrl.trim();
    final baseUrl = rawBase.isNotEmpty
        ? rawBase.replaceAll(RegExp(r'/+$'), '')
        : 'https://your-dinglin-host';
    final isAgent = src.kind == 'agent';
    var selectedTab = isAgent ? 'http' : 'webhook';

    await showAppleAdaptiveModal<void>(
      context: context,
      title: '${src.name} · 接入片段',
      showClose: true,
      maxWidth: 500,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final t = AppleTokens.of(ctx);
            final code = isAgent
                ? (selectedTab == 'http'
                    ? '{\n'
                        '  "mcpServers": {\n'
                        '    "dinglin": {\n'
                        '      "type": "streamable-http",\n'
                        '      "url": "$baseUrl/mcp",\n'
                        '      "headers": {\n'
                        '        "Authorization": "Bearer ${src.tokenPrefix}..."\n'
                        '      }\n'
                        '    }\n'
                        '  }\n'
                        '}'
                    : '{\n'
                        '  "mcpServers": {\n'
                        '    "dinglin": {\n'
                        '      "command": "dinglin",\n'
                        '      "args": ["mcp-stdio", "--server", "$baseUrl/mcp", "--token", "${src.tokenPrefix}..."]\n'
                        '    }\n'
                        '  }\n'
                        '}')
                : (selectedTab == 'webhook'
                    ? 'curl -X POST "$baseUrl/api/v1/webhook/${src.slug}" \\\n'
                        '  -H "Authorization: Bearer ${src.tokenPrefix}..." \\\n'
                        '  -H "Content-Type: application/json" \\\n'
                        '  -d \'{"title":"构建完成","body":"部署成功","priority":"normal"}\''
                    : 'curl -X POST "$baseUrl/api/v1/notify" \\\n'
                        '  -H "Authorization: Bearer ${src.tokenPrefix}..." \\\n'
                        '  -H "Content-Type: application/json" \\\n'
                        '  -d \'{"title":"审批提醒","priority":"critical","actions":[{"id":"ack","label":"确认"}]}\'');

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppleSegmentedControl<String>(
                    value: selectedTab,
                    options: isAgent
                        ? const [
                            (value: 'http', label: 'MCP HTTP'),
                            (value: 'stdio', label: 'MCP Stdio'),
                          ]
                        : const [
                            (value: 'webhook', label: 'Webhook'),
                            (value: 'rest', label: 'REST API'),
                          ],
                    onChanged: (v) => setLocal(() => selectedTab = v),
                  ),
                ),
                const SizedBox(height: 12),
                _CopyBox(
                  label: '${src.slug} · ${src.tokenPrefix}…',
                  value: code,
                  onCopied: () => widget.store.showToast('已复制片段'),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: FilledButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('完成'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openRenameDeviceDialog(DinglinDevice dev) async {
    final ctrl = TextEditingController(text: dev.name);
    await showAppleAdaptiveModal<void>(
      context: context,
      title: '重命名设备',
      showClose: true,
      maxWidth: 380,
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: appleInputDecoration(t, hint: '设备名称'),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final next = ctrl.text.trim();
                    if (next.isEmpty) {
                      widget.store.showToast('设备名称不能为空', isError: true);
                      return;
                    }
                    try {
                      await widget.store.updateDevice(dev.id, name: next);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      widget.store.showToast(e.toString(), isError: true);
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        );
      },
    );
    ctrl.dispose();
  }

  Future<void> _showTokenDialog({
    required String title,
    required String token,
    String? secret,
  }) async {
    await showAppleAdaptiveModal<void>(
      context: context,
      title: title,
      showClose: true,
      maxWidth: 440,
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CopyBox(
              label: 'Bearer Token',
              value: token,
              onCopied: () => widget.store.showToast('已复制 Token'),
            ),
            if (secret != null && secret.isNotEmpty) ...[
              const SizedBox(height: 10),
              _CopyBox(
                label: 'Webhook Secret',
                value: secret,
                onCopied: () => widget.store.showToast('已复制 Secret'),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('完成'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openPairingCodeModal() async {
    try {
      final res = await widget.store.createPairingCode();
      if (!mounted) return;
      await showAppleAdaptiveModal<void>(
        context: context,
        title: '设备配对码',
        showClose: true,
        maxWidth: 360,
        padding: const EdgeInsets.all(24),
        builder: (_) => _PairingCodeContent(
          code: res.code,
          expiresAt: res.expiresAt,
          onCopied: () => widget.store.showToast('已复制配对码'),
        ),
      );
    } catch (e) {
      widget.store.showToast(e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final store = widget.store;
    final hasGateway =
        store.serverUrl.isNotEmpty && store.authToken.isNotEmpty;

    return Column(
      children: [
        const AppleTopBar(title: '设置'),
        Expanded(
          child: RefreshIndicator(
            color: t.accent,
            onRefresh: store.refreshAll,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. Gateway Connection
                        Row(
                          children: [
                            const _SectionTitle('网关连接'),
                            const Spacer(),
                            _GatewayStatusPill(status: store.connectionStatus),
                          ],
                        ),
                        AppleCardGroup(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: AppleSegmentedControl<bool>(
                                    value: _pairMode,
                                    options: const [
                                      (value: false, label: 'Token'),
                                      (value: true, label: '配对码'),
                                    ],
                                    onChanged: (v) =>
                                        setState(() => _pairMode = v),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _urlCtrl,
                                  onChanged: (_) => _dirtyGateway = true,
                                  decoration:
                                      appleInputDecoration(t, hint: '网关地址'),
                                ),
                                const SizedBox(height: 10),
                                if (!_pairMode)
                                  TextField(
                                    controller: _tokenCtrl,
                                    obscureText: true,
                                    onChanged: (_) => _dirtyGateway = true,
                                    decoration: appleInputDecoration(
                                      t,
                                      hint: 'Master Key / Token',
                                    ),
                                  )
                                else
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _pairCodeCtrl,
                                          decoration: appleInputDecoration(
                                            t,
                                            hint: '6 位配对码',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: TextField(
                                          controller: _deviceNameCtrl,
                                          decoration: appleInputDecoration(
                                            t,
                                            hint: '设备名称',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (hasGateway) ...[
                                      AppleIconButton(
                                        icon: AppIconName.disconnect,
                                        tooltip: '断开网关',
                                        danger: true,
                                        onPressed: _disconnectGateway,
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    FilledButton(
                                      onPressed: _busy ? null : _connect,
                                      style: FilledButton.styleFrom(
                                        backgroundColor: t.accent,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: Text(_busy ? '连接中…' : '连接'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),

                        // 2. Reception Policy & Permissions
                        const _SectionTitle('接收策略与权限'),
                        AppleCardGroup(
                          dividerIndent: 16,
                          children: store.platform.supportsKeepAlive
                              ? _buildAndroidReceptionChildren(t, store)
                              : _buildWebReceptionChildren(t, store),
                        ),
                        const SizedBox(height: 22),

                        // 3. Sources
                        Row(
                          children: [
                            const _SectionTitle('消息来源'),
                            const Spacer(),
                            AppleIconButton(
                              icon: AppIconName.plus,
                              tooltip: '新建来源',
                              onPressed: () => _openSourceEditorDialog(),
                            ),
                          ],
                        ),
                        AppleCardGroup(
                          dividerIndent: 16,
                          children: store.sources.isEmpty
                              ? [
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      '暂无来源',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: t.inkTertiary,
                                      ),
                                    ),
                                  ),
                                ]
                              : [
                                  for (final src in store.sources)
                                    _buildSourceRow(t, store, src),
                                ],
                        ),
                        const SizedBox(height: 22),

                        // 4. Devices
                        Row(
                          children: [
                            const _SectionTitle('已绑定设备'),
                            const Spacer(),
                            AppleIconButton(
                              icon: AppIconName.qrCode,
                              tooltip: '生成配对码',
                              onPressed: _openPairingCodeModal,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        AppleCardGroup(
                          dividerIndent: 16,
                          children: store.devices.isEmpty
                              ? [
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      '暂无绑定设备',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: t.inkTertiary,
                                      ),
                                    ),
                                  ),
                                ]
                              : [
                                  for (final dev in store.devices)
                                    _buildDeviceRow(t, store, dev),
                                ],
                        ),
                        const SizedBox(height: 22),

                        // 5. Policy & Appearance
                        const _SectionTitle('策略与外观'),
                        AppleCardGroup(
                          dividerIndent: 16,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    '外观',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: t.inkPrimary,
                                    ),
                                  ),
                                  const Spacer(),
                                  AppleSegmentedControl<ThemePreference>(
                                    value: store.themePreference,
                                    options: const [
                                      (
                                        value: ThemePreference.system,
                                        label: '系统'
                                      ),
                                      (
                                        value: ThemePreference.light,
                                        label: '浅色'
                                      ),
                                      (
                                        value: ThemePreference.dark,
                                        label: '深色'
                                      ),
                                    ],
                                    onChanged: store.setThemePreference,
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    '免打扰时段',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: t.inkPrimary,
                                    ),
                                  ),
                                  const Spacer(),
                                  AppleSwitch(
                                    value: _dndEnabled,
                                    semanticsLabel: '免打扰',
                                    onChanged: (v) => setState(() {
                                      _dirtyPolicy = true;
                                      _dndEnabled = v;
                                    }),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _dndStartCtrl,
                                          onChanged: (_) => _dirtyPolicy = true,
                                          decoration: appleInputDecoration(
                                            t,
                                            hint: '开始',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: TextField(
                                          controller: _dndEndCtrl,
                                          onChanged: (_) => _dirtyPolicy = true,
                                          decoration: appleInputDecoration(
                                            t,
                                            hint: '结束',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _snoozeCtrl,
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => _dirtyPolicy = true,
                                          decoration: appleInputDecoration(
                                            t,
                                            hint: '默认贪睡',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: TextField(
                                          controller: _retentionCtrl,
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => _dirtyPolicy = true,
                                          decoration: appleInputDecoration(
                                            t,
                                            hint: '保留天数',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: FilledButton(
                                      onPressed: _savePolicy,
                                      style: FilledButton.styleFrom(
                                        backgroundColor: t.accent,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: const Text('保存'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildAndroidReceptionChildren(AppleTokens t, AppStore store) {
    final perms = store.permissionStatus;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            AppIcon(
              AppIconName.sliders,
              size: 16,
              color: t.inkSecondary,
              semanticsLabel: '接收策略',
            ),
            const SizedBox(width: 10),
            Text(
              '接收策略',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: t.inkPrimary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: AppleSegmentedControl<KeepAliveMode>(
                  value: store.keepAliveConfig.mode,
                  options: const [
                    (value: KeepAliveMode.auto, label: '自动'),
                    (value: KeepAliveMode.ws, label: '仅 WS'),
                    (value: KeepAliveMode.polling, label: '定时拉取'),
                  ],
                  onChanged: (mode) async {
                    try {
                      await store.setKeepAliveMode(mode);
                    } catch (e) {
                      store.showToast(e.toString(), isError: true);
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      if (store.keepAliveConfig.isPolling)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(
                '拉取间隔',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: t.inkPrimary,
                ),
              ),
              const Spacer(),
              AppleSegmentedControl<int>(
                value: store.keepAliveConfig.intervalMinutes,
                options: const [
                  (value: 5, label: '5m'),
                  (value: 15, label: '15m'),
                  (value: 30, label: '30m'),
                ],
                onChanged: (mins) async {
                  try {
                    await store.setKeepAliveInterval(mins);
                  } catch (e) {
                    store.showToast(e.toString(), isError: true);
                  }
                },
              ),
            ],
          ),
        ),
      for (final item in [
        ('notifications', '通知权限', perms.notifications),
        ('battery_optimization', '忽略电池优化', perms.batteryOptimization),
        ('exact_alarm', '精确闹钟', perms.exactAlarm),
        ('full_screen_intent', '锁屏全屏提醒', perms.fullScreenIntent),
      ])
        _PermissionRow(
          label: item.$2,
          granted: item.$3,
          onRequest: () async {
            try {
              await store.requestPermission(item.$1);
            } catch (e) {
              store.showToast(e.toString(), isError: true);
            }
          },
        ),
      if (store.supportsAutoStartSettings)
        ApplePressable(
          onTap: () async {
            try {
              await store.requestPermission('auto_start');
            } catch (e) {
              store.showToast(e.toString(), isError: true);
            }
          },
          pressedScale: 0.99,
          builder: (context, hovered, pressed) => Container(
            color: pressed
                ? t.bgPressed
                : hovered
                    ? t.bgHover
                    : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                AppIcon(
                  AppIconName.rocket,
                  size: 15,
                  color: t.accent,
                  semanticsLabel: '后台自启动',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '后台自启动',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: t.inkPrimary,
                    ),
                  ),
                ),
                AppIcon(
                  AppIconName.chevronRight,
                  size: 15,
                  color: t.inkTertiary,
                  semanticsLabel: '前往后台自启动设置',
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildWebReceptionChildren(AppleTokens t, AppStore store) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            AppIcon(
              AppIconName.sliders,
              size: 16,
              color: t.inkSecondary,
              semanticsLabel: '推送通道',
            ),
            const SizedBox(width: 10),
            Text(
              '推送通道',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: t.inkPrimary,
              ),
            ),
            const Spacer(),
            ApplePill(
              label: 'WS',
              background: t.bgSelected,
              foreground: t.accent,
            ),
          ],
        ),
      ),
      _PermissionRow(
        label: '浏览器通知',
        granted: store.permissionStatus.notifications,
        onRequest: () async {
          try {
            await store.requestPermission('notifications');
          } catch (e) {
            store.showToast(e.toString(), isError: true);
          }
        },
      ),
    ];
  }

  Widget _buildSourceRow(AppleTokens t, AppStore store, DinglinSource src) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: parseHexColor(src.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      src.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: t.inkPrimary,
                      ),
                    ),
                    ApplePill(
                      label: src.kind == 'agent' ? 'MCP' : 'Webhook',
                      background: t.bgSurfaceSecondary,
                      foreground: t.inkSecondary,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${src.slug} · ${src.tokenPrefix}…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Wrap(
            spacing: 2,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppleSwitch(
                value: src.enabled,
                semanticsLabel: src.name,
                onChanged: (v) async {
                  try {
                    await store.updateSource(src.id, enabled: v);
                  } catch (e) {
                    store.showToast(e.toString(), isError: true);
                  }
                },
              ),
              AppleIconButton(
                icon: AppIconName.code,
                tooltip: '接入片段',
                onPressed: () => _openSourceSnippetDialog(src),
              ),
              AppleIconButton(
                icon: AppIconName.edit,
                tooltip: '编辑来源',
                onPressed: () => _openSourceEditorDialog(existing: src),
              ),
              AppleIconButton(
                icon: AppIconName.rotate,
                tooltip: '轮换 Token',
                onPressed: () async {
                  try {
                    final tok = await store.rotateSourceToken(src.id);
                    if (mounted) {
                      await _showTokenDialog(
                        title: '新 Token（仅展示一次）',
                        token: tok,
                      );
                    }
                  } catch (e) {
                    store.showToast(e.toString(), isError: true);
                  }
                },
              ),
              AppleIconButton(
                icon: AppIconName.trash,
                tooltip: '删除来源',
                danger: true,
                onPressed: () async {
                  final ok = await showAppleConfirmDialog(
                    context,
                    title: '删除来源',
                    message: '确认删除「${src.name}」？关联的推送 Token 将立即失效。',
                    confirmLabel: '删除',
                  );
                  if (ok) {
                    try {
                      await store.deleteSource(src.id);
                    } catch (e) {
                      store.showToast(e.toString(), isError: true);
                    }
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceRow(AppleTokens t, AppStore store, DinglinDevice dev) {
    final isCurrent = dev.id.isNotEmpty && dev.id == store.deviceId;
    final isRemoteAndroid = !isCurrent && dev.platform.toLowerCase() == 'android';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppIcon(
            AppIconName.device,
            size: 18,
            color: dev.online ? t.success : t.inkTertiary,
            semanticsLabel: dev.name,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      dev.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: t.inkPrimary,
                      ),
                    ),
                    if (isCurrent)
                      ApplePill(
                        label: '本机',
                        background: t.bgSurfaceSecondary,
                        foreground: t.inkSecondary,
                      ),
                    if (!isRemoteAndroid)
                      ApplePill(
                        label: dev.pushMode.toUpperCase(),
                        background: t.bgSelected,
                        foreground: t.accent,
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${dev.online ? '在线' : '离线'} · ${dev.platform}',
                  style: TextStyle(
                    fontSize: 12,
                    color: t.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isRemoteAndroid)
                AppleSegmentedControl<String>(
                  compact: true,
                  value: dev.pushMode == 'fcm' ? 'fcm' : 'ws',
                  options: const [
                    (value: 'ws', label: 'WS'),
                    (value: 'fcm', label: 'FCM'),
                  ],
                  disabledValues:
                      dev.hasFcmToken ? const <String>{} : const {'fcm'},
                  onDisabledSelected: (_) => store.showToast(
                    '该设备尚未上报 FCM Token',
                    isError: true,
                  ),
                  onChanged: (mode) async {
                    try {
                      await store.updateDevice(dev.id, pushMode: mode);
                    } catch (e) {
                      store.showToast(e.toString(), isError: true);
                    }
                  },
                ),
              AppleIconButton(
                icon: AppIconName.edit,
                tooltip: '重命名设备',
                onPressed: () => _openRenameDeviceDialog(dev),
              ),
              AppleIconButton(
                icon: AppIconName.send,
                tooltip: '测试推送',
                onPressed: () async {
                  try {
                    await store.testDevicePush(dev.id);
                  } catch (e) {
                    store.showToast(e.toString(), isError: true);
                  }
                },
              ),
              AppleIconButton(
                icon: AppIconName.trash,
                tooltip: '解绑设备',
                danger: true,
                onPressed: () async {
                  final ok = await showAppleConfirmDialog(
                    context,
                    title: '解绑设备',
                    message: '确认解绑「${dev.name}」？该设备的访问令牌将被吊销。',
                    confirmLabel: '解绑',
                  );
                  if (ok) {
                    try {
                      await store.deleteDevice(dev.id);
                    } catch (e) {
                      store.showToast(e.toString(), isError: true);
                    }
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.label,
    required this.granted,
    required this.onRequest,
  });

  final String label;
  final bool granted;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: granted ? t.success : t.warning,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: t.inkPrimary,
              ),
            ),
          ),
          if (granted)
            Tooltip(
              message: '已授权',
              child: AppIcon(
                AppIconName.checkCircle,
                size: 18,
                color: t.success,
                semanticsLabel: '$label已授权',
              ),
            )
          else
            Tooltip(
              message: '授权 $label',
              child: ApplePressable(
                onTap: onRequest,
                pressedScale: 0.94,
                builder: (context, hovered, pressed) => AnimatedContainer(
                  duration: AppleTokens.motionFast,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: pressed
                        ? t.bgPressed
                        : hovered
                            ? t.bgSelected
                            : t.warningBg,
                    borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        AppIconName.shield,
                        size: 14,
                        color: hovered ? t.accent : t.warning,
                        semanticsLabel: '授权 $label',
                      ),
                      const SizedBox(width: 2),
                      AppIcon(
                        AppIconName.chevronRight,
                        size: 13,
                        color: hovered ? t.accent : t.warning,
                        semanticsLabel: '前往授权',
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GatewayStatusPill extends StatelessWidget {
  const _GatewayStatusPill({required this.status});
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final (label, bg, fg) = switch (status) {
      ConnectionStatus.connected => ('已连接', t.successBg, t.success),
      ConnectionStatus.reconnecting => ('重连中', t.warningBg, t.warning),
      ConnectionStatus.offline => ('离线', t.criticalBg, t.critical),
      ConnectionStatus.unconfigured => (
          '未配置',
          t.bgSurfaceSecondary,
          t.inkSecondary
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ApplePill(label: label, background: bg, foreground: fg),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: t.inkSecondary,
        ),
      ),
    );
  }
}

class _CopyBox extends StatelessWidget {
  const _CopyBox({
    required this.label,
    required this.value,
    required this.onCopied,
  });

  final String label;
  final String value;
  final VoidCallback onCopied;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: t.inkSecondary)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: t.bgSurfaceSecondary,
            borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
            border: Border.all(color: t.borderHairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: t.inkPrimary,
                  ),
                ),
              ),
              AppleIconButton(
                icon: AppIconName.copy,
                tooltip: '复制',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  onCopied();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PairingCodeContent extends StatefulWidget {
  const _PairingCodeContent({
    required this.code,
    required this.expiresAt,
    required this.onCopied,
  });

  final String code;
  final DateTime expiresAt;
  final VoidCallback onCopied;

  @override
  State<_PairingCodeContent> createState() => _PairingCodeContentState();
}

class _PairingCodeContentState extends State<_PairingCodeContent> {
  Timer? _timer;
  int _remaining = 300;

  @override
  void initState() {
    super.initState();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _update());
  }

  void _update() {
    final diff = widget.expiresAt.difference(DateTime.now().toUtc()).inSeconds;
    if (mounted) {
      setState(() => _remaining = diff > 0 ? diff : 0);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final mins = _remaining ~/ 60;
    final secs = _remaining % 60;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.code,
          style: AppleTokens.tabular.copyWith(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: 6,
            color: t.accent,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}',
          style: AppleTokens.tabular.copyWith(
            fontSize: 13,
            color: t.inkSecondary,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppleActionChip(
              icon: AppIconName.copy,
              label: '复制',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.code));
                widget.onCopied();
              },
            ),
            const SizedBox(width: 8),
            AppleActionChip(
              label: '关闭',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ],
    );
  }
}
