import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

import '../models/achievement_models.dart';

/// Bounds for these requests, so a server that swallows connection attempts
/// can't hold the settings panel open on a spinner.
@visibleForTesting
BaseOptions achievementRequestOptions() => BaseOptions(
  connectTimeout: const Duration(seconds: 8),
  receiveTimeout: const Duration(seconds: 15),
);

/// Reads the Achievement Badges plugin.
///
/// The plugin earns badges from Jellyfin's own playback events, so what people
/// watch in Moonfin already counts towards them. It just can't show them here,
/// because its own UI only reaches people by injecting scripts into
/// jellyfin-web. Everything it knows is on a plain HTTP API, which is what this
/// reads so the panel can be drawn natively on every platform.
class AchievementsService extends ChangeNotifier {
  static const String _root = 'Plugins/AchievementBadges';

  /// The plugin gives each user 60 requests a minute across all of its routes,
  /// so a panel load costs roughly a sixth of that. Nothing here polls.
  final Dio _dio;

  AchievementsService({@visibleForTesting Dio? dio})
    : _dio = dio ?? Dio(achievementRequestOptions()) {
    // An injected Dio brings its own adapter, so only the one built here needs
    // the server interceptors.
    if (dio == null) {
      configureServerDio(_dio);
      _dio.interceptors.add(redirectInterceptor(_dio));
    }
  }

  bool _available = false;

  /// Whether the plugin answered on this server. False until a probe succeeds,
  /// so the entry stays hidden on every server that doesn't run it.
  bool get available => _available;

  bool _leaderboardEnabled = true;
  bool _questsEnabled = true;

  String _base(MediaServerClient client) =>
      client.baseUrl.replaceAll(RegExp(r'/+$'), '');

  Map<String, String>? _authHeaders(MediaServerClient client) {
    final token = client.accessToken;
    if (token == null || token.isEmpty) return null;

    return {
      'Authorization': buildServerAuthorizationHeader(
        scheme: 'MediaBrowser',
        deviceInfo: client.deviceInfo,
        accessToken: token,
      ),
    };
  }

  /// Clears the flag when a session ends, so the entry can't survive into a
  /// server that has no plugin.
  void reset() {
    _leaderboardEnabled = true;
    _questsEnabled = true;
    if (!_available) return;
    debugPrint('[AchievementsService] cleared, the entry is hidden again');
    _available = false;
    notifyListeners();
  }

  /// Probes the server and records whether the plugin is there.
  ///
  /// Also sends the login ping, which is the one part of the plugin a client
  /// has to drive. The daily login streak only moves when a client reports the
  /// visit.
  Future<bool> refreshAvailability(MediaServerClient client) async {
    final probed = await _probe(client);
    if (probed != _available) {
      _available = probed;
      notifyListeners();
    }
    if (probed) {
      unawaited(sendLoginPing(client));
    }
    return probed;
  }

  Future<bool> _probe(MediaServerClient client) async {
    // It's a Jellyfin plugin, so an Emby server never carries it.
    if (client.serverType != ServerType.jellyfin) {
      debugPrint('[AchievementsService] not probing a ${client.serverType} server');
      return false;
    }

    // public-config needs no token, so this also answers for a user who isn't
    // an administrator. A server without the plugin has no such route and
    // answers 404.
    final config = await _getMap(client, 'public-config');
    debugPrint('[AchievementsService] probed ${_base(client)}, plugin '
        '${config == null ? "did not answer" : "is there"}');
    if (config == null) return false;

    _leaderboardEnabled = config['LeaderboardEnabled'] != false;
    _questsEnabled = config['QuestsEnabled'] != false;
    return true;
  }

  /// Credits the daily login streak. Failure stays silent because the streak is
  /// a nicety and an older plugin build has no such route.
  Future<void> sendLoginPing(MediaServerClient client) async {
    final userId = client.userId;
    final headers = _authHeaders(client);
    if (userId == null || userId.isEmpty || headers == null) return;

    try {
      await _dio.post<dynamic>(
        '${_base(client)}/$_root/users/$userId/login-ping',
        options: Options(headers: headers),
      );
    } catch (_) {}
  }

  Future<dynamic> _get(
    MediaServerClient client,
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final headers = _authHeaders(client);
    if (headers == null) return null;

    try {
      final response = await _dio.get<dynamic>(
        '${_base(client)}/$_root/$path',
        queryParameters: query,
        options: Options(headers: headers),
      );
      if (response.statusCode == 200) return response.data;
      debugPrint('[AchievementsService] $path answered ${response.statusCode}');
      return null;
    } catch (e) {
      // A 404 is how an older plugin build says it has no such route, which
      // loadOverview already treats as normal, so only real faults are worth
      // a line.
      final status = e is DioException ? e.response?.statusCode : null;
      if (status != 404) {
        debugPrint('[AchievementsService] $path failed: $e');
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getMap(
    MediaServerClient client,
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final data = await _get(client, path, query: query);
    return data is Map<String, dynamic> ? data : null;
  }

  Future<List<Map<String, dynamic>>> _getList(
    MediaServerClient client,
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final data = await _get(client, path, query: query);
    if (data is! List) return const <Map<String, dynamic>>[];
    return data.whereType<Map<String, dynamic>>().toList();
  }

  /// Loads everything the panel shows in one pass.
  ///
  /// A part that fails comes back null or empty instead of failing the whole
  /// load, because an older plugin build is missing some of these routes and
  /// one missing section is no reason to show an error page instead of the
  /// rest.
  Future<AchievementsOverview?> loadOverview(
    MediaServerClient client, {
    String recapPeriod = 'month',
    int leaderboardLimit = 10,
  }) async {
    final userId = client.userId;
    if (userId == null || userId.isEmpty) return null;
    if (client.serverType != ServerType.jellyfin) return null;

    final results = await Future.wait<dynamic>([
      _getMap(client, 'users/$userId/summary'),
      _getMap(client, 'users/$userId/rank'),
      _getList(client, 'users/$userId'),
      _getList(client, 'users/$userId/equipped'),
      _questsEnabled
          ? _getMap(client, 'users/$userId/quests')
          : Future<Map<String, dynamic>?>.value(null),
      _leaderboardEnabled
          ? _getList(client, 'leaderboard', query: {'limit': leaderboardLimit})
          : Future<List<Map<String, dynamic>>>.value(
              const <Map<String, dynamic>>[],
            ),
      _getMap(client, 'users/$userId/recap', query: {'period': recapPeriod}),
      _getMap(client, 'users/$userId/library-completion'),
    ]);

    final summary = results[0] as Map<String, dynamic>?;
    final rank = results[1] as Map<String, dynamic>?;
    final badges = results[2] as List<Map<String, dynamic>>;
    final equipped = results[3] as List<Map<String, dynamic>>;
    final quests = results[4] as Map<String, dynamic>?;
    final leaderboard = results[5] as List<Map<String, dynamic>>;
    final recap = results[6] as Map<String, dynamic>?;
    final completion = results[7] as Map<String, dynamic>?;

    // A server that answered none of it has lost the plugin, rather than
    // holding an empty profile.
    if (summary == null && badges.isEmpty && rank == null) return null;

    return AchievementsOverview(
      summary: summary == null ? null : AchievementSummary.fromJson(summary),
      rank: rank == null ? null : AchievementRank.fromJson(rank),
      badges: badges.map(AchievementBadge.fromJson).toList(),
      equipped: equipped.map(AchievementBadge.fromJson).toList(),
      quests: quests == null ? null : AchievementQuests.fromJson(quests),
      leaderboard: leaderboard.map(LeaderboardEntry.fromJson).toList(),
      recap: recap == null ? null : AchievementRecap.fromJson(recap),
      libraryCompletion: _readCompletion(completion),
      leaderboardEnabled: _leaderboardEnabled,
      questsEnabled: _questsEnabled,
    );
  }

  Map<String, int> _readCompletion(Map<String, dynamic>? json) {
    final percents = json?['LibraryCompletionPercents'];
    if (percents is! Map) return const <String, int>{};

    final result = <String, int>{};
    percents.forEach((key, value) {
      if (key is String && value is num) {
        result[key] = value.round();
      }
    });
    return result;
  }

  /// Reloads the recap alone, for the period picker.
  Future<AchievementRecap?> fetchRecap(
    MediaServerClient client,
    String period,
  ) async {
    final userId = client.userId;
    if (userId == null || userId.isEmpty) return null;

    final json = await _getMap(
      client,
      'users/$userId/recap',
      query: {'period': period},
    );
    return json == null ? null : AchievementRecap.fromJson(json);
  }

  @override
  void dispose() {
    _dio.close(force: true);
    super.dispose();
  }

  /// Reloads one leaderboard alone, for the category picker.
  ///
  /// An empty [category] asks for the overall score board. The plugin answers
  /// an unknown category with that board too, rather than a 404.
  Future<List<LeaderboardEntry>> fetchLeaderboard(
    MediaServerClient client, {
    String category = '',
    int limit = 10,
  }) async {
    if (!_leaderboardEnabled) return const <LeaderboardEntry>[];

    final path = category.isEmpty ? 'leaderboard' : 'leaderboard/$category';
    final rows = await _getList(client, path, query: {'limit': limit});
    return rows.map(LeaderboardEntry.fromJson).toList();
  }
}
