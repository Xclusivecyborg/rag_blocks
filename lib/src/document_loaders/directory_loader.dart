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

/// Every supported, non-hidden file under [folder], sorted by path.
Future<List<File>> findSupportedFiles(Directory folder) async {
  final files = <File>[];
  await for (final entity in folder.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name.startsWith('.')) continue;
    if (supportedExtensions.contains(fileExtension(name))) files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The lower-cased extension of [name], including the dot, or '' if none.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot).toLowerCase();
}
