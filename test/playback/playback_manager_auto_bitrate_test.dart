import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:playback_core/playback_core.dart';

/// A backend whose device profile carries no bitrate, the shape an Auto
/// quality setting produces, so the manager asks the auto bitrate provider.
class _AutoBackend extends Fake implements PlayerBackend {
  bool playing = false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration =>
      playing ? const Duration(minutes: 30) : Duration.zero;

  @override
  Duration get buffer => Duration.zero;

  @override
  bool get isPlaying => playing;

  @override
  double get playbackSpeed => 1.0;

  @override
  bool get isBuffering => false;

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> get durationStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> get bufferStream => const Stream<Duration>.empty();

  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();

  @override
  Stream<bool> get bufferingStream => const Stream<bool>.empty();

  @override
  Stream<bool>? get pictureShownStream => null;

  @override
  Stream<bool> get completedStream => const Stream<bool>.empty();

  @override
  Stream<Map<String, dynamic>>? get errorStream => null;

  @override
  bool get supportsRuntimeTrackSelection => false;

  @override
  bool get canRenderBitmapSubtitles => false;

  @override
  bool get requiresStartupMediaReadyCheck => false;

  @override
  bool get nativelyHandlesStartPosition => true;

  @override
  Map<String, dynamic> getDeviceProfile({
    bool useProgressiveTranscode = false,
  }) => <String, dynamic>{};

  @override
  Future<void> play(
    dynamic mediaItem, {
    Duration startPosition = Duration.zero,
  }) async {
    playing = true;
  }

  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> setSubtitleRendererMode(SubtitleRendererMode mode) async {}

  @override
  void dispose() {}
}

/// Records the bitrate ceiling each PlaybackInfo request went out with.
class _TestResolver extends MediaStreamResolver {
  final List<int?> requestedCaps = <int?>[];
  final List<int?> profileCaps = <int?>[];

  @override
  Future<StreamResolutionResult> resolve(
    dynamic mediaItem, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? startTimeTicks,
    String? mediaSourceId,
    bool enableDirectPlay = true,
    bool enableDirectStream = true,
    bool enableTranscoding = true,
  }) async {
    requestedCaps.add(maxStreamingBitrate);
    profileCaps.add(deviceProfile?['MaxStreamingBitrate'] as int?);
    final n = requestedCaps.length;
    final type = mediaItem is Map
        ? mediaItem['Type']
        : (mediaItem as AggregatedItem).rawData['Type'];
    final isLive = type == 'TvChannel' || type == 'LiveTvChannel';
    return StreamResolutionResult(
      streamUrl: 'https://example.test/session-$n',
      mediaSourceId: 'source-$n',
      liveStreamId: isLive ? 'live-$n' : null,
      playSessionId: 'session-$n',
      playMethod: StreamPlayMethod.directPlay,
    );
  }
}

class _TestService implements PlayerService {
  @override
  Future<void> onPlaybackStart(
    dynamic mediaItem,
    StreamResolutionResult resolution, {
    int? positionTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

  @override
  Future<void> onPlaybackProgress(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position, {
    bool isPaused = false,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

  @override
  Future<void> onPlaybackStop(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position,
  ) async {}

  @override
  Future<void> closeLiveStream(String liveStreamId) async {}

  @override
  Future<void> stopTranscoding(StreamResolutionResult resolution) async {}

  @override
  void dispose() {}
}

/// Stands in for AutoBitrateService: a measured figure comes back
/// synchronously, a download in progress comes back as its future.
class _Link {
  int? measured;
  final Completer<int?> download = Completer<int?>();
  int asks = 0;

  FutureOr<int?> call() {
    asks++;
    final known = measured;
    if (known != null) return known;
    return download.future;
  }

  /// The download lands: the figure is cached for whoever asks next.
  void finish(int bps) {
    measured = bps;
    download.complete(bps);
  }
}

class _Harness {
  _Harness(this.link) {
    manager = PlaybackManager()
      ..setBackend(_AutoBackend())
      ..setResolver(resolver)
      ..setPlayerService(_TestService())
      ..autoBitrateProvider = link.call;
  }

  final _Link link;
  final resolver = _TestResolver();
  late final PlaybackManager manager;

  /// Fails instead of hanging when a bringup sits behind something.
  Future<void> play(dynamic item) =>
      manager.playItems(<dynamic>[item]).timeout(const Duration(seconds: 5));

  Future<void> dispose() async {
    await manager.stop();
    manager.dispose();
  }
}

Map<String, dynamic> channel(String id) => <String, dynamic>{
  'Id': id,
  'Type': 'TvChannel',
  'Name': 'Channel $id',
};

const _movie = <String, dynamic>{'Id': 'movie', 'Type': 'Movie'};

AggregatedItem movieAt(int bps) => AggregatedItem(
  id: 'movie-$bps',
  serverId: 'server',
  rawData: <String, dynamic>{
    'Id': 'movie-$bps',
    'Type': 'Movie',
    'MediaSources': <Map<String, dynamic>>[
      <String, dynamic>{'Id': 'src', 'Bitrate': bps},
    ],
  },
);

void main() {
  group('a live channel change', () {
    test('goes out at once, uncapped, while the link is still being measured',
        () async {
      final h = _Harness(_Link());
      try {
        await h.play(channel('1'));

        expect(h.link.asks, 1);
        expect(h.resolver.requestedCaps, <int?>[null]);
        expect(h.resolver.profileCaps, <int?>[null]);
      } finally {
        await h.dispose();
      }
    });

    test('takes a figure the link already has', () async {
      final h = _Harness(_Link()..measured = 6000000);
      try {
        await h.play(channel('1'));

        expect(h.resolver.requestedCaps, <int?>[6000000]);
        expect(h.resolver.profileCaps, <int?>[6000000]);
      } finally {
        await h.dispose();
      }
    });

    test('a download that finished in the background caps the next channel',
        () async {
      final h = _Harness(_Link());
      try {
        await h.play(channel('1'));
        expect(h.resolver.requestedCaps, <int?>[null]);

        h.link.finish(4000000);
        await h.play(channel('2'));

        expect(h.resolver.requestedCaps, <int?>[null, 4000000]);
      } finally {
        await h.dispose();
      }
    });

    test('a link that could not be measured leaves every channel uncapped',
        () async {
      final h = _Harness(_Link());
      try {
        await h.play(channel('1'));
        h.link.download.complete(null);
        await h.play(channel('2'));

        expect(h.resolver.requestedCaps, <int?>[null, null]);
      } finally {
        await h.dispose();
      }
    });
  });

  group('an on-demand play', () {
    test('waits for the measurement and is capped by it', () async {
      final link = _Link();
      final h = _Harness(link);
      try {
        final play = h.play(_movie);
        await pumpEventQueue();
        expect(h.resolver.requestedCaps, isEmpty,
            reason: 'PlaybackInfo must not go out before the figure lands');

        link.finish(4000000);
        await play;

        expect(h.resolver.requestedCaps, <int?>[4000000]);
        expect(h.resolver.profileCaps, <int?>[4000000]);
      } finally {
        await h.dispose();
      }
    });

    test('goes out uncapped when nothing could be measured', () async {
      final link = _Link();
      final h = _Harness(link);
      try {
        final play = h.play(_movie);
        link.download.complete(null);
        await play;

        expect(h.resolver.requestedCaps, <int?>[null]);
      } finally {
        await h.dispose();
      }
    });

    test('drops a cap that sits below the source, so direct play survives',
        () async {
      final h = _Harness(_Link()..measured = 4000000);
      try {
        await h.play(movieAt(10000000));

        expect(h.resolver.requestedCaps, <int?>[null]);
        expect(h.resolver.profileCaps, <int?>[null]);
      } finally {
        await h.dispose();
      }
    });

    test('keeps the cap over a source that fits under it', () async {
      final h = _Harness(_Link()..measured = 4000000);
      try {
        await h.play(movieAt(2000000));

        expect(h.resolver.requestedCaps, <int?>[4000000]);
      } finally {
        await h.dispose();
      }
    });
  });

  test('no provider at all leaves the request uncapped', () async {
    final h = _Harness(_Link()..measured = 6000000);
    h.manager.autoBitrateProvider = null;
    try {
      await h.play(channel('1'));

      expect(h.link.asks, 0);
      expect(h.resolver.requestedCaps, <int?>[null]);
    } finally {
      await h.dispose();
    }
  });
}
