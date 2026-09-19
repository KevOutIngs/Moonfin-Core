import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import 'artwork_timing.dart';

/// The artwork cache's index of what is on disk, kept in memory.
///
/// The cache manager asks its repository for a row on every image it shows,
/// and writes one back to touch the timestamp. The stock repositories make
/// each of those a database round trip: on Android, iOS and macOS a sqflite
/// call over the platform channel, serialised on one thread, so a grid of
/// forty posters queues eighty of them before the first image decodes, and on
/// the other platforms a linear scan of a JSON file. Here a lookup is a map
/// read and a write marks the index dirty, and the file is rewritten at most
/// once per [flushInterval].
///
/// Deleting a row also unlinks its file. The cache manager this app ships
/// resolves the file name against the working directory when it evicts, so
/// "Clear image cache" and the object cap only ever dropped rows and left
/// every file behind for the size sweep to find by age.
class ImageCacheIndex extends CacheInfoRepository {
  ImageCacheIndex({
    required this.directory,
    this.flushInterval = const Duration(seconds: 30),
    CacheInfoRepository? legacy,
    this.fileName = indexFileName,
  }) : _legacy = legacy; // ignore: prefer_initializing_formals

  /// The repository this one replaced, read once when no index file exists.
  final CacheInfoRepository? _legacy;

  /// A dot-file inside the cache directory, beside the files it describes,
  /// so it goes wherever they go: when iOS purges the temporary directory
  /// the index disappears with the files instead of describing ghosts.
  static const indexFileName = '.moonfin-image-index.json';

  /// Files the size sweep must leave alone.
  static bool isIndexFileName(String name) => name.startsWith('.moonfin-');

  static const formatVersion = 1;

  /// The cache directory: `<temp>/libCachedImageData`.
  final Directory directory;
  final String fileName;

  /// How long dirty rows wait before they are written.
  ///
  /// Every disk hit touches a row, so writing through would rewrite the whole
  /// index for every image shown. Losing this much on a crash costs a
  /// slightly stale recently-used order and, for a download whose row was
  /// lost, one orphaned file the size sweep reclaims and one re-download.
  final Duration flushInterval;

  // The same open-count contract the package's own repositories keep: the
  // first opener does the work, later ones wait on it, and the last closer
  // flushes.
  int _openConnections = 0;
  Completer<bool>? _opening;

  final Map<String, CacheObject> _byKey = <String, CacheObject>{};
  final Map<int, CacheObject> _byId = <int, CacheObject>{};
  int _nextId = 1;
  bool _dirty = false;
  Timer? _flushTimer;
  Future<void> _writeChain = Future<void>.value();

  /// Where the rows came from on this open, for the diagnostic log.
  String? migratedFrom;
  int migratedCount = 0;

  int get length => _byKey.length;

  File get _file => File(p.join(directory.path, fileName));
  File get _tempFile => File('${_file.path}.tmp');

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<bool> open() async {
    _openConnections++;
    if (_openConnections > 1) return _opening!.future;
    final completer = _opening = Completer<bool>();
    final stopwatch = Stopwatch()..start();
    try {
      await directory.create(recursive: true);
      final loaded = await _load();
      if (!loaded) await _importLegacy();
    } catch (_) {
      // Whatever went wrong, an empty index is a cold cache, not a broken
      // one: every file on disk is re-downloaded on demand and the size sweep
      // reclaims the rest by age.
      _byKey.clear();
      _byId.clear();
      _nextId = 1;
    }
    ArtworkTimings.indexOpened(
      entries: length,
      took: stopwatch.elapsed,
      migratedFrom: migratedFrom,
      migratedCount: migratedCount,
    );
    completer.complete(true);
    return true;
  }

  /// True when an index file was there to read. A parse failure counts as
  /// read, so a corrupt file is never followed by a second import from the
  /// legacy repository that would resurrect rows for files since evicted.
  Future<bool> _load() async {
    if (!await _file.exists()) return false;
    try {
      final text = await _file.readAsString();
      final decoded = await Isolate.run(() => jsonDecode(text));
      if (decoded is! Map<String, dynamic>) return true;
      if (decoded['v'] != formatVersion) return true;
      final entries = decoded['e'];
      if (entries is! List) return true;
      for (final entry in entries) {
        if (entry is! List || entry.length < 8) continue;
        final id = entry[0];
        final url = entry[1];
        final path = entry[3];
        final validTill = entry[5];
        final touched = entry[6];
        if (id is! int ||
            url is! String ||
            path is! String ||
            validTill is! int ||
            touched is! int) {
          continue;
        }
        final object = CacheObject(
          url,
          id: id,
          key: entry[2] as String?,
          relativePath: path,
          eTag: entry[4] as String?,
          validTill: DateTime.fromMillisecondsSinceEpoch(validTill),
          touched: DateTime.fromMillisecondsSinceEpoch(touched),
          length: entry[7] as int?,
        );
        _byKey[object.key] = object;
        _byId[id] = object;
      }
      final next = decoded['next'];
      _nextId = next is int
          ? next
          : (_byId.keys.fold(0, (a, b) => a > b ? a : b) + 1);
      return true;
    } catch (_) {
      _byKey.clear();
      _byId.clear();
      _nextId = 1;
      return true;
    }
  }

  /// Copies the rows of the repository this replaced, so an update keeps
  /// the artwork already on disk instead of downloading it all again.
  ///
  /// The legacy file is left where it is: a build that goes back to the old
  /// repository then still finds its index. The cache manager's own
  /// migration helper would delete it.
  Future<void> _importLegacy() async {
    final legacy = _legacy;
    if (legacy == null) return;
    if (!await legacy.exists()) return;
    await legacy.open();
    try {
      final objects = await legacy.getAllObjects();
      for (final object in objects) {
        if (_byKey.containsKey(object.key)) continue;
        _put(object, id: _nextId++, touched: object.touched ?? clock.now());
      }
      migratedFrom = legacy.runtimeType.toString();
      migratedCount = objects.length;
    } finally {
      await legacy.close();
    }
    if (migratedCount > 0) {
      _dirty = true;
      await flush();
    }
  }

  @override
  Future<CacheObject?> get(String key) {
    final object = _byKey[key];
    if (object != null) ArtworkTimings.indexHit();
    return Future<CacheObject?>.value(object);
  }

  @override
  Future<List<CacheObject>> getAllObjects() =>
      Future<List<CacheObject>>.value(_byId.values.toList(growable: false));

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) {
    if (cacheObject.id != null) {
      throw ArgumentError("Inserted objects shouldn't have an existing id.");
    }
    final stored = _put(
      cacheObject,
      id: _nextId++,
      touched: setTouchedToNow
          ? clock.now()
          : cacheObject.touched ?? clock.now(),
    );
    _markDirty();
    return Future<CacheObject>.value(stored);
  }

  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) {
    final id = cacheObject.id;
    if (id == null) {
      throw ArgumentError('Updated objects should have an existing id.');
    }
    final previous = _byId[id];
    if (previous != null && previous.key != cacheObject.key) {
      _byKey.remove(previous.key);
    }
    _put(
      cacheObject,
      id: id,
      touched: setTouchedToNow
          ? clock.now()
          : cacheObject.touched ?? clock.now(),
    );
    _markDirty();
    return Future<int>.value(1);
  }

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) =>
      cacheObject.id == null ? insert(cacheObject) : update(cacheObject);

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) {
    if (_byId.length <= capacity) return Future.value(const <CacheObject>[]);
    final sorted = _byId.values.toList()
      ..sort((a, b) => _touchedMs(a).compareTo(_touchedMs(b)));
    return Future.value(sorted.sublist(0, sorted.length - capacity));
  }

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) {
    final cutoff = clock.now().subtract(maxAge).millisecondsSinceEpoch;
    return Future.value(
      _byId.values.where((o) => _touchedMs(o) < cutoff).toList(),
    );
  }

  @override
  Future<int> delete(int id) async {
    final object = _byId.remove(id);
    if (object == null) return 0;
    if (identical(_byKey[object.key], object)) _byKey.remove(object.key);
    _markDirty();
    await _unlink(object);
    return 1;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    var deleted = 0;
    for (final id in ids) {
      deleted += await delete(id);
    }
    return deleted;
  }

  @override
  Future<bool> close() async {
    _openConnections--;
    if (_openConnections > 0) return false;
    _openConnections = 0;
    _opening = null;
    await flush();
    return true;
  }

  @override
  Future<void> deleteDataFile() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    for (final file in [_file, _tempFile]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Writes the index now if anything changed. Safe to call at any time:
  /// writes never overlap and a write in progress is waited for.
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty) return _writeChain;
    _writeChain = _writeChain.then((_) => _write());
    return _writeChain;
  }

  CacheObject _put(
    CacheObject object, {
    required int id,
    required DateTime touched,
  }) {
    final stored = CacheObject(
      object.url,
      id: id,
      key: object.key,
      relativePath: object.relativePath,
      validTill: object.validTill,
      eTag: object.eTag,
      length: object.length,
      touched: touched,
    );
    _byKey[stored.key] = stored;
    _byId[id] = stored;
    if (id >= _nextId) _nextId = id + 1;
    return stored;
  }

  void _markDirty() {
    _dirty = true;
    _flushTimer ??= Timer(flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Future<void> _write() async {
    if (!_dirty) return;
    final stopwatch = Stopwatch()..start();
    _dirty = false;
    final rows = <List<Object?>>[
      for (final o in _byId.values)
        <Object?>[
          o.id,
          o.url,
          o.key == o.url ? null : o.key,
          o.relativePath,
          o.eTag,
          o.validTill.millisecondsSinceEpoch,
          _touchedMs(o),
          o.length,
        ],
    ];
    final text = jsonEncode(<String, Object?>{
      'v': formatVersion,
      'next': _nextId,
      'e': rows,
    });
    try {
      // Temp then rename, so a kill mid-write leaves the previous index
      // whole rather than a truncated file that parses as empty.
      await _tempFile.writeAsString(text, flush: true);
      await _tempFile.rename(_file.path);
    } catch (_) {
      _dirty = true;
    }
    ArtworkTimings.indexFlushed(entries: rows.length, took: stopwatch.elapsed);
  }

  Future<void> _unlink(CacheObject object) async {
    try {
      final file = File(p.join(directory.path, object.relativePath));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Already gone, or the directory is being cleared underneath us.
    }
  }

  static int _touchedMs(CacheObject o) =>
      o.touched?.millisecondsSinceEpoch ?? 0;

  @visibleForTesting
  bool get isDirty => _dirty;
}
