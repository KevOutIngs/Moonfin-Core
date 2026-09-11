import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:server_core/server_core.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockLiveTvApi extends Mock implements LiveTvApi {}

Map<String, dynamic> _channel(String id, {String? number}) => {
  'Id': id,
  'Name': 'Ch $id',
  'ChannelNumber': ?number,
};

Map<String, dynamic> _program(
  String id,
  String channelId, {
  bool isSports = false,
  bool isKids = false,
}) => {
  'Id': id,
  'ChannelId': channelId,
  'Name': 'Program $id',
  'StartDate': '2026-09-11T10:00:00Z',
  'EndDate': '2026-09-11T11:00:00Z',
  'IsSports': isSports,
  'IsKids': isKids,
};

/// Marks a getGuide argument as wild-carded; anything else is matched as a
/// literal (including null, so `channelIds: null` asserts no channel list).
const _wild = Object();

Future<Map<String, dynamic>> _anyGuide(
  LiveTvApi api, {
  bool captureChannelIds = false,
  Object? channelIds = _wild,
  Object? isMovie = _wild,
  Object? isSeries = _wild,
  Object? isSports = _wild,
  Object? isNews = _wild,
  Object? isKids = _wild,
}) {
  bool? flag(Object? v, String name) =>
      identical(v, _wild) ? any(named: name) : v as bool?;
  return api.getGuide(
    startDate: any(named: 'startDate'),
    endDate: any(named: 'endDate'),
    channelIds: captureChannelIds
        ? captureAny(named: 'channelIds')
        : identical(channelIds, _wild)
            ? any(named: 'channelIds')
            : channelIds as List<String>?,
    isMovie: flag(isMovie, 'isMovie'),
    isSeries: flag(isSeries, 'isSeries'),
    isSports: flag(isSports, 'isSports'),
    isNews: flag(isNews, 'isNews'),
    isKids: flag(isKids, 'isKids'),
    fields: any(named: 'fields'),
    enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
    enableImages: any(named: 'enableImages'),
    enableUserData: any(named: 'enableUserData'),
    userId: any(named: 'userId'),
  );
}

void _stubChannels(LiveTvApi liveTv, List<Map<String, dynamic>> channels) {
  when(
    () => liveTv.getChannels(
      sortBy: any(named: 'sortBy'),
      sortOrder: any(named: 'sortOrder'),
      fields: any(named: 'fields'),
      enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
      userId: any(named: 'userId'),
    ),
  ).thenAnswer((_) async => {'Items': channels});
}

void main() {
  late _MockClient client;
  late _MockLiveTvApi liveTv;

  setUp(() {
    client = _MockClient();
    liveTv = _MockLiveTvApi();
    when(() => client.liveTvApi).thenReturn(liveTv);
    when(() => client.userId).thenReturn('user');
    when(() => _anyGuide(liveTv)).thenAnswer((_) async => {'Items': <dynamic>[]});
  });

  test(
    'load() fetches only the first batch; loadMorePrograms() paginates the rest',
    () async {
      // 120 channels → batches of 50 (never one giant all-channels request).
      final channels = List.generate(120, (i) => _channel('c$i'));
      when(
        () => liveTv.getChannels(
          sortBy: any(named: 'sortBy'),
          sortOrder: any(named: 'sortOrder'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer((_) async => {'Items': channels});

      final vm = LiveTvGuideViewModel(client);
      await vm.load();

      // Initial load requested exactly one batch of 50 channels, not all 120.
      final captured = verify(
        () => _anyGuide(liveTv, captureChannelIds: true),
      ).captured;
      expect(captured.length, 1);
      expect((captured.single as List).length, 50);
      expect(vm.programsHighWater, 50);
      expect(vm.hasMorePrograms, isTrue);

      await vm.loadMorePrograms();
      expect(vm.programsHighWater, 100);
      expect(vm.hasMorePrograms, isTrue);

      await vm.loadMorePrograms();
      expect(vm.programsHighWater, 120);
      expect(vm.hasMorePrograms, isFalse);

      // Further calls are no-ops once every channel has been requested.
      await vm.loadMorePrograms();
      expect(vm.programsHighWater, 120);
    },
  );

  group('category filters', () {
    test(
      'a category chip asks the server for the whole lineup, not the first 50',
      () async {
        final channels = List.generate(
          120,
          (i) => _channel('c$i', number: '$i'),
        );
        _stubChannels(liveTv, channels);
        // Sports programs on channels well past the lazily-loaded prefix.
        when(
          () => _anyGuide(liveTv, channelIds: null, isSports: true),
        ).thenAnswer(
          (_) async => {
            'Items': [
              _program('p1', 'c110', isSports: true),
              _program('p2', 'c7', isSports: true),
              _program('p3', 'c60', isSports: true),
              // A server that ignores the flag: dropped client-side.
              _program('p4', 'c8', isKids: true),
            ],
          },
        );

        final vm = LiveTvGuideViewModel(client);
        await vm.load();
        expect(vm.programsHighWater, 50);

        vm.setFilter(GuideFilter.sports);
        expect(vm.state, GuideState.loading);
        await Future<void>.delayed(Duration.zero);
        expect(vm.state, GuideState.ready);

        // One server-wide request: no ChannelIds, only the sports flag set.
        verify(
          () => _anyGuide(
            liveTv,
            channelIds: null,
            isMovie: null,
            isSeries: null,
            isSports: true,
            isNews: null,
            isKids: null,
          ),
        ).called(1);

        // Channel-number order is kept (not response order), and c110 (row
        // 111) shows up even though only the first 50 channels had programs
        // loaded for the All view.
        expect(vm.filteredChannels.map((c) => c.id), ['c7', 'c60', 'c110']);
        expect(vm.hasProgramsFor('c110'), isTrue);
        expect(vm.programsForChannel('c110').single.id, 'p1');
        expect(vm.hasMorePrograms, isFalse);
      },
    );

    test('switching chips drops a stale in-flight category response', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      final sports = Completer<Map<String, dynamic>>();
      when(
        () => _anyGuide(liveTv, channelIds: null, isSports: true),
      ).thenAnswer((_) => sports.future);
      when(() => _anyGuide(liveTv, channelIds: null, isKids: true)).thenAnswer(
        (_) async => {
          'Items': [_program('k1', 'c3', isKids: true)],
        },
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();

      vm.setFilter(GuideFilter.sports);
      vm.setFilter(GuideFilter.kids);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.map((c) => c.id), ['c3']);

      // The slow sports response lands late and must not clobber Kids.
      sports.complete({
        'Items': [_program('s1', 'c1', isSports: true)],
      });
      await Future<void>.delayed(Duration.zero);
      expect(vm.filter, GuideFilter.kids);
      expect(vm.filteredChannels.map((c) => c.id), ['c3']);
    });

    test('backing out of a pending category returns to the All view', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      final sports = Completer<Map<String, dynamic>>();
      when(
        () => _anyGuide(liveTv, channelIds: null, isSports: true),
      ).thenAnswer((_) => sports.future);

      final vm = LiveTvGuideViewModel(client);
      await vm.load();

      vm.setFilter(GuideFilter.sports);
      expect(vm.state, GuideState.loading);
      vm.setFilter(GuideFilter.all);
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.length, 10);

      sports.complete({'Items': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.length, 10);
    });

    test('shifting the window re-fetches the active category', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      when(
        () => _anyGuide(liveTv, channelIds: null, isKids: true),
      ).thenAnswer(
        (_) async => {
          'Items': [_program('k1', 'c5', isKids: true)],
        },
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.kids);
      await Future<void>.delayed(Duration.zero);

      await vm.shiftWindow(3);

      verify(
        () => _anyGuide(liveTv, channelIds: null, isKids: true),
      ).called(2);
      expect(vm.filteredChannels.map((c) => c.id), ['c5']);
    });
  });
}
