import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/services/log_service.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/playback/auto_bitrate_service.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _testBytes = 2500000;

/// The server's BitrateTest endpoint: each request is answered when the
/// test says so, with as many bytes as the test says.
class _FakePlaybackApi extends Fake implements PlaybackApi {
  final List<Completer<List<int>>> requests = <Completer<List<int>>>[];

  @override
  Future<List<int>> bitrateTest(int bytes, {Duration? timeout}) {
    final request = Completer<List<int>>();
    requests.add(request);
    return request.future;
  }

  void answer({int bytes = _testBytes}) =>
      requests.last.complete(List<int>.filled(bytes, 0));

  void fail() => requests.last.completeError(StateError('link down'));
}

class _FakeClient extends Fake implements MediaServerClient {
  _FakeClient(this.baseUrl, this.playbackApi);

  @override
  final String baseUrl;

  @override
  final _FakePlaybackApi playbackApi;
}

class _FakeFactory extends Fake implements MediaServerClientFactory {
  final Map<String, MediaServerClient> _clients = <String, MediaServerClient>{};

  @override
  Map<String, MediaServerClient> get clients => Map.unmodifiable(_clients);

  @override
  MediaServerClient getActiveClient() => _clients.values.last;

  void add(String id, MediaServerClient client) => _clients[id] = client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlaybackApi api;
  late _FakeFactory factory;
  late AutoBitrateService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    final prefs = UserPreferences(store);
    api = _FakePlaybackApi();
    factory = _FakeFactory();
    GetIt.instance.registerSingleton<LogService>(
      LogService(
        prefs,
        factory,
        const DeviceInfo(
          id: 'dev-1',
          name: 'Test Device',
          appName: 'Moonfin',
          appVersion: '0.0.0',
        ),
      ),
    );
    service = AutoBitrateService(factory);
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  void connect() => factory.add('s1', _FakeClient('https://jf.test', api));

  /// Lets the request go out and, once answered, the result settle.
  Future<void> settle() => pumpEventQueue();

  test('with no server there is nothing to measure, and no request', () {
    expect(service.measuredBpsForActiveServer(), isNull);
    expect(api.requests, isEmpty);
  });

  test('a cold link is measured once, then known synchronously', () async {
    connect();

    final first = service.measuredBpsForActiveServer();
    expect(first, isA<Future<int?>>(), reason: 'nothing measured yet');
    expect(api.requests, hasLength(1));

    api.answer();
    final measured = await first;
    expect(measured, isNotNull);
    expect(measured, greaterThan(0));

    final second = service.measuredBpsForActiveServer();
    expect(second, measured, reason: 'the cached figure needs no future');
    expect(api.requests, hasLength(1));
  });

  test('a burst of asks during the download shares one request', () async {
    connect();

    final a = service.measuredBpsForActiveServer();
    final b = service.measuredBpsForActiveServer();
    expect(api.requests, hasLength(1));

    api.answer();
    expect(await a, await b);
  });

  test('a body that arrived short is not a measurement and is not kept',
      () async {
    connect();

    final first = service.measuredBpsForActiveServer() as Future<int?>;
    api.answer(bytes: _testBytes ~/ 4 - 1);
    expect(await first, isNull);

    final second = service.measuredBpsForActiveServer();
    expect(second, isA<Future<int?>>(), reason: 'nothing to cache');
    expect(api.requests, hasLength(2));
  });

  test('a body just long enough still counts', () async {
    connect();

    final first = service.measuredBpsForActiveServer() as Future<int?>;
    api.answer(bytes: _testBytes ~/ 4);
    expect(await first, greaterThan(0));
  });

  test('a failed request leaves the link unmeasured', () async {
    connect();

    final first = service.measuredBpsForActiveServer() as Future<int?>;
    api.fail();
    expect(await first, isNull);
    expect(service.measuredBpsForActiveServer(), isA<Future<int?>>());
  });

  test('after a failure the next ask measures again',
      () async {
    connect();

    final first = service.measuredBpsForActiveServer() as Future<int?>;
    api.fail();
    await first;
    await settle();

    final second = service.measuredBpsForActiveServer() as Future<int?>;
    expect(api.requests, hasLength(2));
    api.answer();
    expect(await second, greaterThan(0));
  });

  group('warm', () {
    test('starts a measurement so a play that follows finds it ready',
        () async {
      connect();

      service.warm();
      expect(api.requests, hasLength(1));

      api.answer();
      await settle();

      expect(service.measuredBpsForActiveServer(), isA<int>());
      expect(api.requests, hasLength(1));
    });

    test('is a no-op while a download is in flight or the figure is fresh',
        () async {
      connect();

      service.warm();
      service.warm();
      expect(api.requests, hasLength(1));

      api.answer();
      await settle();
      service.warm();
      expect(api.requests, hasLength(1));
    });

    test('does nothing without a server', () {
      service.warm();
      expect(api.requests, isEmpty);
    });

    test('warmIfRegistered reaches the registered service, and only that',
        () {
      connect();

      AutoBitrateService.warmIfRegistered();
      expect(api.requests, isEmpty, reason: 'not registered yet');

      GetIt.instance.registerSingleton<AutoBitrateService>(service);
      AutoBitrateService.warmIfRegistered();
      expect(api.requests, hasLength(1));
    });
  });

  test('each server is measured on its own', () async {
    final other = _FakePlaybackApi();
    factory.add('s1', _FakeClient('https://a.test', api));
    final first = service.measuredBpsForActiveServer() as Future<int?>;
    api.answer();
    await first;

    factory.add('s2', _FakeClient('https://b.test', other));
    expect(service.measuredBpsForActiveServer(), isA<Future<int?>>());
    expect(other.requests, hasLength(1));
  });
}
