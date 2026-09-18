import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/data/services/achievements_service.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/screens/settings/achievements_screen.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:server_core/server_core.dart';

import '../../../support/achievement_plugin_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AchievementPluginAdapter adapter;

  /// Belongs in setUp rather than a test body. A widget test body runs against
  /// fake time, where the request timers these calls arm never fire.
  Future<void> arrange({bool leaderboardEnabled = true}) async {
    adapter = AchievementPluginAdapter()
      ..leaderboardEnabled = leaderboardEnabled;
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AchievementsService(dio: dio);
    final client = buildAchievementClient();

    GetIt.instance.registerSingleton<MediaServerClient>(client);
    GetIt.instance.registerSingleton<AchievementsService>(service);
    await service.refreshAvailability(client);
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AchievementsScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() async {
    await GetIt.instance.reset();
  });

  group('with every section on', () {
    setUp(arrange);

    testWidgets('shows the rank, score and what the sections hold', (
      tester,
    ) async {
      await pumpPanel(tester);

      expect(find.text('Viewer'), findsOneWidget);
      expect(find.text('430 points'), findsOneWidget);
      // 430 of 700 towards Regular.
      expect(find.text('270 points to Regular'), findsOneWidget);
      expect(find.text('12 of 200 badges'), findsWidgets);
      expect(find.text('Badges'), findsOneWidget);
      expect(find.text('Leaderboard'), findsOneWidget);
      expect(find.text('Recap'), findsOneWidget);
      expect(find.text('2 libraries'), findsOneWidget);
    });

    testWidgets('a masked secret badge isn\'t spoiled in the list', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Badges'));
      await tester.pumpAndSettle();

      // Categories start closed, so the badge isn't on screen yet.
      expect(find.text('Hidden achievement'), findsNothing);

      await tester.tap(find.text('Hidden'));
      await tester.pumpAndSettle();

      // The plugin masks the title as "???" and the panel names it instead.
      expect(find.text('???'), findsNothing);
      expect(find.text('Hidden achievement'), findsOneWidget);
    });

    testWidgets('the filter tabs narrow the list', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Badges'));
      await tester.pumpAndSettle();

      expect(find.text('Getting Started'), findsOneWidget);
      expect(find.text('Hidden'), findsOneWidget);

      await tester.tap(find.text('Locked'));
      await tester.pumpAndSettle();

      // The only unlocked badge takes its category off the list with it.
      expect(find.text('Getting Started'), findsNothing);
      expect(find.text('Hidden'), findsOneWidget);
    });

    testWidgets('rerolling swaps the daily set once confirmed', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Quests'));
      await tester.pumpAndSettle();

      expect(find.text('Watch something'), findsOneWidget);

      await tester.tap(find.text('Reroll daily quests'));
      await tester.pumpAndSettle();

      // A reroll is spent for the day, so it asks first.
      expect(find.text('Reroll these quests?'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('A fresh day'), findsOneWidget);
      expect(find.text('Watch something'), findsNothing);
      expect(
        find.text('Used today, comes back at midnight UTC'),
        findsOneWidget,
      );
    });

    testWidgets('backing out of the confirm leaves the set alone', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Quests'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reroll daily quests'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Watch something'), findsOneWidget);
      expect(find.text('Swap this set for a different one'), findsOneWidget);
    });

    testWidgets('a reroll the server already spent reads as used', (
      tester,
    ) async {
      adapter.dailyRerollsLeft = 0;

      await pumpPanel(tester);
      await tester.tap(find.text('Quests'));
      await tester.pumpAndSettle();

      expect(
        find.text('Used today, comes back at midnight UTC'),
        findsOneWidget,
      );
      expect(find.text('Swap this set for a different one'), findsNothing);
    });

    testWidgets('a plugin that stops answering offers a retry', (tester) async {
      adapter.pluginMissing = true;

      await pumpPanel(tester);

      expect(find.text('Could not load your achievements.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('on a television', () {
    setUp(() async {
      await arrange();
      PlatformDetection.setTvMode(true);
    });

    tearDown(() => PlatformDetection.setTvMode(false));

    testWidgets('select opens the focused row', (tester) async {
      await pumpPanel(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      // The badge list is open, so the first row took focus and activated.
      expect(find.text('Getting Started'), findsOneWidget);
    });

    testWidgets('a focused row darkens its text for the light ground', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Badges'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Binge'));
      await tester.pumpAndSettle();

      Color? countColor() =>
          tester.widget<Text>(find.text('4 / 10')).style?.color;

      final resting = countColor();
      expect(resting, isNotNull);

      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        final focused = countColor();
        if (focused != null && focused != resting) {
          expect(
            focused.computeLuminance(),
            lessThan(resting!.computeLuminance()),
          );
          return;
        }
      }
      fail('the badge row never adapted its text to the focus highlight');
    });

    testWidgets('badge rows take focus so the remote can scroll', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Badges'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden'));
      await tester.pumpAndSettle();

      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        if (FocusManager.instance.primaryFocus?.debugLabel ==
            'AchievementsReadOnlyRow') {
          return;
        }
      }
      fail("no badge row ever took focus, so a remote can't reach the list");
    });
  });

  group('with the leaderboard switched off', () {
    setUp(() => arrange(leaderboardEnabled: false));

    testWidgets('a section the admin switched off isn\'t offered', (
      tester,
    ) async {
      await pumpPanel(tester);

      expect(find.text('Leaderboard'), findsNothing);
      expect(find.text('Badges'), findsOneWidget);
    });
  });
}
