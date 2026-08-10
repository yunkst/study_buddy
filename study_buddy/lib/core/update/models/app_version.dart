/// APP 版本信息模型（用于 App 内展示更新信息）
class AppVersion {
  final String version;
  final String downloadUrl;
  final int fileSize;
  final String? changelog;
  final String createdAt;

  AppVersion({
    required this.version,
    required this.downloadUrl,
    required this.fileSize,
    this.changelog,
    required this.createdAt,
  });

  factory AppVersion.fromJson(Map<String, dynamic> json) {
    return AppVersion(
      version: json['version'] as String? ?? '',
      downloadUrl: json['download_url'] as String? ?? '',
      fileSize: json['file_size'] as int? ?? 0,
      changelog: json['changelog'] as String?,
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'download_url': downloadUrl,
        'file_size': fileSize,
        'changelog': changelog,
        'created_at': createdAt,
      };

  /// 格式化文件大小显示
  String get fileSizeFormatted {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  @override
  String toString() =>
      'AppVersion(version: $version, downloadUrl: $downloadUrl, fileSize: $fileSize)';
}
