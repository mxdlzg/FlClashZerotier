import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/dav_client.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/fade_box.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/loading.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:fl_clash/widgets/text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class BackupAndRestore extends ConsumerStatefulWidget {
  const BackupAndRestore({super.key});

  @override
  ConsumerState<BackupAndRestore> createState() => _BackupAndRestoreState();
}

class _BackupAndRestoreState extends ConsumerState<BackupAndRestore>
    with UniqueKeyStateMixin {
  final _davConnection = DAVConnectionController();

  @override
  void initState() {
    super.initState();
    ref.listenManual(davSettingProvider, (_, _) {
      _updateDAVClient();
    }, fireImmediately: true);
  }

  void _updateDAVClient() {
    unawaited(_davConnection.update(ref.read(davSettingProvider)));
  }

  @override
  void dispose() {
    _davConnection.dispose();
    super.dispose();
  }

  Future<void> _showAddWebDAV(DAVProps? dav) async {
    await globalState.showCommonDialog<String>(
      child: WebDAVFormDialog(dav: dav?.copyWith()),
    );
  }

  Future<String?> _askBackupPassword() async {
    final saved = await preferences.getBackupPassword();
    final password = await globalState.showCommonDialog<String>(
      child: BackupPasswordDialog(initial: saved ?? ''),
    );
    if (password == null || password.isEmpty) return null;
    await preferences.setBackupPassword(password);
    return password;
  }

  Future<void> _encryptBackupFile(String path, String password) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final encrypted = await encryptZipBytesAsync(bytes, password);
    await file.writeAsBytes(encrypted, flush: true);
  }

  Future<bool> _decryptBackupFileIfNeeded() async {
    final backupFile = File(await appPath.backupFilePath);
    if (!await backupFile.exists()) return false;
    final bytes = await backupFile.readAsBytes();
    if (!isEncryptedBackup(bytes)) return true;
    final saved = await preferences.getBackupPassword();
    final password = await globalState.showCommonDialog<String>(
      child: BackupPasswordDialog(
        initial: saved ?? '',
        title: '备份已加密，请输入密码',
        requireConfirm: false,
      ),
    );
    if (password == null || password.isEmpty) return false;
    try {
      final zip = await decryptBackupBytesAsync(bytes, password);
      await backupFile.writeAsBytes(zip, flush: true);
      return true;
    } on FormatException {
      globalState.showMessage(
        title: currentAppLocalizations.restore,
        message: const TextSpan(text: '密码错误或备份文件已损坏'),
      );
      return false;
    }
  }

  Future<void> _backupOnWebDAV() async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.loadingRun<bool>(
      () async {
        final client = _davConnection.client;
        if (client == null) {
          return false;
        }
        final path = await globalState.container
            .read(backupActionProvider.notifier)
            .backup();
        if (path.isEmpty) {
          return false;
        }
        final password = await _askBackupPassword();
        if (password == null) {
          return false;
        }
        await _encryptBackupFile(path, password);
        return client.backup(path);
      },
      tag: LoadingTag.backup_restore,
      title: appLocalizations.backup,
    );
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.backup,
      message: TextSpan(text: appLocalizations.backupSuccess),
    );
  }

  Future<void> _restoreOnWebDAV(RestoreOption option) async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.loadingRun<bool>(
      () async {
        final client = _davConnection.client;
        if (client == null) {
          return false;
        }
        await client.restore();
        if (!await _decryptBackupFileIfNeeded()) {
          return false;
        }
        await globalState.container
            .read(backupActionProvider.notifier)
            .restore(option);
        return true;
      },
      tag: LoadingTag.backup_restore,
      title: appLocalizations.restore,
    );
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.restore,
      message: TextSpan(text: appLocalizations.restoreSuccess),
    );
  }

  Future<void> _handleRestoreOnWebDAV() async {
    final restoreOption = await globalState.showCommonDialog<RestoreOption>(
      child: const RestoreOptionsDialog(),
    );
    if (restoreOption == null || !context.mounted) return;
    _restoreOnWebDAV(restoreOption);
  }

  Future<void> _backupOnLocal() async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.loadingRun<bool>(
      () async {
        final path = await globalState.container
            .read(backupActionProvider.notifier)
            .backup();
        if (path.isEmpty) {
          return false;
        }
        final password = await _askBackupPassword();
        if (password == null) {
          return false;
        }
        await _encryptBackupFile(path, password);
        final value = await picker.saveFileWithPath(
          utils.getBackupFileName(),
          path,
        );
        if (value == null) return false;
        return true;
      },
      title: appLocalizations.backup,
      tag: LoadingTag.backup_restore,
    );
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.backup,
      message: TextSpan(text: appLocalizations.backupSuccess),
    );
  }

  Future<void> _restoreOnLocal(RestoreOption option) async {
    final appLocalizations = context.appLocalizations;
    final file = await picker.pickerFile();
    final path = file?.path;
    if (path == null) return;
    await File(path).safeCopy(await appPath.backupFilePath);
    final res = await globalState.loadingRun<bool>(
      () async {
        if (!await _decryptBackupFileIfNeeded()) {
          return false;
        }
        await globalState.container
            .read(backupActionProvider.notifier)
            .restore(option);
        return true;
      },
      tag: LoadingTag.backup_restore,
      title: appLocalizations.restore,
    );
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.restore,
      message: TextSpan(text: appLocalizations.restoreSuccess),
    );
  }

  Future<void> _handleRestoreOnLocal() async {
    final option = await globalState.showCommonDialog<RestoreOption>(
      child: const RestoreOptionsDialog(),
    );
    if (option == null || !mounted) return;
    _restoreOnLocal(option);
  }

  void _handleChange(String? value, WidgetRef ref) {
    if (value == null) {
      return;
    }
    ref
        .read(davSettingProvider.notifier)
        .update((state) => state?.copyWith(fileName: value));
  }

  Future<void> _handleUpdateRestoreStrategy() async {
    final restoreStrategy = ref.read(
      appSettingProvider.select((state) => state.restoreStrategy),
    );
    final res = await globalState.showCommonDialog(
      child: OptionsDialog<RestoreStrategy>(
        title: currentAppLocalizations.restoreStrategy,
        options: RestoreStrategy.values,
        textBuilder: (mode) => Intl.message('restoreStrategy_${mode.name}'),
        value: restoreStrategy,
      ),
    );
    if (res == null) {
      return;
    }
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(restoreStrategy: res));
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final dav = ref.watch(davSettingProvider);
    final isLoading = ref.watch(loadingProvider(LoadingTag.backup_restore));
    return CommonScaffold(
      isLoading: isLoading,
      title: appLocalizations.backupAndRestore,
      body: ListView(
        children: [
          ListHeader(title: appLocalizations.remote),
          if (dav == null)
            ListItem(
              leading: const Icon(Icons.account_box),
              title: Text(appLocalizations.noInfo),
              subtitle: Text(appLocalizations.pleaseBindWebDAV),
              trailing: FilledButton.tonal(
                onPressed: () {
                  _showAddWebDAV(dav);
                },
                child: Text(appLocalizations.bind),
              ),
            )
          else ...[
            ListItem(
              leading: const Icon(Icons.account_box),
              title: TooltipText(
                text: Text(
                  dav.user,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(appLocalizations.connectivity),
                    ValueListenableBuilder(
                      valueListenable: _davConnection,
                      builder: (_, isCompleter, _) {
                        return Center(
                          child: FadeThroughBox(
                            child: isCompleter == null
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CommonCircleLoading(),
                                  )
                                : Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: !isCompleter
                                          ? context.colorScheme.error
                                          : Colors.green.harmonizeWith(
                                              context.colorScheme.primary,
                                            ),
                                    ),
                                    width: 12,
                                    height: 12,
                                  ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              trailing: FilledButton.tonal(
                onPressed: () {
                  _showAddWebDAV(dav);
                },
                child: Text(appLocalizations.edit),
              ),
            ),
            const SizedBox(height: 4),
            ListItem.input(
              title: Text(appLocalizations.file),
              subtitle: Text(dav.fileName),
              dialogTitle: appLocalizations.file,
              value: dav.fileName,
              resetValue: defaultDavFileName,
              maxLength: TextInputLimits.fileName,
              onChanged: (value) {
                _handleChange(value, ref);
              },
            ),
            ListItem(
              onTap: () {
                _backupOnWebDAV();
              },
              title: Text(appLocalizations.backup),
              subtitle: Text(appLocalizations.remoteBackupDesc),
            ),
            ListItem(
              onTap: () {
                _handleRestoreOnWebDAV();
              },
              title: Text(appLocalizations.restore),
              subtitle: Text(appLocalizations.restoreFromWebDAVDesc),
            ),
          ],
          ListHeader(title: appLocalizations.local),
          ListItem(
            onTap: () {
              _backupOnLocal();
            },
            title: Text(appLocalizations.backup),
            subtitle: Text(appLocalizations.localBackupDesc),
          ),
          ListItem(
            onTap: () {
              _handleRestoreOnLocal();
            },
            title: Text(appLocalizations.restore),
            subtitle: Text(appLocalizations.restoreFromFileDesc),
          ),
          ListHeader(title: appLocalizations.options),
          Consumer(
            builder: (_, ref, _) {
              final restoreStrategy = ref.watch(
                appSettingProvider.select((state) => state.restoreStrategy),
              );
              return ListItem(
                onTap: () {
                  _handleUpdateRestoreStrategy();
                },
                title: Text(appLocalizations.restoreStrategy),
                trailing: FilledButton(
                  onPressed: () {
                    _handleUpdateRestoreStrategy();
                  },
                  child: Text(
                    Intl.message('restoreStrategy_${restoreStrategy.name}'),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class RestoreOptionsDialog extends StatefulWidget {
  const RestoreOptionsDialog({super.key});

  @override
  State<RestoreOptionsDialog> createState() => _RestoreOptionsDialogState();
}

class _RestoreOptionsDialogState extends State<RestoreOptionsDialog> {
  void _handleOnTab(RestoreOption? option) {
    if (option == null) return;
    Navigator.of(context).pop(option);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonDialog(
      title: appLocalizations.restore,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Wrap(
        children: [
          ListItem(
            onTap: () {
              _handleOnTab(RestoreOption.onlyProfiles);
            },
            title: Text(appLocalizations.restoreOnlyConfig),
          ),
          ListItem(
            onTap: () {
              _handleOnTab(RestoreOption.all);
            },
            title: Text(appLocalizations.restoreAllData),
          ),
        ],
      ),
    );
  }
}

class BackupPasswordDialog extends StatefulWidget {
  final String initial;
  final String title;
  final bool requireConfirm;

  const BackupPasswordDialog({
    super.key,
    required this.initial,
    this.title = '设置备份加密密码',
    this.requireConfirm = true,
  });

  @override
  State<BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<BackupPasswordDialog> {
  late final TextEditingController _passwordController;
  final _confirmController = TextEditingController();
  final _obscure = ValueNotifier<bool>(true);
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _obscure.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonDialog(
      title: widget.title,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(appLocalizations.cancel),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(appLocalizations.confirm),
        ),
      ],
      child: Form(
        key: _formKey,
        child: Wrap(
          runSpacing: 16,
          children: [
            ValueListenableBuilder(
              valueListenable: _obscure,
              builder: (_, obscure, _) {
                return TextFormField(
                  controller: _passwordController,
                  obscureText: obscure,
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.password),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => _obscure.value = !_obscure.value,
                    ),
                    labelText: appLocalizations.password,
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return appLocalizations.emptyTip(
                        appLocalizations.password,
                      );
                    }
                    return null;
                  },
                );
              },
            ),
            if (widget.requireConfirm)
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.password),
                  border: OutlineInputBorder(),
                  labelText: '确认密码',
                ),
                validator: (value) {
                  if (value != _passwordController.text) {
                    return '两次输入不一致';
                  }
                  return null;
                },
              ),
            if (widget.requireConfirm)
              Text(
                '备份将以 AES-256 加密导出（含 ZeroTier 节点身份）。'
                '密码会保存在本机用于 WebDAV 自动恢复；'
                '忘记密码将无法解密备份。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class WebDAVFormDialog extends ConsumerStatefulWidget {
  final DAVProps? dav;

  const WebDAVFormDialog({super.key, this.dav});

  @override
  ConsumerState<WebDAVFormDialog> createState() => _WebDAVFormDialogState();
}

class _WebDAVFormDialogState extends ConsumerState<WebDAVFormDialog> {
  late TextEditingController _uriController;
  late TextEditingController _userController;
  late TextEditingController _passwordController;
  final _obscureController = ValueNotifier<bool>(true);
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _uriController = TextEditingController(text: widget.dav?.uri);
    _userController = TextEditingController(text: widget.dav?.user);
    _passwordController = TextEditingController(text: widget.dav?.password);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref
        .read(davSettingProvider.notifier)
        .update(
          (_) => DAVProps(
            uri: _uriController.text,
            user: _userController.text,
            password: _passwordController.text,
            fileName: widget.dav?.fileName ?? defaultDavFileName,
          ),
        );
    Navigator.pop(context);
  }

  void _delete() {
    ref.read(davSettingProvider.notifier).update((_) => null);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _obscureController.dispose();
    _uriController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonDialog(
      title: appLocalizations.webDAVConfiguration,
      actions: [
        if (widget.dav != null)
          TextButton(onPressed: _delete, child: Text(appLocalizations.delete)),
        TextButton(onPressed: _submit, child: Text(appLocalizations.save)),
      ],
      child: Form(
        key: _formKey,
        child: Wrap(
          runSpacing: 16,
          children: [
            TextFormField(
              controller: _uriController,
              inputFormatters: TextInputLimits.limit(TextInputLimits.uri),
              maxLines: 5,
              minLines: 1,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.link),
                border: const OutlineInputBorder(),
                labelText: appLocalizations.address,
                helperText: appLocalizations.addressHelp,
              ),
              validator: (String? value) {
                if (value == null || value.isEmpty || !value.isUrl) {
                  return appLocalizations.addressTip;
                }
                return null;
              },
            ),
            TextFormField(
              controller: _userController,
              inputFormatters: TextInputLimits.limit(TextInputLimits.userName),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.account_circle),
                border: const OutlineInputBorder(),
                labelText: appLocalizations.account,
              ),
              validator: (String? value) {
                if (value == null || value.isEmpty) {
                  return appLocalizations.emptyTip(appLocalizations.account);
                }
                return null;
              },
            ),
            ValueListenableBuilder(
              valueListenable: _obscureController,
              builder: (_, obscure, _) {
                return TextFormField(
                  controller: _passwordController,
                  inputFormatters: TextInputLimits.limit(
                    TextInputLimits.password,
                  ),
                  obscureText: obscure,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.password),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        _obscureController.value = !obscure;
                      },
                    ),
                    labelText: appLocalizations.password,
                  ),
                  validator: (String? value) {
                    if (value == null || value.isEmpty) {
                      return appLocalizations.emptyTip(
                        appLocalizations.password,
                      );
                    }
                    return null;
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
