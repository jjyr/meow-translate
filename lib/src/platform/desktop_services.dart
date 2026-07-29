import 'package:flutter/services.dart';

final class DesktopServices {
  static const _channel = MethodChannel('app.meow/desktop');

  Future<void> initialize() async {}

  Future<void> notifyCompleted({
    required String jobId,
    required String outputPath,
  }) => _channel.invokeMethod<void>('notifyCompleted', {
    'id': jobId,
    'outputPath': outputPath,
  });

  Future<void> reveal(String filePath) =>
      _channel.invokeMethod<void>('reveal', {'path': filePath});

  Future<String> createBookmark(String filePath) async {
    final bookmark = await _channel.invokeMethod<String>('createBookmark', {
      'path': filePath,
    });
    if (bookmark == null || bookmark.isEmpty) {
      throw PlatformException(
        code: 'bookmark_failed',
        message: 'macOS did not return a security-scoped bookmark.',
      );
    }
    return bookmark;
  }

  Future<SecurityScopedAccess> startAccess(String bookmark) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'startAccessingBookmark',
      {'bookmark': bookmark},
    );
    final token = result?['token'];
    final resolvedPath = result?['path'];
    if (token is! String || resolvedPath is! String) {
      throw PlatformException(
        code: 'bookmark_failed',
        message: 'macOS could not restore file access.',
      );
    }
    return SecurityScopedAccess._(
      services: this,
      token: token,
      resolvedPath: resolvedPath,
      refreshedBookmark: result?['bookmark'] as String?,
    );
  }

  Future<void> _stopAccess(String token) =>
      _channel.invokeMethod<void>('stopAccessingBookmark', {'token': token});
}

final class SecurityScopedAccess {
  SecurityScopedAccess._({
    required DesktopServices services,
    required this.token,
    required this.resolvedPath,
    required this.refreshedBookmark,
  }) : _services = services;

  final DesktopServices _services;
  final String token;
  final String resolvedPath;
  final String? refreshedBookmark;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _services._stopAccess(token);
  }
}
