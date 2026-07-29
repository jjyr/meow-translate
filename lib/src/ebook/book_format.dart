import 'package:path/path.dart' as path;

enum BookFormat {
  epub,
  mobi,
  azw3;

  static BookFormat? fromPath(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return switch (extension) {
      '.epub' => BookFormat.epub,
      '.mobi' => BookFormat.mobi,
      '.azw3' => BookFormat.azw3,
      _ => null,
    };
  }

  String get extension => '.$name';

  bool get requiresCalibre => this != BookFormat.epub;
}
