import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:server_core/server_core.dart';

import '../../../data/models/achievement_models.dart';
import '../../../data/services/achievements_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../util/achievement_icons.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../../util/platform_detection.dart';
import '../../navigation/destinations.dart';
import '../../widgets/adaptive/adaptive_dialog.dart';
import '../../widgets/adaptive/adaptive_list_section.dart';
import '../../widgets/focus/dpad_list_tile.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/settings/clean_settings_typography.dart';
import '../../widgets/settings/preference_tiles.dart';
import '../../widgets/settings/settings_panel.dart';
import '../../widgets/settings/settings_section_header.dart';
import '../../widgets/sliding_pill_tabs.dart';
import 'settings_app_bar.dart';

/// Shows what the Achievement Badges plugin has recorded for the signed-in
/// user.
///
/// Read-only. The plugin's shop, power-ups, friends and messaging all need
/// write calls and a lot more UI than this.
class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  AchievementsOverview? _overview;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = _client();
    if (client == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final overview = await GetIt.instance<AchievementsService>().loadOverview(
      client,
    );
    if (!mounted) return;
    setState(() {
      _overview = overview;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _AchievementsScaffold(
      title: l10n.achievementBadges,
      builder: (context) => _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final overview = _overview;
    if (overview == null) {
      return _RetryPanel(
        message: l10n.achievementsLoadFailed,
        onRetry: () {
          setState(() => _loading = true);
          _load();
        },
      );
    }

    final quests = overview.quests;
    final completion = overview.libraryCompletion;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: _listPadding,
        children: [
          if (overview.rank != null || overview.summary != null)
            _RankHeader(rank: overview.rank, summary: overview.summary),
          if (overview.equipped.isNotEmpty)
            _ShowcaseStrip(badges: overview.equipped),
          adaptiveListSection(
            children: [
              DpadListTile(
                autofocus: true,
                useSettingsIconShell: true,
                leading: const Icon(Icons.military_tech),
                trailing: const Icon(Icons.chevron_right),
                title: Text(l10n.achievementsBadges),
                subtitle: Text(
                  l10n.achievementsBadgeCount(
                    overview.badges.where((b) => b.unlocked).length,
                    overview.badges.length,
                  ),
                ),
                onTap: overview.badges.isEmpty
                    ? null
                    : () => context.pushSettingsScreen(
                        _BadgeListScreen(badges: overview.badges),
                      ),
              ),
              if (overview.questsEnabled && quests != null && !quests.isEmpty)
                DpadListTile(
                  useSettingsIconShell: true,
                  leading: const Icon(Icons.task_alt),
                trailing: const Icon(Icons.chevron_right),
                  title: Text(l10n.achievementsQuests),
                  subtitle: Text(
                    l10n.achievementsQuestCount(_questsDone(quests)),
                  ),
                  onTap: () =>
                      context.pushSettingsScreen(_QuestsScreen(quests: quests)),
                ),
              if (overview.leaderboardEnabled)
                DpadListTile(
                  useSettingsIconShell: true,
                  leading: const Icon(Icons.leaderboard),
                trailing: const Icon(Icons.chevron_right),
                  title: Text(l10n.achievementsLeaderboard),
                  subtitle: Text(l10n.achievementsLeaderboardSubtitle),
                  onTap: () => context.pushSettingsScreen(
                    _LeaderboardScreen(initial: overview.leaderboard),
                  ),
                ),
              DpadListTile(
                useSettingsIconShell: true,
                leading: const Icon(Icons.insights),
                trailing: const Icon(Icons.chevron_right),
                title: Text(l10n.achievementsRecap),
                subtitle: Text(l10n.achievementsRecapSubtitle),
                onTap: () => context.pushSettingsScreen(
                  _RecapScreen(initial: overview.recap),
                ),
              ),
              DpadListTile(
                useSettingsIconShell: true,
                leading: const Icon(Icons.backpack),
                trailing: const Icon(Icons.chevron_right),
                title: Text(l10n.achievementsLoadout),
                subtitle: Text(l10n.achievementsLoadoutSubtitle),
                onTap: () =>
                    context.pushSettingsScreen(const _LoadoutScreen()),
              ),
              if (completion.isNotEmpty)
                DpadListTile(
                  useSettingsIconShell: true,
                  leading: const Icon(Icons.collections_bookmark),
                trailing: const Icon(Icons.chevron_right),
                  title: Text(l10n.achievementsLibraryCompletion),
                  subtitle: Text(
                    l10n.achievementsLibraryCount(completion.length),
                  ),
                  onTap: () => context.pushSettingsScreen(
                    _LibraryCompletionScreen(percents: completion),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  int _questsDone(AchievementQuests quests) {
    return [...quests.daily, ...quests.weekly].where((q) => q.completed).length;
  }
}

/// A remote needs room to bring the last row clear of the overscan edge.
EdgeInsets get _listPadding =>
    EdgeInsets.only(bottom: PlatformDetection.isTV ? 96 : 24);

/// The signed-in client, or null if the session ended while the panel was open.
MediaServerClient? _client() => GetIt.instance.isRegistered<MediaServerClient>()
    ? GetIt.instance<MediaServerClient>()
    : null;

/// One shell for every screen here: the settings typography, the settings app
/// bar, and a focus scope the remote can't wander out of.
class _AchievementsScaffold extends StatefulWidget {
  const _AchievementsScaffold({required this.title, required this.builder});

  final String title;
  final WidgetBuilder builder;

  @override
  State<_AchievementsScaffold> createState() => _AchievementsScaffoldState();
}

class _AchievementsScaffoldState extends State<_AchievementsScaffold> {
  final _scope = FocusScopeNode(
    debugLabel: 'AchievementsScope',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => withCleanSettingsTypography(
    context,
    Builder(
      builder: (context) => Scaffold(
        appBar: buildSettingsAppBar(context, Text(widget.title)),
        body: FocusScope(
          node: _scope,
          autofocus: true,
          child: widget.builder(context),
        ),
      ),
    ),
  );
}

/// A row inside one of these lists.
///
/// On TV it has to be a focus stop even when it does nothing, because a list
/// whose rows can't take focus is a list the remote can't scroll. When it does
/// something, select has to be handled here as well, since d-pad centre does
/// doesn't always reach an InkWell.
class _AchievementRow extends StatefulWidget {
  const _AchievementRow({required this.builder, this.onTap});

  /// Built with whether the row is currently inverted onto a light ground.
  final Widget Function(BuildContext context, bool highlighted) builder;
  final VoidCallback? onTap;

  @override
  State<_AchievementRow> createState() => _AchievementRowState();
}

class _AchievementRowState extends State<_AchievementRow> {
  final _node = FocusNode(debugLabel: 'AchievementsRow');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final onTap = widget.onTap;
    if (onTap == null || !event.logicalKey.isSelectKey) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) onTap();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformDetection.isTV) return widget.builder(context, false);

    // The highlight watches its descendants, so the focusable node belongs
    // inside it rather than around it.
    return TvFocusHighlight(
      builder: (context, focused) => Focus(
        focusNode: _node,
        onKeyEvent: _onKey,
        child: widget.builder(
          context,
          focused && settingsTileInvertsOnFocus,
        ),
      ),
    );
  }
}

/// A tap handler for the tile inside an [_AchievementRow].
///
/// On TV the row already handles select, and a handler here would make the
/// tile a focus stop of its own, leaving the remote to step through every row
/// twice. Off TV there is no row handler, so the tile carries the tap.
VoidCallback? _tileTap(VoidCallback onTap) =>
    PlatformDetection.isTV ? null : onTap;

/// The score a user still has to spend, above whatever it can be spent on.
class _ScoreBank extends StatelessWidget {
  const _ScoreBank(this.bank);

  final int bank;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(l10n.achievementsScoreBank),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            l10n.achievementsScore(bank),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// The round tinted icon every tile in this panel leads with.
class _TileIcon extends StatelessWidget {
  const _TileIcon({
    required this.icon,
    required this.colour,
    required this.highlighted,
  });

  final IconData icon;
  final Color colour;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    backgroundColor: _tintedSurface(colour, highlighted),
    child: Icon(icon, color: colour),
  );
}

/// The plugin sends English names for its three power-ups, so the panel words
/// them itself and falls back to the raw type if a fourth ever turns up.
String _powerUpName(AppLocalizations l10n, String type) => switch (type) {
  'XpBoost' => l10n.achievementsBoost,
  'DoubleCredit' => l10n.achievementsDoubleCredit,
  'StreakFreeze' => l10n.achievementsStreakFreeze,
  _ => type,
};

String _powerUpBody(AppLocalizations l10n, String type) => switch (type) {
  'XpBoost' => l10n.achievementsBoostBody,
  'DoubleCredit' => l10n.achievementsDoubleCreditBody,
  'StreakFreeze' => l10n.achievementsStreakFreezeBody,
  _ => '',
};

/// Asks before spending something the user only gets so many of.
Future<bool> _confirmSpend(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final l10n = AppLocalizations.of(context);
  final answer = await showFocusRestoringDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(title),
      content: Text(body),
      actions: [
        adaptiveDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        adaptiveDialogAction(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.confirm),
        ),
      ],
    ),
  );
  return answer == true;
}

/// Leaves the settings panel behind and opens the item on the main navigator.
void _openItem(BuildContext context, String itemId) {
  final root = Navigator.of(context, rootNavigator: true);
  if (root.canPop()) root.pop();
  context.navigateTopLevel(Destinations.item(itemId));
}

/// The rarity tiers keep recognisable hues, because people read rarity by
/// colour before they read the word. Everything drawn from them is composited
/// against whichever ground it lands on, so the tint holds up on light, dark
/// and glass themes alike.
const _rarityCommon = Color(0xFF9AA5B1);
const _rarityUncommon = Color(0xFF4CAF50);
const _rarityRare = Color(0xFF2196F3);
const _rarityEpic = Color(0xFF9C27B0);
const _rarityLegendary = Color(0xFFFF9800);
const _rarityMythic = Color(0xFFE91E63);

/// Rarity is a free-form string on the wire, so anything unrecognized reads as
/// the commonest.
Color _rarityColor(String rarity) {
  switch (rarity.trim().toLowerCase()) {
    case 'uncommon':
      return _rarityUncommon;
    case 'rare':
      return _rarityRare;
    case 'epic':
      return _rarityEpic;
    case 'legendary':
      return _rarityLegendary;
    case 'mythic':
      return _rarityMythic;
    default:
      return _rarityCommon;
  }
}

/// A tint of [color] sitting on whichever ground the tile currently has.
Color _tintedSurface(Color color, [bool highlighted = false]) =>
    Color.alphaBlend(
      color.withValues(alpha: 0.18),
      highlighted ? AppColors.white : AppColorScheme.surface,
    );

/// The unfilled part of any progress bar here.
Color _trackColor(bool highlighted) => highlighted
    ? AppColors.black.withValues(alpha: 0.15)
    : AppColorScheme.onSurface.scaleAlpha(0.15);

/// Counts, dates and point totals, which sit a step back from the title.
Color _secondaryText(bool highlighted) => highlighted
    ? AppColors.black.withValues(alpha: 0.54)
    : AppColorScheme.onSurface.withValues(alpha: 0.7);

/// Titles and figures at full strength. Null leaves the theme's own colour.
Color? _primaryText(bool highlighted) =>
    highlighted ? AppColors.black.withValues(alpha: 0.87) : null;

/// A rarity or accent hue darkened enough to read once the tile inverts.
Color _hueOn(Color color, bool highlighted) =>
    highlighted ? Color.lerp(color, AppColors.black, 0.35)! : color;

/// The one bar shape progress is drawn with here.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.value,
    required this.color,
    this.highlighted = false,
    this.minHeight = 5,
    this.radius = 3,
  });

  final double value;
  final Color color;
  final bool highlighted;
  final double minHeight;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: LinearProgressIndicator(
        value: value,
        minHeight: minHeight,
        color: color,
        backgroundColor: _trackColor(highlighted),
      ),
    );
  }
}

Color? _parseHexColor(String value) {
  final hex = value.replaceAll('#', '').trim();
  if (hex.length != 6) return null;
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(0xFF000000 | parsed);
}

class _RetryPanel extends StatelessWidget {
  const _RetryPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              autofocus: true,
              onPressed: onRetry,
              child: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rank tier, score and the bar towards the next tier.
class _RankHeader extends StatelessWidget {
  const _RankHeader({required this.rank, required this.summary});

  final AchievementRank? rank;
  final AchievementSummary? summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rank = this.rank;
    final summary = this.summary;
    // Admins author a colour per tier, so the server's choice wins here.
    final tierColor = rank == null
        ? AppColorScheme.accent
        : _parseHexColor(rank.tier.color) ?? AppColorScheme.accent;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rank != null) ...[
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: _tintedSurface(tierColor),
                  child: Icon(
                    achievementIcon(rank.tier.icon),
                    color: tierColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rank.tier.name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(l10n.achievementsScore(rank.score)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // The header sits on the page rather than inside a tile, so it
            // never inverts and keeps the resting track.
            _ProgressBar(
              value: rank.progressToNext / 100,
              color: tierColor,
              minHeight: 8,
              radius: 4,
            ),
            const SizedBox(height: 6),
            Text(
              rank.isTopTier
                  ? l10n.achievementsTopRank
                  : l10n.achievementsPointsToNextRank(
                      (rank.nextTier!.minScore - rank.score).clamp(0, 1 << 30),
                      rank.nextTier!.name,
                    ),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (summary != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatChip(
                  icon: Icons.military_tech,
                  label: l10n.achievementsBadgeCount(
                    summary.unlocked,
                    summary.total,
                  ),
                ),
                _StatChip(
                  icon: Icons.percent,
                  label: '${summary.percentage.toStringAsFixed(1)}%',
                ),
                _StatChip(
                  icon: Icons.local_fire_department,
                  label: l10n.achievementsCurrentStreak(
                    summary.currentWatchStreak,
                  ),
                ),
                _StatChip(
                  icon: Icons.emoji_events,
                  label: l10n.achievementsBestStreak(summary.bestWatchStreak),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18, color: AppColorScheme.accent),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The badges the user pinned to their profile.
class _ShowcaseStrip extends StatelessWidget {
  const _ShowcaseStrip({required this.badges});

  final List<AchievementBadge> badges;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(l10n.achievementsShowcase),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: badges.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final badge = badges[index];
              final color = _rarityColor(badge.rarity);
              return SizedBox(
                width: 84,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: _tintedSurface(color),
                      child: Icon(achievementIcon(badge.icon), color: color),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      badge.title,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

enum _BadgeFilter { all, unlocked, locked }

/// Every badge the server returned, grouped by category.
class _BadgeListScreen extends StatefulWidget {
  const _BadgeListScreen({required this.badges});

  final List<AchievementBadge> badges;

  @override
  State<_BadgeListScreen> createState() => _BadgeListScreenState();
}

class _BadgeListScreenState extends State<_BadgeListScreen> {
  _BadgeFilter _filter = _BadgeFilter.all;

  List<AchievementBadge> get _filtered {
    switch (_filter) {
      case _BadgeFilter.unlocked:
        return widget.badges.where((b) => b.unlocked).toList();
      case _BadgeFilter.locked:
        return widget.badges.where((b) => !b.unlocked).toList();
      case _BadgeFilter.all:
        return widget.badges;
    }
  }

  String _filterLabel(AppLocalizations l10n, _BadgeFilter filter) =>
      switch (filter) {
        _BadgeFilter.all => l10n.all,
        _BadgeFilter.unlocked => l10n.achievementsUnlocked,
        _BadgeFilter.locked => l10n.achievementsLocked,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final grouped = <String, List<AchievementBadge>>{};
    for (final badge in _filtered) {
      final category = badge.category.isEmpty ? l10n.other : badge.category;
      grouped.putIfAbsent(category, () => <AchievementBadge>[]).add(badge);
    }
    final categories = grouped.keys.toList()..sort();

    return _AchievementsScaffold(
      title: l10n.achievementsBadges,
      builder: (context) => ListView(
        padding: _listPadding,
        children: [
          _TabStrip(
            labels: [
              for (final filter in _BadgeFilter.values)
                _filterLabel(l10n, filter),
            ],
            selectedIndex: _filter.index,
            onChanged: (index) =>
                setState(() => _filter = _BadgeFilter.values[index]),
          ),
          if (categories.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.achievementsNothingHere),
            )
          else
            for (final category in categories)
              _CategorySection(
                key: ValueKey(category),
                category: category,
                badges: grouped[category]!,
              ),
        ],
      ),
    );
  }
}

/// The same pill tabs search and the downloads panel use, so a filter row
/// reads the same wherever it turns up.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SlidingPillTabs(
        labels: labels,
        alignment: Alignment.center,
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onChanged: onChanged,
      ),
    );
  }
}

/// One badge category, closed until asked for.
///
/// A full library runs to hundreds of badges across a dozen categories, which
/// is more than a remote can reasonably walk, so each group stays shut until
/// someone opens it.
class _CategorySection extends StatefulWidget {
  const _CategorySection({
    super.key,
    required this.category,
    required this.badges,
  });

  final String category;
  final List<AchievementBadge> badges;

  @override
  State<_CategorySection> createState() => _CategorySectionState();
}

class _CategorySectionState extends State<_CategorySection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unlocked = widget.badges.where((b) => b.unlocked).length;

    return adaptiveListSection(
      children: [
        DpadListTile(
          useSettingsIconShell: true,
          leading: Icon(_open ? Icons.folder_open : Icons.folder),
          title: Text(widget.category),
          subtitle: Text(
            l10n.achievementsBadgeCount(unlocked, widget.badges.length),
          ),
          trailing: Icon(_open ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open)
          for (final badge in widget.badges) _BadgeTile(badge: badge),
      ],
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.badge});

  final AchievementBadge badge;

  @override
  Widget build(BuildContext context) {
    void open() =>
        context.pushSettingsScreen(_BadgeChaseScreen(badge: badge));

    return _AchievementRow(
      onTap: open,
      builder: (context, highlighted) => _tile(context, highlighted, open),
    );
  }

  Widget _tile(BuildContext context, bool highlighted, VoidCallback onTap) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = _hueOn(_rarityColor(badge.rarity), highlighted);
    final secondary = _secondaryText(highlighted);
    final unlockedAt = badge.unlockedAt;

    final subtitle = <Widget>[];
    if (badge.description.isNotEmpty && !badge.descriptionHidden) {
      subtitle.add(Text(badge.description));
    }
    if (!badge.unlocked && badge.targetValue > 0) {
      subtitle
        ..add(const SizedBox(height: 6))
        ..add(
          _ProgressBar(
            value: badge.progress,
            color: color,
            highlighted: highlighted,
          ),
        )
        ..add(const SizedBox(height: 4))
        ..add(
          Text(
            '${badge.currentValue} / ${badge.targetValue}',
            style: theme.textTheme.bodySmall?.copyWith(color: secondary),
          ),
        );
    }
    if (badge.unlocked && unlockedAt != null) {
      subtitle.add(
        Text(
          l10n.achievementsUnlockedOn(
            MaterialLocalizations.of(context).formatMediumDate(unlockedAt),
          ),
          style: theme.textTheme.bodySmall?.copyWith(color: secondary),
        ),
      );
    }

    return ListTile(
      leading: Opacity(
        opacity: badge.unlocked ? 1 : 0.4,
        child: _TileIcon(
          icon: achievementIcon(badge.icon),
          colour: color,
          highlighted: highlighted,
        ),
      ),
      title: Text(
        badge.isSecret ? l10n.achievementsHiddenBadge : badge.title,
        style: TextStyle(
          fontWeight: badge.unlocked ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: subtitle,
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            badge.rarity,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          Text(
            l10n.achievementsPoints(badge.score),
            style: theme.textTheme.bodySmall?.copyWith(color: secondary),
          ),
        ],
      ),
      isThreeLine: subtitle.length > 1,
      onTap: _tileTap(onTap),
    );
  }
}

/// One badge on its own, with what the plugin suggests watching for it.
class _BadgeChaseScreen extends StatefulWidget {
  const _BadgeChaseScreen({required this.badge});

  final AchievementBadge badge;

  @override
  State<_BadgeChaseScreen> createState() => _BadgeChaseScreenState();
}

class _BadgeChaseScreenState extends State<_BadgeChaseScreen> {
  BadgeChase? _chase;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = _client();
    if (client == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final chase = await GetIt.instance<AchievementsService>().fetchBadgeChase(
      client,
      widget.badge.id,
    );
    if (!mounted) return;
    setState(() {
      _chase = chase;
      _loading = false;
    });
  }

  String _itemSubtitle(AppLocalizations l10n, ChaseItem item) => [
    if (item.type.isNotEmpty) item.type,
    if (item.year > 0) '${item.year}',
    if (item.runtimeMinutes > 0) l10n.minutesShort(item.runtimeMinutes),
  ].join(' \u00b7 ');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final badge = widget.badge;

    return _AchievementsScaffold(
      title: badge.isSecret ? l10n.achievementsHiddenBadge : badge.title,
      builder: (context) => _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final badge = widget.badge;
    final chase = _chase;
    final current = chase?.current ?? badge.currentValue;
    final target = chase?.target ?? badge.targetValue;
    final items = chase?.items ?? const <ChaseItem>[];

    return ListView(
      padding: _listPadding,
      children: [
        if (badge.description.isNotEmpty && !badge.descriptionHidden)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(badge.description),
          ),
        SettingsSectionHeader(l10n.achievementsProgressLabel),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$current / $target',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              _ProgressBar(
                value: badge.progress,
                color: _rarityColor(badge.rarity),
                minHeight: 8,
                radius: 4,
              ),
            ],
          ),
        ),
        SettingsSectionHeader(l10n.achievementsSuggested),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.achievementsNoSuggestions),
          )
        else
          adaptiveListSection(
            children: [
              for (final item in items)
                _AchievementRow(
                  onTap: () => _openItem(context, item.id),
                  builder: (context, _) => ListTile(
                    title: Text(item.name),
                    subtitle: Text(_itemSubtitle(l10n, item)),
                    onTap: _tileTap(() => _openItem(context, item.id)),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// The score bank and the consumables it has bought.
class _LoadoutScreen extends StatefulWidget {
  const _LoadoutScreen();

  @override
  State<_LoadoutScreen> createState() => _LoadoutScreenState();
}

class _LoadoutScreenState extends State<_LoadoutScreen> {
  PowerUpState? _state;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = _client();
    if (client == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final state = await GetIt.instance<AchievementsService>().fetchPowerUps(
      client,
    );
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
    });
  }

  Future<void> _use(AppLocalizations l10n, PowerUpSlot slot) async {
    final client = _client();
    if (client == null || _busy) return;

    final go = await _confirmSpend(
      context,
      title: l10n.achievementsUsePowerUp,
      body: l10n.achievementsUsePowerUpBody,
    );
    if (!go || !mounted) return;

    setState(() => _busy = true);
    final result = await GetIt.instance<AchievementsService>().usePowerUp(
      client,
      slot.type,
    );
    if (!mounted) return;

    final current = _state;
    setState(() {
      _busy = false;
      if (result.outcome == PowerUpUseOutcome.used && current != null) {
        // Spending one costs no score, so only the inventory moves.
        _state = PowerUpState(bank: current.bank, slots: result.slots);
      }
    });

    if (result.outcome == PowerUpUseOutcome.used) return;
    final text = result.message ?? l10n.achievementsPowerUpFailed;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _AchievementsScaffold(
      title: l10n.achievementsLoadout,
      builder: (context) => _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final state = _state;
    if (state == null) {
      return _RetryPanel(
        message: l10n.achievementsLoadFailed,
        onRetry: () {
          setState(() => _loading = true);
          _load();
        },
      );
    }

    return ListView(
      padding: _listPadding,
      children: [
        _ScoreBank(state.bank),
        SettingsSectionHeader(l10n.achievementsPowerUps),
        adaptiveListSection(
          children: [
            for (final slot in state.slots)
              _PowerUpTile(
                name: _powerUpName(l10n, slot.type),
                body: _powerUpBody(l10n, slot.type),
                slot: slot,
                onUse: slot.count > 0 && !_busy
                    ? () => _use(l10n, slot)
                    : null,
              ),
            DpadListTile(
              useSettingsIconShell: true,
              leading: const Icon(Icons.storefront),
              trailing: const Icon(Icons.chevron_right),
              title: Text(l10n.achievementsShop),
              subtitle: Text(l10n.achievementsShopSubtitle),
              // Reloading on the way back, since a purchase changes both the
              // bank and the stock this screen is showing.
              onTap: () async {
                await context.pushSettingsScreen(const _ShopScreen());
                if (mounted) _load();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// What score can be spent on.
class _ShopScreen extends StatefulWidget {
  const _ShopScreen();

  @override
  State<_ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<_ShopScreen> {
  List<ShopPowerUp> _items = const [];
  int _bank = 0;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = _client();
    if (client == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final service = GetIt.instance<AchievementsService>();
    // The catalogue carries no bank, so the two are read together.
    final results = await Future.wait([
      service.fetchShopPowerUps(client),
      service.fetchPowerUps(client),
    ]);
    if (!mounted) return;
    setState(() {
      _items = results[0] as List<ShopPowerUp>;
      _bank = (results[1] as PowerUpState?)?.bank ?? 0;
      _loading = false;
    });
  }

  Future<void> _buy(AppLocalizations l10n, ShopPowerUp item) async {
    final client = _client();
    if (client == null || _busy) return;

    final go = await _confirmSpend(
      context,
      title: l10n.achievementsBuyConfirm,
      body: l10n.achievementsBuyConfirmBody,
    );
    if (!go || !mounted) return;

    setState(() => _busy = true);
    final result = await GetIt.instance<AchievementsService>().buy(
      client,
      item.id,
    );
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (result.outcome == PurchaseOutcome.bought) {
        _bank = result.bankAfter ?? _bank;
      }
    });

    if (result.outcome == PurchaseOutcome.bought) return;
    final text = result.message ?? l10n.achievementsBuyFailed;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _AchievementsScaffold(
      title: l10n.achievementsShop,
      builder: (context) => _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    return ListView(
      padding: _listPadding,
      children: [
        _ScoreBank(_bank),
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.achievementsShopEmpty),
          )
        else
          adaptiveListSection(
            children: [
              for (final item in _items)
                _ShopTile(
                  item: item,
                  affordable: item.priceScore <= _bank && !_busy,
                  onBuy: () => _buy(l10n, item),
                ),
            ],
          ),
      ],
    );
  }
}

class _ShopTile extends StatelessWidget {
  const _ShopTile({
    required this.item,
    required this.affordable,
    required this.onBuy,
  });

  final ShopPowerUp item;
  final bool affordable;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) => _AchievementRow(
    onTap: affordable ? onBuy : null,
    builder: (context, highlighted) => _tile(context, highlighted),
  );

  Widget _tile(BuildContext context, bool highlighted) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final accent = _hueOn(AppColorScheme.accent, highlighted);
    final name = _powerUpName(l10n, item.type);

    return ListTile(
      leading: _TileIcon(
        icon: Icons.storefront,
        colour: accent,
        highlighted: highlighted,
      ),
      title: Text(
        item.bundleSize > 1
            ? l10n.achievementsShopPack(name, item.bundleSize)
            : name,
      ),
      subtitle: Text(_powerUpBody(l10n, item.type)),
      trailing: Text(
        l10n.achievementsScore(item.priceScore),
        style: theme.textTheme.bodySmall?.copyWith(
          color: affordable ? accent : _secondaryText(highlighted),
        ),
      ),
      isThreeLine: true,
      onTap: affordable ? _tileTap(onBuy) : null,
    );
  }
}

class _PowerUpTile extends StatelessWidget {
  const _PowerUpTile({
    required this.name,
    required this.body,
    required this.slot,
    required this.onUse,
  });

  final String name;
  final String body;
  final PowerUpSlot slot;
  final VoidCallback? onUse;

  @override
  Widget build(BuildContext context) => _AchievementRow(
    onTap: onUse,
    builder: (context, highlighted) => _tile(context, highlighted),
  );

  Widget _tile(BuildContext context, bool highlighted) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final accent = _hueOn(AppColorScheme.accent, highlighted);
    final held = l10n.achievementsPowerUpHeld(slot.count);

    // Deliberately not marked disabled. The row still takes focus so it can be
    // read on a remote, and a disabled tile greys its title past legibility
    // once the highlight inverts. Having none is said in the subtitle instead.
    return ListTile(
      leading: _TileIcon(
        icon: achievementIcon(slot.icon),
        colour: accent,
        highlighted: highlighted,
      ),
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (body.isNotEmpty) Text(body),
          const SizedBox(height: 4),
          Text(
            slot.active
                ? '$held \u00b7 ${l10n.achievementsPowerUpActive}'
                : held,
            style: theme.textTheme.bodySmall?.copyWith(
              color: slot.active ? accent : _secondaryText(highlighted),
            ),
          ),
        ],
      ),
      isThreeLine: true,
      onTap: onUse == null ? null : _tileTap(onUse!),
    );
  }
}

class _QuestsScreen extends StatefulWidget {
  const _QuestsScreen({required this.quests});

  final AchievementQuests quests;

  @override
  State<_QuestsScreen> createState() => _QuestsScreenState();
}

class _QuestsScreenState extends State<_QuestsScreen> {
  late AchievementQuests _quests = widget.quests;
  bool _rerolling = false;

  Future<void> _reroll(AppLocalizations l10n, {required bool weekly}) async {
    final client = _client();
    if (client == null || _rerolling) return;
    final go = await _confirmSpend(
      context,
      title: l10n.achievementsRerollConfirm,
      body: l10n.achievementsRerollConfirmBody,
    );
    if (!go) return;
    if (!mounted) return;

    setState(() => _rerolling = true);
    final result = await GetIt.instance<AchievementsService>().rerollQuests(
      client,
      weekly: weekly,
    );
    if (!mounted) return;

    setState(() {
      _rerolling = false;
      switch (result.outcome) {
        case QuestRerollOutcome.rerolled:
          _quests = weekly
              ? _quests.copyWith(
                  weekly: result.quests,
                  weeklyRerollsLeft: result.rerollsLeft,
                )
              : _quests.copyWith(
                  daily: result.quests,
                  dailyRerollsLeft: result.rerollsLeft,
                );
        case QuestRerollOutcome.alreadyUsed:
          // The server is the authority on this, so take its word and let the
          // row settle into its spent state.
          _quests = weekly
              ? _quests.copyWith(weeklyRerollsLeft: 0)
              : _quests.copyWith(dailyRerollsLeft: 0);
        case QuestRerollOutcome.failed:
          break;
      }
    });

    if (result.outcome == QuestRerollOutcome.failed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.achievementsRerollFailed)));
    }
  }

  Widget _rerollRow(AppLocalizations l10n, {required bool weekly}) {
    final left = weekly ? _quests.weeklyRerollsLeft : _quests.dailyRerollsLeft;
    final spent = weekly
        ? l10n.achievementsRerollSpentWeekly
        : l10n.achievementsRerollSpentDaily;

    // Withholding the tap rather than marking the tile disabled, which would
    // grey the wording about when the reroll comes back past reading.
    return DpadListTile(
      useSettingsIconShell: true,
      leading: const Icon(Icons.casino),
      title: Text(
        weekly ? l10n.achievementsRerollWeekly : l10n.achievementsRerollDaily,
      ),
      subtitle: Text(left > 0 ? l10n.achievementsRerollOffer : spent),
      onTap: left > 0 && !_rerolling
          ? () => _reroll(l10n, weekly: weekly)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return _AchievementsScaffold(
      title: l10n.achievementsQuests,
      builder: (context) => ListView(
        padding: _listPadding,
        children: [
          if (_quests.daily.isNotEmpty) ...[
            SettingsSectionHeader(l10n.achievementsDailyQuests),
            adaptiveListSection(
              children: [
                for (final quest in _quests.daily) _QuestTile(quest: quest),
                _rerollRow(l10n, weekly: false),
              ],
            ),
          ],
          if (_quests.weekly.isNotEmpty) ...[
            SettingsSectionHeader(l10n.achievementsWeeklyQuests),
            adaptiveListSection(
              children: [
                for (final quest in _quests.weekly) _QuestTile(quest: quest),
                _rerollRow(l10n, weekly: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QuestTile extends StatelessWidget {
  const _QuestTile({required this.quest});

  final AchievementQuest quest;

  @override
  Widget build(BuildContext context) =>
      _AchievementRow(
        builder: (context, highlighted) => _tile(context, highlighted),
      );

  Widget _tile(BuildContext context, bool highlighted) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = _hueOn(AppColorScheme.accent, highlighted);

    return ListTile(
      leading: _TileIcon(
        icon: quest.completed ? Icons.check : achievementIcon(quest.icon),
        colour: color,
        highlighted: highlighted,
      ),
      title: Text(quest.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (quest.description.isNotEmpty) Text(quest.description),
          const SizedBox(height: 6),
          _ProgressBar(
            value: quest.progress,
            color: color,
            highlighted: highlighted,
          ),
          const SizedBox(height: 4),
          Text(
            '${quest.current} / ${quest.target}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _secondaryText(highlighted),
            ),
          ),
        ],
      ),
      trailing: Text(l10n.achievementsQuestReward(quest.reward)),
      isThreeLine: true,
    );
  }
}

class _LeaderboardScreen extends StatefulWidget {
  const _LeaderboardScreen({required this.initial});

  final List<LeaderboardEntry> initial;

  @override
  State<_LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<_LeaderboardScreen> {
  /// An empty entry is the overall score board. The rest are the category
  /// names the plugin recognizes.
  static const _categories = <String>[
    '',
    'movies',
    'episodes',
    'hours',
    'streak',
    'series',
    'unlocked',
  ];

  late List<LeaderboardEntry> _entries = widget.initial;
  String _category = '';
  bool _loading = false;

  Future<void> _select(String category) async {
    final client = _client();
    if (client == null) return;

    setState(() {
      _category = category;
      _loading = true;
    });

    final entries = await GetIt.instance<AchievementsService>()
        .fetchLeaderboard(client, category: category);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String _label(AppLocalizations l10n, String category) {
    switch (category) {
      case 'movies':
        return l10n.movies;
      case 'episodes':
        return l10n.episodes;
      case 'hours':
        return l10n.achievementsHours;
      case 'streak':
        return l10n.achievementsStreak;
      case 'series':
        return l10n.series;
      case 'unlocked':
        return l10n.achievementsBadges;
      default:
        return l10n.achievementsScoreLabel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return _AchievementsScaffold(
      title: l10n.achievementsLeaderboard,
      builder: (context) => ListView(
        padding: _listPadding,
        children: [
          _TabStrip(
            labels: [for (final category in _categories) _label(l10n, category)],
            selectedIndex: _categories.indexOf(_category),
            onChanged: (index) {
              if (!_loading) _select(_categories[index]);
            },
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.achievementsNothingHere),
            )
          else
            adaptiveListSection(
              children: [
                for (var i = 0; i < _entries.length; i++)
                  _LeaderboardTile(position: i + 1, entry: _entries[i]),
              ],
            ),
        ],
      ),
    );
  }
}

class _LeaderboardTile extends StatelessWidget {
  const _LeaderboardTile({required this.position, required this.entry});

  final int position;
  final LeaderboardEntry entry;

  @override
  Widget build(BuildContext context) =>
      _AchievementRow(
        builder: (context, highlighted) => _tile(context, highlighted),
      );

  Widget _tile(BuildContext context, bool highlighted) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // A category board carries a single value and the overall board a score.
    final value = entry.value ?? entry.score ?? 0;
    final unlocked = entry.unlocked;
    final subtitle =
        entry.customTitle ??
        (unlocked == null
            ? null
            : l10n.achievementsBadgeCount(unlocked, entry.total ?? 0));

    return ListTile(
      leading: SizedBox(
        width: 32,
        child: Center(
          child: Text(
            '$position',
            style: theme.textTheme.titleMedium?.copyWith(
              color: _primaryText(highlighted),
            ),
          ),
        ),
      ),
      title: Text(entry.userName),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Text(
        '$value',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: _primaryText(highlighted),
        ),
      ),
    );
  }
}

class _RecapScreen extends StatefulWidget {
  const _RecapScreen({required this.initial});

  final AchievementRecap? initial;

  @override
  State<_RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<_RecapScreen> {
  static const _periods = <String>['week', 'month', 'year'];

  late AchievementRecap? _recap = widget.initial;
  String _period = 'month';
  bool _loading = false;

  Future<void> _select(String period) async {
    final client = _client();
    if (client == null) return;

    setState(() {
      _period = period;
      _loading = true;
    });

    final recap = await GetIt.instance<AchievementsService>().fetchRecap(
      client,
      period,
    );
    if (!mounted) return;
    setState(() {
      _recap = recap;
      _loading = false;
    });
  }

  String _label(AppLocalizations l10n, String period) {
    switch (period) {
      case 'week':
        return l10n.achievementsPeriodWeek;
      case 'year':
        return l10n.achievementsPeriodYear;
      default:
        return l10n.achievementsPeriodMonth;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final recap = _recap;

    return _AchievementsScaffold(
      title: l10n.achievementsRecap,
      builder: (context) => ListView(
        padding: _listPadding,
        children: [
          _TabStrip(
            labels: [for (final period in _periods) _label(l10n, period)],
            selectedIndex: _periods.indexOf(_period),
            onChanged: (index) {
              if (!_loading) _select(_periods[index]);
            },
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (recap == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.achievementsNothingHere),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatChip(
                    icon: Icons.movie,
                    label: '${recap.moviesWatched} ${l10n.movies}',
                  ),
                  _StatChip(
                    icon: Icons.live_tv,
                    label: '${recap.episodesWatched} ${l10n.episodes}',
                  ),
                  _StatChip(
                    icon: Icons.calendar_month,
                    label: l10n.achievementsDaysWatched(recap.daysWatched),
                  ),
                  _StatChip(
                    icon: Icons.military_tech,
                    label: l10n.achievementsBadgesEarned(recap.badgesUnlocked),
                  ),
                ],
              ),
            ),
            if (recap.topGenres.isNotEmpty)
              _CountList(title: l10n.genres, counts: recap.topGenres),
            if (recap.topDirectors.isNotEmpty)
              _CountList(
                title: l10n.achievementsTopDirectors,
                counts: recap.topDirectors,
              ),
            if (recap.topActors.isNotEmpty)
              _CountList(
                title: l10n.achievementsTopActors,
                counts: recap.topActors,
              ),
          ],
        ],
      ),
    );
  }
}

class _CountList extends StatelessWidget {
  const _CountList({required this.title, required this.counts});

  final String title;
  final List<RecapCount> counts;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title),
        adaptiveListSection(
          children: [
            for (final count in counts)
              _AchievementRow(
                builder: (context, _) => ListTile(
                  dense: true,
                  title: Text(count.name),
                  trailing: Text('${count.count}'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _LibraryCompletionScreen extends StatelessWidget {
  const _LibraryCompletionScreen({required this.percents});

  final Map<String, int> percents;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final names = percents.keys.toList()..sort();

    return _AchievementsScaffold(
      title: l10n.achievementsLibraryCompletion,
      builder: (context) => ListView(
        padding: _listPadding,
        children: [
          adaptiveListSection(
            children: [
              for (final name in names)
                _AchievementRow(
                  builder: (context, highlighted) => ListTile(
                    title: Text(name),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _ProgressBar(
                        value: (percents[name]! / 100).clamp(0.0, 1.0),
                        color: _hueOn(AppColorScheme.accent, highlighted),
                        highlighted: highlighted,
                      ),
                    ),
                    trailing: Text(
                      '${percents[name]}%',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: _primaryText(highlighted),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
