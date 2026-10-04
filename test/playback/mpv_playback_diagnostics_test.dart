import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/mpv_playback_diagnostics.dart';

void main() {
  testWidgets('logs the setup once and counter changes per window', (
    tester,
  ) async {
    final props = <String, String>{
      'current-vo': 'libmpv',
      'hwdec-current': 'd3d11va-copy',
      'video-params/w': '3840',
      'video-params/h': '2160',
      'frame-drop-count': '4',
      'decoder-frame-drop-count': '0',
      'estimated-vf-fps': '23.976',
      'avsync': '0.0021',
    };
    final lines = <String>[];
    var playing = true;
    final diagnostics = MpvPlaybackDiagnostics(
      readProperty: (key) async => props[key],
      isPlaying: () => playing,
      renderPath: () => 'texture',
      textureSize: () => const Size(3840, 2160),
      log: lines.add,
    );

    diagnostics.start();
    await tester.pump(const Duration(seconds: 10));
    props['frame-drop-count'] = '10';
    await tester.pump(const Duration(seconds: 10));

    final setups = lines.where((l) => l.startsWith('Video setup:')).toList();
    final stats = lines.where((l) => l.startsWith('Video stats')).toList();
    expect(setups, hasLength(1));
    expect(setups.single, contains('path=texture'));
    expect(setups.single, contains('hwdec-current=d3d11va-copy'));
    expect(setups.single, contains('texture=3840x2160'));
    expect(stats, hasLength(2));
    expect(stats[0], contains('vo-drops=+4'));
    expect(stats[1], contains('vo-drops=+6'));
    expect(stats[1], contains('avsync=2.1ms'));

    // Paused time is not sampled.
    playing = false;
    await tester.pump(const Duration(seconds: 10));
    expect(lines.where((l) => l.startsWith('Video stats')), hasLength(2));

    diagnostics.stop();
  });
}
