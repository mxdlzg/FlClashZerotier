import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// FlClashTier: ZeroTier 网络设置页（独立栏目）。
///
/// 写入 `HomeDir/zerotier.json`（Go core 在 TUN 启动时读取；改动后重启 VPN 生效）。
/// 支持多网络：`"network-ids": ["id1", "id2", ...]`，同一个 ZT 节点同时加入
/// 全部网络，各自内网流量都走 ZeroTier。清空全部 = 禁用 ZeroTier（纯 mihomo
/// 模式，与 M0 行为一致）。旧版单 `network-id` 配置自动兼容读取。
///
/// 私有 Planet（自建根服务器）：
/// - planet 文件保存到 `HomeDir/zerotier-planet.custom`；
/// - `zerotier.json` 增加 `"use-custom-planet": true`；
/// - Go core StartEngine 在创建 ZT 节点前把该文件装入 C wrapper，
///   ZT core 的 stateGet(PLANET) 将返回私有 planet 而非内置官方 planet；
/// - planet 是节点级的：所有已加入网络共用同一个 planet。
class ZeroTierView extends ConsumerStatefulWidget {
  const ZeroTierView({super.key});

  @override
  ConsumerState<ZeroTierView> createState() => _ZeroTierViewState();
}

class _ZeroTierViewState extends ConsumerState<ZeroTierView> {
  /// Planet 文件头校验：world type 0x01 = planet（0x02 = moon）。
  static const int _planetMaxBytes = 8192;

  /// ZeroTier Network ID 必须是 16 位十六进制。
  static final RegExp _nwidRegExp = RegExp(r'^[0-9a-fA-F]{16}$');

  /// 路由模式取值（写入 zerotier.json 的 route-mode，与 Go core 一一对应）。
  static const String _modeClash = 'clash';
  static const String _modeZerotier = 'zerotier';
  static const String _modeCoexist = 'coexist';
  static const String _modeClashOverZerotier = 'clash-over-zerotier';

  /// 每个已配置网络一个输入框（动态增删）。
  final List<TextEditingController> _nwidControllers = [];
  Timer? _debounce;
  String _status = '';

  String _routeMode = _modeCoexist;
  bool _useCustomPlanet = false;
  int _planetFileSize = -1; // -1 = 未导入
  bool _planetBusy = false;

  Map<String, dynamic>? _ztStatus;
  Timer? _ztPoller;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshZtStatus();
    _ztPoller = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshZtStatus(),
    );
  }

  Future<void> _refreshZtStatus() async {
    try {
      final data = await coreController.getZeroTierStatus();
      if (mounted && data != null) {
        setState(() => _ztStatus = data);
      }
    } catch (_) {
      // core 未初始化/方法不可用时静默，下一次轮询自然恢复。
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ztPoller?.cancel();
    for (final c in _nwidControllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- paths / config io ----

  Future<String> _homeDir() => appPath.homeDirPath;

  Future<File> _configFile() async {
    return File(p.join(await _homeDir(), 'zerotier.json'));
  }

  Future<File> _planetFile() async {
    return File(p.join(await _homeDir(), 'zerotier-planet.custom'));
  }

  Future<Map<String, dynamic>> _readConfig() async {
    try {
      final file = await _configFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) return json;
      }
    } catch (_) {
      // 文件缺失/损坏 → 视为空配置
    }
    return <String, dynamic>{};
  }

  /// 合并写回：保留未知字段，network-id 为空时移除该字段；
  /// 配置完全为空时才删除文件（Go core 将缺失文件解释为禁用 ZeroTier）。
  /// 注意：即使 network-id 暂时为空，也保留 use-custom-planet 等其余字段，
  /// 避免用户先导入 planet、后填 Network ID 时丢失开关状态。
  Future<void> _writeConfig(Map<String, dynamic> patch) async {
    final cfg = await _readConfig();
    cfg.addAll(patch);
    final nwid = (cfg['network-id'] as String?) ?? '';
    if (nwid.isEmpty) {
      cfg.remove('network-id');
    }
    final file = await _configFile();
    if (cfg.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString('${jsonEncode(cfg)}\n');
  }

  Future<void> _load() async {
    final cfg = await _readConfig();
    // 多网络字段优先；旧版单 network-id 配置回退兼容。
    final ids = <String>[];
    final rawList = cfg['network-ids'];
    if (rawList is List) {
      for (final e in rawList) {
        final s = (e is String ? e : '').trim();
        if (s.isNotEmpty) ids.add(s);
      }
    } else {
      final legacy = ((cfg['network-id'] as String?) ?? '').trim();
      if (legacy.isNotEmpty) ids.add(legacy);
    }
    final planet = await _planetFile();
    _routeMode = _normalizeMode(cfg['route-mode'] as String?);
    _useCustomPlanet = (cfg['use-custom-planet'] as bool?) ?? false;
    _planetFileSize = await planet.exists() ? await planet.length() : -1;
    for (final c in _nwidControllers) {
      c.dispose();
    }
    _nwidControllers.clear();
    for (final id in ids) {
      _nwidControllers.add(TextEditingController(text: id));
    }
    if (_nwidControllers.isEmpty) {
      // 始终保留一个空行供直接输入。
      _nwidControllers.add(TextEditingController());
    }
    _status = ids.isEmpty
        ? 'ZeroTier disabled (mihomo only)'
        : 'ZeroTier networks: ${ids.join(', ')}';
    if (mounted) setState(() {});
  }

  /// 归一化 route-mode；未知/缺失值回落默认的共存模式（与 Go core 一致）。
  String _normalizeMode(String? value) {
    switch (value) {
      case _modeClash:
      case _modeZerotier:
      case _modeClashOverZerotier:
        return value!;
      default:
        return _modeCoexist;
    }
  }

  Future<void> _saveRouteMode(String value) async {
    try {
      await _writeConfig({'route-mode': value});
      _routeMode = value;
      _status = '路由模式已保存 — restart VPN to apply';
      if (mounted) setState(() {});
    } catch (err) {
      _status = 'save failed: $err';
      if (mounted) setState(() {});
    }
  }

  /// 收集所有输入框 → 校验 → 写入 `network-ids`（并移除旧版单字段）。
  Future<void> _saveNwids() async {
    final ids = <String>[];
    for (final c in _nwidControllers) {
      final id = c.text.trim();
      if (id.isEmpty) continue;
      if (!_nwidRegExp.hasMatch(id)) {
        setState(() {
          _status = '无效：Network ID 必须是 16 位十六进制'
              '（"$id" 为 ${id.length} 位），未保存';
        });
        return;
      }
      ids.add(id.toLowerCase());
    }
    // 去重（保持顺序）。
    final seen = <String>{};
    final uniq = <String>[];
    for (final id in ids) {
      if (seen.add(id)) uniq.add(id);
    }
    try {
      await _writeNetworkIds(uniq);
      _status = uniq.isEmpty
          ? 'ZeroTier disabled (mihomo only)'
          : 'saved ${uniq.length} network(s) — restart VPN to apply';
      if (mounted) setState(() {});
    } catch (err) {
      _status = 'save failed: $err';
      if (mounted) setState(() {});
    }
  }

  /// 写回网络列表：空列表移除字段（= 禁用）；同时迁移掉旧版 network-id。
  Future<void> _writeNetworkIds(List<String> ids) async {
    final cfg = await _readConfig();
    cfg.remove('network-id');
    if (ids.isEmpty) {
      cfg.remove('network-ids');
    } else {
      cfg['network-ids'] = ids;
    }
    final file = await _configFile();
    if (cfg.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString('${jsonEncode(cfg)}\n');
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _saveNwids);
  }

  void _addNwid() {
    setState(() {
      _nwidControllers.add(TextEditingController());
    });
  }

  Future<void> _removeNwid(int i) async {
    _debounce?.cancel();
    setState(() {
      _nwidControllers[i].dispose();
      _nwidControllers.removeAt(i);
    });
    // 删除即生效保存（空列表 = 禁用）。
    await _saveNwids();
  }

  // ---- private planet ----

  /// 校验 planet（world）文件：首字节 0x01 = planet，且不超过大小上限。
  String? _validatePlanet(Uint8List bytes) {
    if (bytes.isEmpty) return 'planet 文件为空';
    if (bytes.lengthInBytes > _planetMaxBytes) {
      return 'planet 文件过大（>$_planetMaxBytes 字节）';
    }
    if (bytes[0] != 0x01) {
      return '文件格式错误：首字节应为 0x01（planet），当前为 0x${bytes[0].toRadixString(16).padLeft(2, '0')}';
    }
    return null;
  }

  Future<void> _installPlanet(Uint8List bytes) async {
    final err = _validatePlanet(bytes);
    if (err != null) {
      throw err;
    }
    final file = await _planetFile();
    await file.safeWriteAsBytes(bytes);
    await _writeConfig({'use-custom-planet': true});
    _useCustomPlanet = true;
    _planetFileSize = bytes.lengthInBytes;
  }

  Future<void> _toggleCustomPlanet(bool value) async {
    if (!value) {
      await _writeConfig({'use-custom-planet': false});
      setState(() => _useCustomPlanet = false);
      return;
    }
    if (_planetFileSize < 0) {
      // 还没有 planet 文件：引导用户先导入。
      setState(() => _useCustomPlanet = false);
      globalState.showMessage(
        title: '私有 Planet',
        message: const TextSpan(
          text: '请先导入私有 planet 文件（文件导入 / URL 导入），再开启此开关。',
        ),
      );
      return;
    }
    await _writeConfig({'use-custom-planet': true});
    setState(() => _useCustomPlanet = true);
  }

  Future<void> _importPlanetFromFile() async {
    try {
      setState(() => _planetBusy = true);
      final platformFile = await picker.pickerFile();
      if (platformFile == null) return;
      final bytes = await platformFile.readBytes();
      await _installPlanet(bytes);
      if (!mounted) return;
      globalState.showMessage(
        title: '私有 Planet',
        message: TextSpan(
          text: '已导入 planet 文件（${bytes.lengthInBytes} 字节）。'
              '重启 VPN 后生效。',
        ),
      );
    } catch (e) {
      if (mounted) {
        globalState.showMessage(
          title: '私有 Planet',
          message: TextSpan(text: '导入失败：$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _planetBusy = false);
    }
  }

  Future<void> _importPlanetFromUrl() async {
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从 URL 导入 Planet'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://example.com/planet',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.appLocalizations.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(urlController.text),
            child: Text(context.appLocalizations.confirm),
          ),
        ],
      ),
    );
    urlController.dispose();
    if (url == null || url.trim().isEmpty) return;

    try {
      setState(() => _planetBusy = true);
      // 走裸 dio（不经 clash 代理）：planet 通常托管在公网/内网直连可达处，
      // 且 VPN 未启动时也不应依赖代理链路。
      final response = await request.dio.get<Uint8List>(
        url.trim(),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw '下载内容为空';
      }
      await _installPlanet(bytes);
      if (!mounted) return;
      globalState.showMessage(
        title: '私有 Planet',
        message: TextSpan(
          text: '已导入 planet 文件（${bytes.lengthInBytes} 字节）。'
              '重启 VPN 后生效。',
        ),
      );
    } catch (e) {
      if (mounted) {
        globalState.showMessage(
          title: '私有 Planet',
          message: TextSpan(text: '下载失败：$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _planetBusy = false);
    }
  }

  Future<void> _removePlanet() async {
    final res = await globalState.showMessage(
      title: '私有 Planet',
      message: const TextSpan(
        text: '删除已导入的私有 planet 文件？删除后将自动切回官方 planet。',
      ),
    );
    if (res != true) return;
    try {
      final file = await _planetFile();
      await file.safeDelete();
      await _writeConfig({'use-custom-planet': false});
      setState(() {
        _planetFileSize = -1;
        _useCustomPlanet = false;
      });
    } catch (e) {
      if (mounted) {
        globalState.showMessage(
          title: '私有 Planet',
          message: TextSpan(text: '删除失败：$e'),
        );
      }
    }
  }

  // ---- ui ----

  String get _planetStatusText {
    if (_planetFileSize < 0) return '未导入（使用 ZeroTier 官方公共服务）';
    return '已导入（$_planetFileSize 字节）'
        '${_useCustomPlanet ? ' — 已启用，重启 VPN 生效' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BaseScaffold(
      title: 'ZeroTier',
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'ZeroTier 网络互联：先在下方选择路由模式，再配置 Network ID。'
              '不同模式决定流量在 ZeroTier 与 Clash 之间的分工，'
              '改动后重启 VPN 生效。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_ztStatus != null)
            _ZeroTierStatusCard(
              status: _ztStatus!,
              onRefresh: _refreshZtStatus,
            ),
          ListTile(
            title: const Text('ZeroTier Network ID'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '可同时加入多个网络（每行一个 Network ID），'
                  '全部留空 = 禁用。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < _nwidControllers.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _nwidControllers[i],
                      decoration: InputDecoration(
                        hintText: '16 位十六进制 Network ID',
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: '删除此行',
                          onPressed: () => _removeNwid(i),
                        ),
                      ),
                      style: theme.textTheme.bodyMedium,
                      onChanged: (_) => _scheduleSave(),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _addNwid,
                  icon: const Icon(Icons.add),
                  label: const Text('添加网络'),
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _status,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '路由模式（单选）',
              style: theme.textTheme.titleSmall,
            ),
          ),
          RadioListTile<String>(
            title: const Text('纯 Clash'),
            subtitle: const Text(
              '不启动 ZeroTier，行为与原版 FlClash 完全一致。',
            ),
            value: _modeClash,
            groupValue: _routeMode,
            onChanged: (value) {
              if (value != null) _saveRouteMode(value);
            },
          ),
          RadioListTile<String>(
            title: const Text('纯 ZeroTier'),
            subtitle: const Text(
              '全部流量优先走 ZeroTier（需 ZT 网络下发默认路由/出口）；'
              'ZT 未覆盖的流量直连，不经 Clash 代理。',
            ),
            value: _modeZerotier,
            groupValue: _routeMode,
            onChanged: (value) {
              if (value != null) _saveRouteMode(value);
            },
          ),
          RadioListTile<String>(
            title: const Text('共存互不影响（默认）'),
            subtitle: const Text(
              '命中 ZeroTier Managed Routes 的流量走 ZT 内网，'
              '其余流量交给 Clash 规则处理，两者互不干涉。',
            ),
            value: _modeCoexist,
            groupValue: _routeMode,
            onChanged: (value) {
              if (value != null) _saveRouteMode(value);
            },
          ),
          RadioListTile<String>(
            title: const Text('Clash 走 ZeroTier'),
            subtitle: const Text(
              '先由 Clash 规则决定去向，出站目标（代理服务器/直连目标）'
              '若命中 ZT 内网路由则改经 ZeroTier 承载——用于通过 ZT '
              '内网连接部署在局域网里的 Clash 节点。',
            ),
            value: _modeClashOverZerotier,
            groupValue: _routeMode,
            onChanged: (value) {
              if (value != null) _saveRouteMode(value);
            },
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '私有 Planet（自建 ZeroTier 根服务器）',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '默认连接 ZeroTier 官方公共 planet。如果你的网络部署在自建 '
              'planet（自托管 ztncui / ZeroTier 私有根）上，请在此导入你的 '
              'planet 文件并开启开关；否则节点将永远无法到达你的控制器。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          SwitchListTile(
            title: const Text('使用私有 Planet'),
            subtitle: Text(_planetStatusText),
            value: _useCustomPlanet,
            onChanged: _planetBusy ? null : _toggleCustomPlanet,
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('从文件导入 Planet'),
            enabled: !_planetBusy,
            onTap: _importPlanetFromFile,
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('从 URL 导入 Planet'),
            enabled: !_planetBusy,
            onTap: _importPlanetFromUrl,
          ),
          if (_planetFileSize >= 0)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除 Planet 文件'),
              enabled: !_planetBusy,
              onTap: _removePlanet,
            ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '使用步骤',
              style: theme.textTheme.titleSmall,
            ),
          ),
          const _StepText(
            '1. 先在「配置文件」页导入 Clash 配置（订阅链接/文件），'
            '此时首页才会出现启动 VPN 的按钮。',
          ),
          const _StepText(
            '2. 在本页填写 ZeroTier Network ID（可在 ZeroTier Central '
            '或你的自建控制器创建网络后获得）；需要进入多个内网时，'
            '点「添加网络」逐行填入每个网络的 ID。',
          ),
          const _StepText(
            '3. 自建网络：导入你的私有 planet 文件并开启「使用私有 Planet」。',
          ),
          const _StepText(
            '4. 启动 VPN（首次会弹出系统授权），然后在控制器上授权本机节点。',
          ),
          const _StepText(
            '5. 修改 Network ID / Planet / 路由模式后需重启 VPN 才生效；'
            '路由模式选「纯 Clash」或清空全部 Network ID 后为纯 mihomo 模式。',
          ),
        ],
      ),
    );
  }
}

class _StepText extends StatelessWidget {
  const _StepText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _ZeroTierStatusCard extends StatelessWidget {
  const _ZeroTierStatusCard({required this.status, required this.onRefresh});

  final Map<String, dynamic> status;
  final VoidCallback onRefresh;

  static const Map<int, String> _networkStatusNames = {
    0: 'REQUESTING_CONFIGURATION',
    1: 'OK',
    2: 'ACCESS_DENIED',
    3: 'NOT_FOUND',
    4: 'PORT_ERROR',
  };

  static const Map<int, String> _networkStatusHints = {
    0: '正在向控制器申请配置——planet 或网络可能不可达，稍后自动重试。',
    2: '控制器未授权本节点：请在控制器（ztncui / ZeroTier Central）的 '
        'Peer 列表勾选上面的节点地址并 Authorize。',
    3: '控制器上不存在该 Network ID，检查是否填错或网络已被删除。',
  };

  String get _statusText {
    final state = (status['state'] as String?) ?? 'STOPPED';
    if (state != 'RUNNING') {
      final configured = status['configured'] == true;
      if (!configured) {
        return '未启用（Network ID 为空）';
      }
      return '引擎 $state — 启动/重启 VPN 后连接';
    }
    final networks = (status['networks'] as List?) ?? const [];
    if (networks.isEmpty) {
      return '引擎 RUNNING — 尚未加入任何网络';
    }
    final first = networks.first;
    if (first is Map) {
      final s = (first['status'] as num?)?.toInt() ?? -1;
      return _networkStatusNames[s] ?? 'status=$s';
    }
    return 'RUNNING';
  }

  Color _statusColor(BuildContext context) {
    final state = (status['state'] as String?) ?? 'STOPPED';
    if (state != 'RUNNING') {
      return Colors.grey;
    }
    final networks = (status['networks'] as List?) ?? const [];
    var hasDenied = false;
    var hasRequesting = false;
    for (final n in networks) {
      if (n is! Map) continue;
      switch ((n['status'] as num?)?.toInt()) {
        case 1:
          return Colors.green;
        case 2:
          hasDenied = true;
        case 0:
          hasRequesting = true;
      }
    }
    if (hasDenied) return Theme.of(context).colorScheme.error;
    if (hasRequesting) return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = (status['state'] as String?) ?? 'STOPPED';
    final node = (status['node'] as String?) ?? '';
    final networks =
        ((status['networks'] as List?) ?? const [])
            .whereType<Map>()
            .toList();
    final hint = networks
        .map(
          (n) => _networkStatusHints[(n['status'] as num?)?.toInt() ?? -1],
        )
        .whereType<String>()
        .firstOrNull;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _statusColor(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusText,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '立即刷新',
                  onPressed: onRefresh,
                ),
              ],
            ),
            if (node.isNotEmpty && state == 'RUNNING') ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      '节点地址 $node',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: '复制节点地址',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: node));
                    },
                  ),
                ],
              ),
            ],
            for (final n in networks)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${n['nwid']}: ${(n['assigned'] as List?)?.join(', ') ?? ''}'
                  '  routes: ${(n['routes'] as List?)?.join(', ') ?? ''}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
