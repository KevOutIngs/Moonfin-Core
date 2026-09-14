import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../data/offline/connectivity_aware_media_server_client.dart';
import '../data/services/log_service.dart';
import '../data/services/media_server_client_factory.dart';

/// Measures what the link to the active server can carry, so an Auto bitrate
/// setting means a measured ceiling instead of none at all. Left uncapped the
/// server is asked for the highest quality it can encode, which makes every
/// remote transcode the heaviest job the machine can produce.
///
/// Jellyfin and Emby both serve a throwaway body from BitrateTest, and the
/// time it takes to arrive gives bits per second.
class AutoBitrateService {
  AutoBitrateService(this._clientFactory);

  final MediaServerClientFactory _clientFactory;

  static const _testBytes = 2500000;
  static const _requestTimeout = Duration(seconds: 8);
  static const _cacheLifetime = Duration(minutes: 15);

  /// Leaves room under what the link actually managed, since a stream has to
  /// share it with everything else the device is doing.
  static const _safetyFactor = 0.8;

  final _cache = <String, ({int bps, DateTime measuredAt})>{};
  final _inFlight = <String, Future<int?>>{};

  /// Bits per second the active server can deliver, or null when nothing
  /// could be measured, which leaves the request uncapped as before.
  ///
  /// A figure measured within the last quarter hour comes back
  /// synchronously, so a caller that cannot wait (a live channel change)
  /// can tell a known link from one still being measured. Anything else
  /// comes back as the measurement's future.
  FutureOr<int?> measuredBpsForActiveServer() {
    if (_clientFactory.clients.isEmpty) return null;
    // Offline playback would otherwise wait out the probe's timeout before
    // the local file starts.
    if (shouldUseOfflineCatalog()) return null;
    final client = _clientFactory.getActiveClient();

    final key = client.baseUrl;
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.measuredAt) < _cacheLifetime) {
      return cached.bps;
    }

    // One measurement per server at a time, so a burst of plays does not
    // spend the link on its own tests.
    return _inFlight[key] ??= _measure(client).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  /// Starts a measurement now if none is fresh, so a play that follows has
  /// a figure waiting instead of a download to sit behind. Called where a
  /// play is likely next (the Live TV screens), while the viewer is still
  /// choosing and the link is otherwise idle.
  void warm() {
    final measurement = measuredBpsForActiveServer();
    if (measurement is Future<int?>) unawaited(measurement);
  }

  /// [warm] on the registered service, or nothing where none is registered
  /// (a screen under test, or one built before playback is wired up).
  static void warmIfRegistered() {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<AutoBitrateService>()) return;
    getIt<AutoBitrateService>().warm();
  }

  Future<int?> _measure(MediaServerClient client) async {
    final log = GetIt.instance<LogService>();
    log.log(LogCategory.playback, 'Auto bitrate: measuring');
    try {
      final stopwatch = Stopwatch()..start();
      final body = await client.playbackApi.bitrateTest(
        _testBytes,
        timeout: _requestTimeout,
      );
      stopwatch.stop();

      final bytes = body.length;
      final seconds = stopwatch.elapsedMicroseconds / 1000000;
      // A body that arrived short measures the server giving up, not the link.
      if (bytes < _testBytes ~/ 4 || seconds <= 0) return null;

      final bps = (bytes * 8 / seconds * _safetyFactor).round();
      _cache[client.baseUrl] = (bps: bps, measuredAt: DateTime.now());
      log.log(LogCategory.playback, 'Auto bitrate: measured ${bps}bps');
      return bps;
    } catch (e) {
      log.log(LogCategory.playback, 'Auto bitrate: measurement failed ($e)');
      return null;
    }
  }
}
