import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_core/server_core.dart';

/// A stand-in for a Jellyfin server running the Achievement Badges plugin,
/// shared by the service and panel tests.

class MockMediaServerClient extends Mock implements MediaServerClient {}

/// Answers the plugin's routes the way it does, with PascalCase properties and
/// null fields left out of the payload rather than written as null. Records
/// every request so tests can assert which ones ran.
class AchievementPluginAdapter implements HttpClientAdapter {
  final List<String> requests = [];

  /// Set when no plugin is installed, which answers 404 for every route.
  bool pluginMissing = false;

  /// The plugin's admin switches.
  bool leaderboardEnabled = true;
  bool questsEnabled = true;

  /// One reroll a day and one a week, the same budget the plugin grants.
  int dailyRerollsLeft = 1;
  int weeklyRerollsLeft = 1;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requests.add('${options.method} $path');

    if (pluginMissing) {
      return ResponseBody.fromString('', 404);
    }

    dynamic body;
    if (path.endsWith('/public-config')) {
      body = {
        'LeaderboardEnabled': leaderboardEnabled,
        'QuestsEnabled': questsEnabled,
        'ForcePrivacyMode': false,
      };
    } else if (path.contains('/chase/')) {
      body = {
        'BadgeId': path.split('/').last,
        'Progress': {'Current': 4, 'Target': 10},
        'Items': [
          {
            'Id': 'item-1',
            'Name': 'Trolls Band Together',
            'Type': 'Movie',
            'Year': 2023,
            'RunTimeMinutes': 91,
          },
          {
            'Id': 'item-2',
            'Name': 'Beef',
            'Type': 'Episode',
            'Year': 2026,
            'RunTimeMinutes': 24,
          },
        ],
      };
    } else if (path.endsWith('/login-ping')) {
      body = {'Success': true};
    } else if (path.endsWith('/quests/daily/reroll') ||
        path.endsWith('/quests/weekly/reroll')) {
      final weekly = path.endsWith('/quests/weekly/reroll');
      final left = weekly ? weeklyRerollsLeft : dailyRerollsLeft;
      if (left <= 0) {
        return ResponseBody.fromString(
          jsonEncode({'Message': 'Already used.'}),
          429,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (weekly) {
        weeklyRerollsLeft = 0;
      } else {
        dailyRerollsLeft = 0;
      }
      body = {
        'Message': 'Rerolled.',
        'RerollsUsed': 1,
        'RerollsRemaining': 0,
        'Quests': [
          {
            'Kind': weekly ? 'weekly' : 'daily',
            'Id': weekly ? 'weekly-fresh' : 'daily-fresh',
            'Title': weekly ? 'A fresh week' : 'A fresh day',
            'Description': 'Rerolled quest.',
            'Icon': 'refresh',
            'Reward': 30,
            'Target': 2,
            'Current': 0,
            'Completed': false,
          },
        ],
      };
    } else if (path.endsWith('/summary')) {
      body = {
        'Unlocked': 12,
        'Total': 200,
        'Percentage': 6.0,
        'EquippedCount': 1,
        'Score': 430,
        'CurrentWatchStreak': 3,
        'BestWatchStreak': 9,
      };
    } else if (path.endsWith('/rank')) {
      body = {
        'Score': 430,
        'Tier': {
          'Name': 'Viewer',
          'MinScore': 300,
          'Color': '#2196f3',
          'Icon': 'visibility',
        },
        'NextTier': {
          'Name': 'Regular',
          'MinScore': 700,
          'Color': '#03a9f4',
          'Icon': 'person',
        },
        'ProgressToNext': 32,
        'Tiers': const <dynamic>[],
      };
    } else if (path.endsWith('/equipped')) {
      body = [
        {
          'Id': 'first-contact',
          'Title': 'First Contact',
          'Description': 'Watch your first item.',
          'Icon': 'rocket_launch',
          'Category': 'Getting Started',
          'Rarity': 'Common',
          'Unlocked': true,
          'UnlockedAt': '2026-09-01T10:00:00.0000000+00:00',
          'CurrentValue': 1,
          'TargetValue': 1,
        },
      ];
    } else if (path.endsWith('/quests')) {
      body = {
        'Daily': [
          {
            'Kind': 'daily',
            'Id': 'daily-watch',
            'Title': 'Watch something',
            'Description': 'Finish one item today.',
            'Icon': 'play_circle',
            'Reward': 25,
            'Target': 1,
            'Current': 0,
            'Completed': false,
          },
        ],
        'Weekly': const <dynamic>[],
        'DailyRerollsRemaining': dailyRerollsLeft,
        'WeeklyRerollsRemaining': weeklyRerollsLeft,
      };
    } else if (path.endsWith('/leaderboard')) {
      body = [
        {
          'UserId': 'user1',
          'UserName': 'Ada',
          'Unlocked': 12,
          'Total': 200,
          'Percentage': 6.0,
          'Score': 430,
          'BestWatchStreak': 9,
          'Equipped': const <dynamic>[],
        },
      ];
    } else if (path.contains('/leaderboard/')) {
      body = [
        {
          'UserId': 'user1',
          'UserName': 'Ada',
          'Value': 42,
          'Equipped': const <dynamic>[],
        },
      ];
    } else if (path.endsWith('/recap')) {
      body = {
        'Period': options.uri.queryParameters['period'],
        'Days': 30,
        'MoviesWatched': 4,
        'EpisodesWatched': 18,
        'TotalItems': 22,
        'DaysWatched': 11,
        'BadgesUnlocked': 2,
        'TopGenres': [
          {'Name': 'Drama', 'Count': 9},
        ],
        'TopDirectors': const <dynamic>[],
        'TopActors': const <dynamic>[],
      };
    } else if (path.endsWith('/library-completion')) {
      body = {
        'LibraryCompletionPercents': {'Movies': 63, 'Shows': 12},
      };
    } else if (path.endsWith('/users/user1')) {
      body = [
        {
          'Id': 'first-contact',
          'Title': 'First Contact',
          'Description': 'Watch your first item.',
          'Icon': 'rocket_launch',
          'Category': 'Getting Started',
          'Rarity': 'Common',
          'Unlocked': true,
          'UnlockedAt': '2026-09-01T10:00:00.0000000+00:00',
          'CurrentValue': 1,
          'TargetValue': 1,
        },
        {
          'Id': 'binge-titan',
          'Title': 'Binge Titan',
          'Description': 'Watch 10 episodes in a day.',
          'Icon': 'bolt',
          'Category': 'Binge',
          'Rarity': 'Epic',
          'Unlocked': false,
          'CurrentValue': 4,
          'TargetValue': 10,
        },
        {
          // A locked secret badge. The server masks it and never sends
          // a flag saying so.
          'Id': 'deep-cut',
          'Title': '???',
          'Description': 'Hidden achievement, keep watching to discover it.',
          'Icon': 'help',
          'Category': 'Hidden',
          'Rarity': 'Mythic',
          'Unlocked': false,
          'CurrentValue': 0,
          'TargetValue': 1,
        },
      ];
    }

    if (body == null) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A signed-in client pointed at the fake server.
MockMediaServerClient buildAchievementClient({
  ServerType serverType = ServerType.jellyfin,
  String baseUrl = 'http://badges.test',
  String? token = 'token',
  String? userId = 'user1',
}) {
  final mock = MockMediaServerClient();
  when(() => mock.baseUrl).thenReturn(baseUrl);
  when(() => mock.accessToken).thenReturn(token);
  when(() => mock.userId).thenReturn(userId);
  when(() => mock.serverType).thenReturn(serverType);
  when(() => mock.deviceInfo).thenReturn(
    const DeviceInfo(
      id: 'dev1',
      name: 'test',
      appName: 'moonfin',
      appVersion: '0.0.0',
    ),
  );
  return mock;
}
