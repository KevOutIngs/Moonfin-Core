import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  final t0 = DateTime(2026, 9, 13, 21, 0);

  /// Feeds one sample a second for [seconds] at [bps] on a 1080p frame.
  void feed(
    StreamPictureEvidence e,
    int seconds,
    int bps, {
    int width = 1920,
    int height = 1080,
    int fromSecond = 0,
  }) {
    for (var i = 0; i < seconds; i++) {
      e.onSample(
        at: t0.add(Duration(seconds: fromSecond + i)),
        videoBitsPerSecond: bps,
        width: width,
        height: height,
      );
    }
  }

  test('nothing to say before there is enough history', () {
    final e = StreamPictureEvidence();
    feed(e, 1, 40000);
    expect(e.noPicture(t0.add(const Duration(seconds: 1))), isNull);
  });

  test('a zero rate is the player not having measured yet', () {
    final e = StreamPictureEvidence();
    feed(e, 6, 0);
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isNull);
  });

  test('a black placeholder carries too few bits to be a picture', () {
    // Around 40 kbit/s at 1080p.
    final e = StreamPictureEvidence();
    feed(e, 6, 40000);
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isTrue);
  });

  test('a real channel carries a picture', () {
    final e = StreamPictureEvidence();
    feed(e, 6, 2000000);
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isFalse);
  });

  test('a still picture with its keyframes carries a picture', () {
    // A logo on a flat colour: a keyframe every two seconds, little between.
    final e = StreamPictureEvidence();
    for (var i = 0; i < 6; i++) {
      e.onSample(
        at: t0.add(Duration(seconds: i)),
        videoBitsPerSecond: i.isEven ? 800000 : 20000,
        width: 1920,
        height: 1080,
      );
    }
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isFalse);
  });

  test('a poor sd channel still carries a picture', () {
    final e = StreamPictureEvidence();
    feed(e, 6, 400000, width: 720, height: 576);
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isFalse);
  });

  test('a black sd placeholder is still caught', () {
    final e = StreamPictureEvidence();
    feed(e, 6, 12000, width: 720, height: 576);
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isTrue);
  });

  test('the verdict follows the stream when it collapses mid-play', () {
    final e = StreamPictureEvidence();
    feed(e, 6, 2000000);
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isFalse);
    feed(e, 8, 40000, fromSecond: 6);
    expect(e.noPicture(t0.add(const Duration(seconds: 14))), isTrue);
  });

  test('reset forgets the samples', () {
    final e = StreamPictureEvidence();
    feed(e, 6, 40000);
    e.reset();
    expect(e.noPicture(t0.add(const Duration(seconds: 6))), isNull);
  });
}
