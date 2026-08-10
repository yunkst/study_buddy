import 'package:flutter/material.dart';

import '../app_update_service.dart';
import '../models/app_version.dart';

/// APP 更新对话框：显示新版本，提供下载 + 安装
class AppUpdateDialog extends StatefulWidget {
  final AppVersion version;
  final AppUpdateService updateService;
  final VoidCallback? onUpdateComplete;
  final bool isNewVersion; // false 表示版本相同但用户重新下载

  const AppUpdateDialog({
    super.key,
    required this.version,
    required this.updateService,
    this.onUpdateComplete,
    this.isNewVersion = true,
  });

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  double _downloadProgress = 0.0;
  String _statusMessage = '';
  bool _isDownloading = false;
  bool _isDownloadComplete = false;
  bool _isInstalling = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(children: [
        Icon(Icons.new_releases, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(widget.isNewVersion ? '发现新版本' : '重新下载',
            style: theme.textTheme.titleLarge),
      ]),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本 ${widget.version.version}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('大小: ${widget.version.fileSizeFormatted}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (widget.version.changelog != null &&
                widget.version.changelog!.isNotEmpty) ...[
              Text('更新内容:', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(widget.version.changelog!,
                      style: theme.textTheme.bodySmall),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_isDownloading || _isDownloadComplete) ...[
              if (_isDownloading) ...[
                LinearProgressIndicator(
                  value: _downloadProgress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_downloadProgress * 100).toStringAsFixed(0)}% - $_statusMessage',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('下载完成',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
      actions: _buildActions(),
    );
  }

  List<Widget> _buildActions() {
    if (_isInstalling) {
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: CircularProgressIndicator(),
          ),
        ),
      ];
    }
    if (_isDownloadComplete) {
      return [
        TextButton(
          onPressed: _isInstalling ? null : _installApk,
          child: const Text('立即安装'),
        ),
      ];
    }
    if (_isDownloading) {
      return const [TextButton(onPressed: null, child: Text('下载中...'))];
    }
    return [
      TextButton(
        onPressed: () async {
          await widget.updateService.ignoreVersion(widget.version.version);
          if (mounted) Navigator.of(context).pop();
        },
        child: const Text('稍后提醒'),
      ),
      ElevatedButton(
        onPressed: _startDownload,
        child: Text(widget.isNewVersion ? '立即更新' : '重新下载'),
      ),
    ];
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _statusMessage = '准备下载...';
    });
    final success = await widget.updateService.downloadUpdate(
      version: widget.version,
      onProgress: (p) => mounted ? setState(() => _downloadProgress = p) : null,
      onStatus: (s) => mounted ? setState(() => _statusMessage = s) : null,
    );
    if (!mounted) return;
    setState(() {
      _isDownloading = false;
      _isDownloadComplete = success;
      _statusMessage = success ? '下载完成' : '下载失败';
    });
    if (success) _installApk();
  }

  Future<void> _installApk() async {
    setState(() => _isInstalling = true);
    final success = await widget.updateService.installUpdate(widget.version.version);
    if (!mounted) return;
    setState(() => _isInstalling = false);
    if (success) {
      Navigator.of(context).pop();
      widget.onUpdateComplete?.call();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('安装失败，请手动安装')),
      );
    }
  }
}

/// 显示更新对话框的辅助函数
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppVersion version,
  required AppUpdateService updateService,
  VoidCallback? onUpdateComplete,
  bool isNewVersion = true,
}) {
  return showDialog(
    context: context,
    builder: (context) => AppUpdateDialog(
      version: version,
      updateService: updateService,
      onUpdateComplete: onUpdateComplete,
      isNewVersion: isNewVersion,
    ),
  );
}
