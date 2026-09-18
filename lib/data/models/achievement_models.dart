/// Models for the Achievement Badges plugin.
///
/// The plugin writes PascalCase names and leaves a null property out of the
/// payload instead of writing it, so anything the server can omit is nullable
/// here. Admins can author badges with any category, rarity or icon string,
/// which is why none of those are enums.
library;

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String _asString(dynamic value) => value is String ? value : '';

bool _asBool(dynamic value) => value is bool ? value : false;

DateTime? _asDate(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

/// Points a badge is worth. The plugin works this out from rarity instead of
/// storing it per badge, so the table has to be repeated here.
int _scoreForRarity(String rarity) {
  switch (rarity.trim().toLowerCase()) {
    case 'uncommon':
      return 20;
    case 'rare':
      return 35;
    case 'epic':
      return 60;
    case 'legendary':
      return 100;
    case 'mythic':
      return 150;
    default:
      return 10;
  }
}

class AchievementSummary {
  const AchievementSummary({
    required this.unlocked,
    required this.total,
    required this.percentage,
    required this.score,
    required this.currentWatchStreak,
    required this.bestWatchStreak,
  });

  final int unlocked;
  final int total;
  final double percentage;
  final int score;
  final int currentWatchStreak;
  final int bestWatchStreak;

  factory AchievementSummary.fromJson(Map<String, dynamic> json) {
    return AchievementSummary(
      unlocked: _asInt(json['Unlocked']),
      total: _asInt(json['Total']),
      percentage: _asDouble(json['Percentage']),
      score: _asInt(json['Score']),
      currentWatchStreak: _asInt(json['CurrentWatchStreak']),
      bestWatchStreak: _asInt(json['BestWatchStreak']),
    );
  }
}

class RankTier {
  const RankTier({
    required this.name,
    required this.minScore,
    required this.color,
    required this.icon,
  });

  final String name;
  final int minScore;

  /// Hex string as the plugin writes it, such as `#ffd700`.
  final String color;
  final String icon;

  factory RankTier.fromJson(Map<String, dynamic> json) {
    return RankTier(
      name: _asString(json['Name']),
      minScore: _asInt(json['MinScore']),
      color: _asString(json['Color']),
      icon: _asString(json['Icon']),
    );
  }
}

class AchievementRank {
  const AchievementRank({
    required this.score,
    required this.tier,
    required this.nextTier,
    required this.progressToNext,
  });

  final int score;
  final RankTier tier;

  /// Left out of the payload once the user reaches the top tier.
  final RankTier? nextTier;

  /// 0 to 100, and 100 at the top tier.
  final int progressToNext;

  bool get isTopTier => nextTier == null;

  factory AchievementRank.fromJson(Map<String, dynamic> json) {
    final tier = json['Tier'];
    final next = json['NextTier'];

    return AchievementRank(
      score: _asInt(json['Score']),
      tier: tier is Map<String, dynamic>
          ? RankTier.fromJson(tier)
          : const RankTier(name: '', minScore: 0, color: '', icon: ''),
      nextTier: next is Map<String, dynamic> ? RankTier.fromJson(next) : null,
      progressToNext: _asInt(json['ProgressToNext']),
    );
  }
}

class AchievementBadge {
  const AchievementBadge({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.category,
    required this.rarity,
    required this.unlocked,
    required this.unlockedAt,
    required this.currentValue,
    required this.targetValue,
  });

  final String id;
  final String title;
  final String description;

  /// A Material Icons name, not an emoji or a URL.
  final String icon;
  final String category;
  final String rarity;
  final bool unlocked;
  final DateTime? unlockedAt;
  final int currentValue;
  final int targetValue;

  /// The plugin never sends the secret flag. It masks a locked secret badge's
  /// title instead, and that mask is all a client gets to go on.
  bool get isSecret => !unlocked && title.trim() == '???';

  /// Whether the server blanked the description under spoiler mode.
  bool get descriptionHidden => !unlocked && description.trim() == '???';

  int get score => _scoreForRarity(rarity);

  /// 0 to 1. Target is 0 on badges that are just a flag.
  double get progress {
    if (unlocked) return 1;
    if (targetValue <= 0) return 0;
    return (currentValue / targetValue).clamp(0.0, 1.0);
  }

  factory AchievementBadge.fromJson(Map<String, dynamic> json) {
    return AchievementBadge(
      id: _asString(json['Id']),
      title: _asString(json['Title']),
      description: _asString(json['Description']),
      icon: _asString(json['Icon']),
      category: _asString(json['Category']),
      rarity: _asString(json['Rarity']),
      unlocked: _asBool(json['Unlocked']),
      unlockedAt: _asDate(json['UnlockedAt']),
      currentValue: _asInt(json['CurrentValue']),
      targetValue: _asInt(json['TargetValue']),
    );
  }
}

class AchievementQuest {
  const AchievementQuest({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.reward,
    required this.target,
    required this.current,
    required this.completed,
  });

  final String id;
  final String title;
  final String description;
  final String icon;

  /// Score points the quest pays out.
  final int reward;
  final int target;
  final int current;
  final bool completed;

  double get progress {
    if (completed) return 1;
    if (target <= 0) return 0;
    return (current / target).clamp(0.0, 1.0);
  }

  factory AchievementQuest.fromJson(Map<String, dynamic> json) {
    return AchievementQuest(
      id: _asString(json['Id']),
      title: _asString(json['Title']),
      description: _asString(json['Description']),
      icon: _asString(json['Icon']),
      reward: _asInt(json['Reward']),
      target: _asInt(json['Target']),
      current: _asInt(json['Current']),
      completed: _asBool(json['Completed']),
    );
  }
}

class AchievementQuests {
  const AchievementQuests({required this.daily, required this.weekly});

  final List<AchievementQuest> daily;
  final List<AchievementQuest> weekly;

  bool get isEmpty => daily.isEmpty && weekly.isEmpty;

  static List<AchievementQuest> _list(dynamic value) {
    if (value is! List) return const <AchievementQuest>[];
    return value
        .whereType<Map<String, dynamic>>()
        .map(AchievementQuest.fromJson)
        .toList();
  }

  factory AchievementQuests.fromJson(Map<String, dynamic> json) {
    return AchievementQuests(
      daily: _list(json['Daily']),
      weekly: _list(json['Weekly']),
    );
  }
}

/// One row of either leaderboard.
///
/// The overall board carries score and completion. A category board carries a
/// single [value] that means whatever the category is, and leaves the rest
/// null.
class LeaderboardEntry {
  const LeaderboardEntry({
    required this.userId,
    required this.userName,
    required this.score,
    required this.unlocked,
    required this.total,
    required this.value,
    required this.customTitle,
  });

  final String userId;
  final String userName;
  final int? score;
  final int? unlocked;
  final int? total;

  /// Set only on a category board.
  final int? value;

  /// The shop title the user equipped. Most people have none.
  final String? customTitle;

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    final customTitle = json['CustomTitle'];
    return LeaderboardEntry(
      userId: _asString(json['UserId']),
      userName: _asString(json['UserName']),
      score: json.containsKey('Score') ? _asInt(json['Score']) : null,
      unlocked: json.containsKey('Unlocked') ? _asInt(json['Unlocked']) : null,
      total: json.containsKey('Total') ? _asInt(json['Total']) : null,
      value: json.containsKey('Value') ? _asInt(json['Value']) : null,
      customTitle: customTitle is String && customTitle.isNotEmpty
          ? customTitle
          : null,
    );
  }
}

/// A name and how many items it covers, for the recap's top lists.
class RecapCount {
  const RecapCount({required this.name, required this.count});

  final String name;
  final int count;

  factory RecapCount.fromJson(Map<String, dynamic> json) {
    return RecapCount(
      name: _asString(json['Name']),
      count: _asInt(json['Count']),
    );
  }
}

class AchievementRecap {
  const AchievementRecap({
    required this.period,
    required this.moviesWatched,
    required this.episodesWatched,
    required this.daysWatched,
    required this.badgesUnlocked,
    required this.topGenres,
    required this.topDirectors,
    required this.topActors,
  });

  /// `week`, `month` or `year`, echoed back by the server.
  final String period;
  final int moviesWatched;
  final int episodesWatched;
  final int daysWatched;
  final int badgesUnlocked;
  final List<RecapCount> topGenres;
  final List<RecapCount> topDirectors;
  final List<RecapCount> topActors;

  static List<RecapCount> _counts(dynamic value) {
    if (value is! List) return const <RecapCount>[];
    return value
        .whereType<Map<String, dynamic>>()
        .map(RecapCount.fromJson)
        .toList();
  }

  factory AchievementRecap.fromJson(Map<String, dynamic> json) {
    return AchievementRecap(
      period: _asString(json['Period']),
      moviesWatched: _asInt(json['MoviesWatched']),
      episodesWatched: _asInt(json['EpisodesWatched']),
      daysWatched: _asInt(json['DaysWatched']),
      badgesUnlocked: _asInt(json['BadgesUnlocked']),
      topGenres: _counts(json['TopGenres']),
      topDirectors: _counts(json['TopDirectors']),
      topActors: _counts(json['TopActors']),
    );
  }
}

/// Everything the panel shows, fetched in one pass.
class AchievementsOverview {
  const AchievementsOverview({
    required this.summary,
    required this.rank,
    required this.badges,
    required this.equipped,
    required this.quests,
    required this.leaderboard,
    required this.recap,
    required this.libraryCompletion,
    required this.leaderboardEnabled,
    required this.questsEnabled,
  });

  final AchievementSummary? summary;
  final AchievementRank? rank;
  final List<AchievementBadge> badges;
  final List<AchievementBadge> equipped;
  final AchievementQuests? quests;
  final List<LeaderboardEntry> leaderboard;
  final AchievementRecap? recap;

  /// Library name to percent complete.
  final Map<String, int> libraryCompletion;

  /// Admin switches from the plugin's config. The panel hides a section the
  /// server turned off rather than drawing an empty one.
  final bool leaderboardEnabled;
  final bool questsEnabled;
}
