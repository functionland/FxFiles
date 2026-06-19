import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/utils/file_type_utils.dart';

void main() {
  group('uploadCategoryBase', () {
    test('images', () {
      for (final n in [
        'a.jpg', 'b.JPEG', 'c.png', 'd.gif', 'e.webp', 'f.heic', 'g.svg',
      ]) {
        expect(uploadCategoryBase(n), 'images', reason: n);
      }
    });

    test('videos', () {
      for (final n in ['a.mp4', 'b.MOV', 'c.mkv', 'd.webm', 'e.m4v', 'f.flv']) {
        expect(uploadCategoryBase(n), 'videos', reason: n);
      }
    });

    test('audio', () {
      for (final n in ['a.mp3', 'b.WAV', 'c.flac', 'd.m4a', 'e.ogg', 'f.opus']) {
        expect(uploadCategoryBase(n), 'audio', reason: n);
      }
    });

    test('documents (incl. office/iwork/ebook)', () {
      for (final n in [
        'a.pdf', 'b.DOCX', 'c.txt', 'd.md', 'e.xlsx', 'f.csv',
        'g.pages', 'h.key', 'i.epub', 'j.odt', 'k.pptx',
      ]) {
        expect(uploadCategoryBase(n), 'documents', reason: n);
      }
    });

    test('archives — including .tar.gz via its .gz extension', () {
      for (final n in [
        'a.zip', 'b.RAR', 'c.7z', 'd.tar', 'e.tar.gz', 'f.tgz', 'g.iso', 'h.xz',
      ]) {
        expect(uploadCategoryBase(n), 'archives', reason: n);
      }
    });

    test('unknown binaries + no-extension fall to downloads', () {
      for (final n in [
        'a.exe', 'b.apk', 'c.bin', 'd.dmg', 'noextension', 'weird.xyz',
      ]) {
        expect(uploadCategoryBase(n), 'downloads', reason: n);
      }
    });
  });

  group('categoryDisplayName', () {
    test('capitalizes the base', () {
      expect(categoryDisplayName('images'), 'Images');
      expect(categoryDisplayName('audio'), 'Audio');
      expect(categoryDisplayName('downloads'), 'Downloads');
      expect(categoryDisplayName('archives'), 'Archives');
    });

    test('empty stays empty', () {
      expect(categoryDisplayName(''), '');
    });
  });
}
