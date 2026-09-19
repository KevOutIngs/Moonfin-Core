import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:file/file.dart' as f;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moonfin/util/image_cache_index.dart';
import 'package:moonfin/util/image_file_service.dart';

/// A file system rooted in a test directory, standing in for the package's
/// own temp-directory one, which needs path_provider.
class _DirectoryFileSystem implements FileSystem {
  _DirectoryFileSystem(this.directory);
  final Directory directory;

  @override
  Future<f.File> createFile(String name) async =>
      const LocalFileSystem().file('${directory.path}/$name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory cacheDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('moonfin-index');
    cacheDir = Directory('${temp.path}/libCachedImageData');
  });

  tearDown(() => temp.delete(recursive: true));

  CacheObject object(
    String url, {
    String? path,
    DateTime? touched,
    int? length,
  }) => CacheObject(
    url,
    relativePath: path ?? '${url.hashCode}.jpg',
    validTill: DateTime(2030),
    touched: touched,
    length: length,
  );

  Future<File> fileFor(CacheObject o) async {
    final file = File('${cacheDir.path}/${o.relativePath}');
    await file.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(10, 1));
    return file;
  }

  group('round trip', () {
    test('a flushed index reopens with the same rows', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      final a = await index.insert(
        object('http://s/a', length: 12),
        setTouchedToNow: false,
      );
      final b = await index.insert(
        object('http://s/b', touched: DateTime(2024, 1, 2)),
      );
      await index.flush();
      expect(
        File('${cacheDir.path}/${ImageCacheIndex.indexFileName}').existsSync(),
        isTrue,
      );

      final reopened = ImageCacheIndex(directory: cacheDir);
      await reopened.open();
      expect(reopened.length, 2);
      final ra = await reopened.get('http://s/a');
      final rb = await reopened.get('http://s/b');
      expect(ra?.id, a.id);
      expect(ra?.length, 12);
      expect(ra?.relativePath, a.relativePath);
      expect(rb?.id, b.id);
      expect(
        rb?.touched?.millisecondsSinceEpoch,
        b.touched?.millisecondsSinceEpoch,
      );
      // Ids keep counting from where they left off, so a row inserted after a
      // reopen never collides with one written before it.
      final c = await reopened.insert(object('http://s/c'));
      expect(c.id, greaterThan(b.id!));
    });

    test(
      'a corrupt index opens empty without throwing or deleting files',
      () async {
        await cacheDir.create(recursive: true);
        final stray = await fileFor(object('http://s/x'));
        await File('${cacheDir.path}/${ImageCacheIndex.indexFileName}')
            .writeAsString('{not json');
        final index = ImageCacheIndex(directory: cacheDir);
        expect(await index.open(), isTrue);
        expect(index.length, 0);
        expect(stray.existsSync(), isTrue);
      },
    );

    test('an unknown format version opens empty', () async {
      await cacheDir.create(recursive: true);
      await File('${cacheDir.path}/${ImageCacheIndex.indexFileName}')
          .writeAsString(
            jsonEncode({
              'v': 99,
              'e': [
                [1, 'u', null, 'p', null, 0, 0, null],
              ],
            }),
          );
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      expect(index.length, 0);
    });

    test('a leftover temp file is ignored', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      await index.insert(object('http://s/a'));
      await index.flush();
      await File('${cacheDir.path}/${ImageCacheIndex.indexFileName}.tmp')
          .writeAsString('garbage');
      final reopened = ImageCacheIndex(directory: cacheDir);
      await reopened.open();
      expect(reopened.length, 1);
    });
  });

  group('rows', () {
    test('update reflects the new touched time', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      final early = DateTime(2024, 1, 1);
      final stored = await index.insert(
        object('http://s/a', touched: early),
        setTouchedToNow: false,
      );
      expect((await index.get('http://s/a'))?.touched, early);
      await withClock(Clock.fixed(DateTime(2025, 6, 1)), () async {
        await index.update(stored);
      });
      expect((await index.get('http://s/a'))?.touched, DateTime(2025, 6, 1));
    });

    test(
      'over capacity returns the least recently touched beyond the cap',
      () async {
        final index = ImageCacheIndex(directory: cacheDir);
        await index.open();
        for (var i = 0; i < 5; i++) {
          await index.insert(
            object('http://s/$i', touched: DateTime(2024, 1, i + 1)),
            setTouchedToNow: false,
          );
        }
        expect(await index.getObjectsOverCapacity(5), isEmpty);
        expect(await index.getObjectsOverCapacity(9), isEmpty);
        final over = await index.getObjectsOverCapacity(3);
        expect(over.map((o) => o.url), ['http://s/0', 'http://s/1']);
      },
    );

    test('old objects are those touched before the cutoff', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      await index.insert(
        object('http://s/old', touched: DateTime(2020)),
        setTouchedToNow: false,
      );
      await index.insert(
        object('http://s/new', touched: DateTime(2030)),
        setTouchedToNow: false,
      );
      final old = await index.getOldObjects(const Duration(days: 14));
      expect(old.map((o) => o.url), ['http://s/old']);
    });

    test('delete unlinks the file and tolerates a missing one', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      final a = await index.insert(object('http://s/a'));
      final file = await fileFor(a);
      expect(await index.delete(a.id!), 1);
      expect(file.existsSync(), isFalse);
      expect(await index.get('http://s/a'), isNull);
      final b = await index.insert(object('http://s/b'));
      expect(await index.delete(b.id!), 1);
      expect(await index.delete(999), 0);
    });
  });

  group('persistence', () {
    test('many changes coalesce into one write', () {
      fakeAsync((async) {
        final index = ImageCacheIndex(
          directory: cacheDir,
          flushInterval: const Duration(seconds: 30),
        );
        index.open();
        async.flushMicrotasks();
        for (var i = 0; i < 20; i++) {
          index.insert(object('http://s/$i'));
        }
        async.flushMicrotasks();
        expect(index.isDirty, isTrue);
        async.elapse(const Duration(seconds: 29));
        expect(index.isDirty, isTrue);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(index.isDirty, isFalse);
      });
    });

    test('close flushes', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      await index.open();
      await index.insert(object('http://s/a'));
      expect(await index.close(), isTrue);
      final reopened = ImageCacheIndex(directory: cacheDir);
      await reopened.open();
      expect(reopened.length, 1);
    });
  });

  group('migration', () {
    test(
      'imports the legacy repository and leaves its file in place',
      () async {
        final legacyFile = File('${temp.path}/legacy.json');
        final legacy = JsonCacheInfoRepository.withFile(legacyFile);
        await legacy.open();
        await legacy.insert(
          object('http://s/a', touched: DateTime(2024, 3, 3)),
          setTouchedToNow: false,
        );
        await legacy.insert(object('http://s/b'));
        await legacy.close();
        expect(legacyFile.existsSync(), isTrue);

        final index = ImageCacheIndex(
          directory: cacheDir,
          legacy: JsonCacheInfoRepository.withFile(legacyFile),
        );
        await index.open();
        expect(index.length, 2);
        expect(index.migratedCount, 2);
        expect((await index.get('http://s/a'))?.touched, DateTime(2024, 3, 3));
        expect(
          legacyFile.existsSync(),
          isTrue,
          reason: 'a downgrade must find it',
        );
        expect(
          File('${cacheDir.path}/${ImageCacheIndex.indexFileName}')
              .existsSync(),
          isTrue,
        );
      },
    );

    test('does not import again once an index exists', () async {
      final legacyFile = File('${temp.path}/legacy.json');
      final legacy = JsonCacheInfoRepository.withFile(legacyFile);
      await legacy.open();
      await legacy.insert(object('http://s/legacy'));
      await legacy.close();

      final first = ImageCacheIndex(
        directory: cacheDir,
        legacy: JsonCacheInfoRepository.withFile(legacyFile),
      );
      await first.open();
      final id = (await first.get('http://s/legacy'))!.id!;
      await first.delete(id);
      await first.flush();

      final second = ImageCacheIndex(
        directory: cacheDir,
        legacy: JsonCacheInfoRepository.withFile(legacyFile),
      );
      await second.open();
      expect(second.length, 0);
      expect(second.migratedCount, 0);
    });
  });

  group('through a real CacheManager', () {
    late HttpServer server;

    setUp(() async {
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(List<int>.filled(64, 0x41));
        request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('emptyCache really empties the directory', () async {
      final index = ImageCacheIndex(directory: cacheDir);
      final manager = CacheManager(
        Config(
          'test-index',
          repo: index,
          fileSystem: _DirectoryFileSystem(cacheDir),
          fileService: BoundedImageFileService(http.Client()),
          maxNrOfCacheObjects: 100,
        ),
      );
      for (var i = 0; i < 3; i++) {
        await manager.getSingleFile('http://127.0.0.1:${server.port}/$i.jpg');
      }
      await index.flush();
      final files = cacheDir
          .listSync()
          .whereType<File>()
          .where(
            (f) => !ImageCacheIndex.isIndexFileName(f.uri.pathSegments.last),
          )
          .toList();
      expect(files, hasLength(3));

      await manager.emptyCache();
      final after = cacheDir
          .listSync()
          .whereType<File>()
          .where(
            (f) => !ImageCacheIndex.isIndexFileName(f.uri.pathSegments.last),
          )
          .toList();
      expect(after, isEmpty, reason: 'rows dropped but files left behind');
      expect(index.length, 0);
    });
  });
}
