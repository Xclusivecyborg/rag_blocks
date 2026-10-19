import 'dart:io';

import 'package:rag_blocks/rag_blocks.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('rag_blocks_'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative) {
    final parts = relative.split('/');
    File([root.path, ...parts].join(Platform.pathSeparator))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
  }

  List<String> namesBelow(Directory dir, List<File> files) => [
    for (final f in files)
      f.path
          .substring(dir.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/'),
  ];

  test('finds supported files in subfolders, sorted', () async {
    write('b.md');
    write('a.txt');
    write('docs/c.csv');
    write('image.png');

    final files = await findSupportedFiles(root);

    expect(namesBelow(root, files), ['a.txt', 'b.md', 'docs/c.csv']);
  });

  test('skips hidden files and everything in hidden folders', () async {
    write('notes.md');
    write('.secret.md');
    write('.obsidian/app.json');
    write('docs/.cache/old.txt');

    final files = await findSupportedFiles(root);

    expect(namesBelow(root, files), ['notes.md']);
  });

  test('the folder itself may be hidden', () async {
    write('.docs/guide.md');
    final hidden = Directory('${root.path}${Platform.pathSeparator}.docs');

    final files = await findSupportedFiles(hidden);

    expect(namesBelow(hidden, files), ['guide.md']);
  });

  test('extensions are matched case-insensitively', () {
    expect(fileExtension('README.MD'), '.md');
    expect(fileExtension('Makefile'), '');
  });
}
