import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/hdr_output_controller.dart';

void main() {
  group('isHdrVideoParams', () {
    test('PQ and HLG transfers are HDR', () {
      expect(isHdrVideoParams(gamma: 'pq', primaries: 'bt.2020'), isTrue);
      expect(isHdrVideoParams(gamma: 'st2084', primaries: 'bt.2020'), isTrue);
      expect(isHdrVideoParams(gamma: 'hlg', primaries: 'bt.2020'), isTrue);
    });

    test('plain SDR is not', () {
      expect(isHdrVideoParams(gamma: 'bt.1886', primaries: 'bt.709'), isFalse);
      expect(isHdrVideoParams(gamma: 'srgb', primaries: 'bt.709'), isFalse);
      expect(isHdrVideoParams(gamma: null, primaries: null), isFalse);
    });

    test('BT.2020 primaries alone count, which is the Profile 5 case', () {
      // A Dolby Vision Profile 5 stream has no HDR10 base layer and often no
      // VUI transfer characteristic, so mpv reports it as SDR until
      // libplacebo applies the RPU - which only happens once the native
      // window is engaged, which is the decision this feeds.
      expect(isHdrVideoParams(gamma: 'bt.1886', primaries: 'bt.2020'), isTrue);
      expect(isHdrVideoParams(gamma: null, primaries: 'bt.2020'), isTrue);
    });

    test('case and spelling variants of the transfer are accepted', () {
      expect(isHdrVideoParams(gamma: 'PQ', primaries: 'BT.709'), isTrue);
      expect(isHdrVideoParams(gamma: 'HLG', primaries: 'BT.709'), isTrue);
    });
  });

  group('HdrOutputController.maybeEngage', () {
    /// Runs a decision with every gate open unless overridden. The window
    /// itself is never created, because each test stops at a gate ahead of it.
    Future<HdrOutputController> decide({
      bool preferenceEnabled = true,
      bool isHdrContent = true,
      bool displayInHdrMode = true,
      List<String>? calls,
    }) async {
      final controller = HdrOutputController();
      await controller.maybeEngage(
        preferenceEnabled: preferenceEnabled,
        isHdrContent: () async {
          calls?.add('content');
          return isHdrContent;
        },
        displayInHdrMode: () async {
          calls?.add('display');
          return displayInHdrMode;
        },
        engageMpv: (_) async {
          calls?.add('engage');
          return true;
        },
      );
      return controller;
    }

    test('starts out reporting SDR content', () {
      expect(
        HdrOutputController().status.value.reason,
        HdrOutputReason.contentIsSdr,
      );
    });

    test('the preference is the first gate, and nothing else is asked', () async {
      final calls = <String>[];
      final controller = await decide(preferenceEnabled: false, calls: calls);

      expect(
        controller.status.value.reason,
        HdrOutputReason.disabledByPreference,
      );
      // Both remaining checks are expensive - waiting on mpv's video-params,
      // and enumerating every display path - so neither may run once the
      // answer is already no.
      expect(calls, isEmpty);
    });

    test('SDR content stops before the display is queried', () async {
      final calls = <String>[];
      final controller = await decide(isHdrContent: false, calls: calls);

      expect(controller.status.value.reason, HdrOutputReason.contentIsSdr);
      expect(calls, ['content']);
    });

    test('an SDR display stops before mpv is handed anything', () async {
      final calls = <String>[];
      final controller = await decide(displayInHdrMode: false, calls: calls);

      expect(
        controller.status.value.reason,
        HdrOutputReason.displayNotInHdrMode,
      );
      expect(calls, ['content', 'display']);
    });

    test('a status change notifies, so the player can swap surfaces', () async {
      final controller = HdrOutputController();
      var notified = 0;
      controller.status.addListener(() => notified++);

      await controller.maybeEngage(
        preferenceEnabled: false,
        isHdrContent: () async => true,
        displayInHdrMode: () async => true,
        engageMpv: (_) async => true,
      );

      expect(notified, 1);
    });

    test('not engaged and not failed on a plain SDR decision', () async {
      final controller = await decide(isHdrContent: false);
      expect(controller.isEngaged, isFalse);
      expect(controller.hasFailed, isFalse);
    });
  });
}
