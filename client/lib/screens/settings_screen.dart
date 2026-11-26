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
  }

  @override
  void dispose() {
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
    } catch (e) {
      widget.store.showToast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePolicy() async {
    final next = widget.store.settings.copyWith(
      dndEnabled: _dndEnabled,
      dndStart: _dndStartCtrl.text.trim(),
      dndEnd: _dndEndCtrl.text.trim(),
      defaultSnoozeMinutes: int.tryParse(_snoozeCtrl.text.trim()) ?? 10,
      retentionDays: int.tryParse(_retentionCtrl.text.trim()) ?? 30,
    );
    try {
      await widget.store.saveSettings(next);
    } catch (e) {
      widget.store.showToast(e.toString());
    }
  }

  Future<void> _openCreateSourceDialog() async {
    final nameCtrl = TextEditingController();
    final slugCtrl = TextEditingController();
    final cbCtrl = TextEditingController();
    var kind = 'webhook';
    var color = '#007AFF';

    final created = await showDialog<dynamic>(
      context: context,
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setLocal) => Dialog(
            backgroundColor: t.bgSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
              side: BorderSide(color: t.borderHairline),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '新建消息来源',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: t.inkPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    AppleSegmentedControl<String>(
                      value: kind,
                      options: const [
                        (value: 'webhook', label: 'Webhook'),
                        (value: 'agent', label: 'Agent / MCP'),
                      ],
                      onChanged: (v) => setLocal(() => kind = v),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: _dec(t, '名称（如 GitHub Actions）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: slugCtrl,
                      decoration: _dec(t, '标识（小写字母/数字，如 github-ci）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: cbCtrl,
                      decoration: _dec(t, '回调 URL（可选）'),
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
                          GestureDetector(
                            onTap: () => setLocal(() => color = hex),
                            child: Container(
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
                            try {
                              final res = await widget.store.createSource(
                                name: nameCtrl.text.trim(),
                                slug: slugCtrl.text.trim(),
                                kind: kind,
                                color: color,
                                callbackUrl: cbCtrl.text.trim(),
                              );
                              if (ctx.mounted) Navigator.pop(ctx, res);
                            } catch (e) {
                              widget.store.showToast(e.toString());
                            }
                          },
                          child: const Text('创建'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (created != null && mounted) {
      await _showTokenDialog(
        title: '来源凭据（仅展示一次）',
        token: created.token as String,
        secret: created.callbackSecret as String,
      );
    }
  }

  Future<void> _showTokenDialog({
    required String title,
    required String token,
    String? secret,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return Dialog(
          backgroundColor: t.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
            side: BorderSide(color: t.borderHairline),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: t.inkPrimary,
                    ),
                  ),
                  const SizedBox(height: 14),
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
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPairingCodeModal() async {
    try {
      final res = await widget.store.createPairingCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _PairingCodeDialog(
          code: res.code,
          expiresAt: res.expiresAt,
          onCopied: () => widget.store.showToast('已复制配对码'),
        ),
      );
    } catch (e) {
      widget.store.showToast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final store = widget.store;

    return Column(
      children: [
        FrostedSurface(
          color: t.bgTopbar,
          border: Border(bottom: BorderSide(color: t.borderHairline)),
          child: SizedBox(
            height: AppleTokens.topbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '设置',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                      color: t.inkPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. Gateway Connection
                      const _SectionTitle('网关连接'),
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
                                    (value: false, label: 'Master Key / Token'),
                                    (value: true, label: '6 位配对码'),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _pairMode = v),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _urlCtrl,
                                decoration:
                                    _dec(t, '网关地址（如 http://127.0.0.1:8080）'),
                              ),
                              const SizedBox(height: 10),
                              if (!_pairMode)
                                TextField(
                                  controller: _tokenCtrl,
                                  obscureText: true,
                                  decoration: _dec(t, 'Master Key 或设备 Token'),
                                )
                              else
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _pairCodeCtrl,
                                        decoration: _dec(t, '6 位配对码'),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextField(
                                        controller: _deviceNameCtrl,
                                        decoration: _dec(t, '设备名称'),
                                      ),
                                    ),
                                  ],
                                ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FilledButton(
                                  onPressed: _busy ? null : _connect,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: t.accent,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: Text(_busy ? '连接中…' : '连接'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),

                      // 2. Sources
                      Row(
                        children: [
                          const _SectionTitle('消息来源'),
                          const Spacer(),
                          AppleIconButton(
                            icon: AppIconName.plus,
                            tooltip: '新建来源',
                            onPressed: _openCreateSourceDialog,
                          ),
                        ],
                      ),
                      AppleCardGroup(
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
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
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
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    src.name,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: t.inkPrimary,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  ApplePill(
                                                    label: src.kind == 'agent'
                                                        ? 'MCP'
                                                        : 'Webhook',
                                                    background:
                                                        t.bgSurfaceSecondary,
                                                    foreground: t.inkSecondary,
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                '${src.slug} · ${src.tokenPrefix}…',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: t.inkSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        AppleSwitch(
                                          value: src.enabled,
                                          semanticsLabel: src.name,
                                          onChanged: (v) => store.updateSource(
                                            src.id,
                                            enabled: v,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        AppleIconButton(
                                          icon: AppIconName.rotate,
                                          tooltip: '轮换 Token',
                                          onPressed: () async {
                                            final tok = await store
                                                .rotateSourceToken(src.id);
                                            if (mounted) {
                                              await _showTokenDialog(
                                                title: '新 Token（仅展示一次）',
                                                token: tok,
                                              );
                                            }
                                          },
                                        ),
                                        AppleIconButton(
                                          icon: AppIconName.trash,
                                          tooltip: '删除来源',
                                          danger: true,
                                          onPressed: () =>
                                              store.deleteSource(src.id),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                      ),
                      const SizedBox(height: 22),

                      // 3. Devices
                      Row(
                        children: [
                          const _SectionTitle('已绑定设备'),
                          const Spacer(),
                          AppleActionChip(
                            icon: AppIconName.plus,
                            label: '生成配对码',
                            onPressed: _openPairingCodeModal,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      AppleCardGroup(
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
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        AppIcon(
                                          AppIconName.device,
                                          size: 18,
                                          color: dev.online
                                              ? t.success
                                              : t.inkTertiary,
                                          semanticsLabel: dev.name,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    dev.name,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: t.inkPrimary,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  ApplePill(
                                                    label: dev.pushMode
                                                        .toUpperCase(),
                                                    background: t.bgSelected,
                                                    foreground: t.accent,
                                                  ),
                                                ],
                                              ),
                                              Text(
                                                dev.online ? '在线' : '离线',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: t.inkSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        AppleIconButton(
                                          icon: AppIconName.send,
                                          tooltip: '测试推送',
                                          onPressed: () =>
                                              store.testDevicePush(dev.id),
                                        ),
                                        AppleIconButton(
                                          icon: AppIconName.trash,
                                          tooltip: '解绑设备',
                                          danger: true,
                                          onPressed: () =>
                                              store.deleteDevice(dev.id),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                      ),
                      const SizedBox(height: 22),

                      // 4. Policy & Appearance
                      const _SectionTitle('策略与外观'),
                      AppleCardGroup(
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
                                    (value: ThemePreference.system, label: '系统'),
                                    (value: ThemePreference.light, label: '浅色'),
                                    (value: ThemePreference.dark, label: '深色'),
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
                                  onChanged: (v) =>
                                      setState(() => _dndEnabled = v),
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
                                        decoration: _dec(t, '开始（23:00）'),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextField(
                                        controller: _dndEndCtrl,
                                        decoration: _dec(t, '结束（07:00）'),
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
                                        decoration: _dec(t, '默认贪睡（分钟）'),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextField(
                                        controller: _retentionCtrl,
                                        keyboardType: TextInputType.number,
                                        decoration: _dec(t, '消息保留（天）'),
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
                                    child: const Text('保存策略'),
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
      ],
    );
  }

  InputDecoration _dec(AppleTokens t, String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 13, color: t.inkTertiary),
      filled: true,
      fillColor: t.bgSurfaceSecondary,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
        borderSide: BorderSide(color: t.borderHairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
        borderSide: BorderSide(color: t.borderHairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
        borderSide: BorderSide(color: t.accent),
      ),
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

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({
    required this.code,
    required this.expiresAt,
    required this.onCopied,
  });

  final String code;
  final DateTime expiresAt;
  final VoidCallback onCopied;

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
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
    return Dialog(
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
        side: BorderSide(color: t.borderHairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '设备配对码',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: t.inkPrimary,
              ),
            ),
            const SizedBox(height: 16),
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
        ),
      ),
    );
  }
}
