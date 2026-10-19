import 'dart:io';

/// File types the loader picks up.
const Set<String> supportedExtensions = {
  '.txt',
  '.md',
  '.markdown',
  '.csv',
  '.log',
  '.json',
};

/// Every supported file under [folder], sorted by path.
///
/// Hidden files are skipped, and so is everything inside a hidden folder
/// such as `.git` or `.obsidian`. [folder] itself may be hidden.
Future<List<File>> findSupportedFiles(Directory folder) async {
  final files = <File>[];
  await for (final entity in folder.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    // Paths from list() start with folder.path, so this is the part below it.
    final below = entity.path.substring(folder.path.length);
    final names = below.split(Platform.pathSeparator);
    if (names.any((n) => n.startsWith('.'))) continue;
    if (supportedExtensions.contains(fileExtension(names.last))) {
      files.add(entity);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The lower-cased extension of [name], including the dot, or '' if none.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot).toLowerCase();
}
