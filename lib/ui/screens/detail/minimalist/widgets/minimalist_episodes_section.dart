import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin/util/season_queue_context.dart';

import '../../../../../data/models/aggregated_item.dart';
import '../../../../../data/viewmodels/item_detail_view_model.dart';
import '../../../../../l10n/app_localizations.dart';
import '../../../../../preference/user_preferences.dart';
import '../../../../navigation/destinations.dart';
import '../../../../widgets/focus/context_menu_sheet.dart';
import '../../../../widgets/focus/locked_focus_row.dart';
import '../../../../widgets/sliding_pill_tabs.dart';
import '../../detail_episode_images.dart';
import 'minimalist_episode_card.dart';

/// Season tabs over a rail of episodes, and nothing else.
///
/// The flow is one way on purpose: a tab picks the season and the rail follows.
class MinimalistEpisodesSection extends StatefulWidget {
  final ItemDetailViewModel viewModel;
  final UserPreferences prefs;
  final double cardWidth;

  /// Whatever sits at the top of this section, which is the season tabs when
  /// there are seasons to choose between and the episode rail when there are
  /// not. Coming down from the play button aims at this, so it has to belong
  /// to a widget that's actually on screen.
  final FocusNode? episodesFocusNode;

  /// Up out of the section, usually back to the play button.
  final bool Function(bool isUp)? onVerticalNavigation;

  const MinimalistEpisodesSection({
    super.key,
    required this.viewModel,
    required this.prefs,
    required this.cardWidth,
    this.episodesFocusNode,
    this.onVerticalNavigation,
  });

  @override
  State<MinimalistEpisodesSection> createState() =>
      _MinimalistEpisodesSectionState();
}

class _MinimalistEpisodesSectionState extends State<MinimalistEpisodesSection> {
  final _railKey = GlobalKey<LockedFocusRowState<AggregatedItem>>();
  final _railController = ScrollController();
  int? _selectedSeason;
  bool _loadStarted = false;

  ItemDetailViewModel get _vm => widget.viewModel;
  bool get _isSeries => _vm.item?.type == 'Series';
  bool get _isSeason => _vm.item?.type == 'Season';
  bool get _isEpisode => _vm.item?.type == 'Episode';

  @override
  void initState() {
    super.initState();
    _beginEpisodesLoad();
  }

  @override
  void dispose() {
    _railController.dispose();
    super.dispose();
  }

  /// A Season already carries its own episodes. A Series, or one episode of
  /// one, has to ask for every season's worth, once, so the tabs can filter a
  /// list that's already here.
  void _beginEpisodesLoad() {
    if (_loadStarted || !(_isSeries || _isEpisode)) return;
    _loadStarted = true;
    final viewModel = _vm;
    if (viewModel.seriesEpisodes.isNotEmpty) return;
    unawaited(
      viewModel.loadAllSeriesEpisodes().whenComplete(() {
        if (!mounted || !identical(_vm, viewModel)) return;
        setState(() {});
      }),
    );
  }

  List<AggregatedItem> get _allEpisodes =>
      _isSeason ? _vm.episodes : _vm.seriesEpisodes;

  List<int> _seasonNumbers(List<AggregatedItem> episodes) => episodes
      .map((episode) => episode.parentIndexNumber)
      .whereType<int>()
      .toSet()
      .toList()
    ..sort();

  String _seasonLabel(AppLocalizations l10n, int number) =>
      number == 0 ? l10n.specials : l10n.seasonNumber(number);

  void _selectSeason(int number) {
    if (_selectedSeason == number) return;
    setState(() => _selectedSeason = number);
    // Back to the start of the rail, but the tabs keep focus. Left and right
    // change the season as you pass over it, so pulling focus down here would
    // strand you on the first season you touched.
    if (_railController.hasClients) _railController.jumpTo(0);
  }

  void _showEpisodeMenu(BuildContext context, AggregatedItem episode) {
    showContextMenu(context, episode, onChanged: () => setState(() {}));
  }

  void _openEpisode(BuildContext context, AggregatedItem episode) {
    context.push(
      Destinations.item(
        episode.id,
        serverId: episode.serverId,
        seasonContext: seasonContextParam(
          contextSeasonId: _isSeason ? _vm.item?.id : null,
          episodeSeasonId: episode.seasonId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final all = _allEpisodes;
    if (all.isEmpty) return const SizedBox.shrink();

    final seasons = _seasonNumbers(all);
    // Landing on an episode opens its own season rather than the first one.
    final arrivedIn = _isEpisode ? _vm.item?.parentIndexNumber : null;
    final fallback = arrivedIn != null && seasons.contains(arrivedIn)
        ? arrivedIn
        : (seasons.isEmpty ? null : seasons.first);
    final selected = _selectedSeason != null && seasons.contains(_selectedSeason)
        ? _selectedSeason!
        : fallback;

    final episodes = selected == null
        ? all
        : all.where((e) => e.parentIndexNumber == selected).toList();

    final cardWidth = widget.cardWidth;
    final railHeight = cardWidth * 9 / 16 + 62;
    // One season is no choice at all, so the strip only earns its space when
    // there's somewhere else to go, and the rail takes over as the way in.
    final showTabs = seasons.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTabs) ...[
          SlidingPillTabs(
            key: const ValueKey('minimalist-season-tabs'),
            labels: [for (final n in seasons) _seasonLabel(l10n, n)],
            selectedIndex: selected == null ? 0 : seasons.indexOf(selected),
            onChanged: (index) => _selectSeason(seasons[index]),
            focusNode: widget.episodesFocusNode,
            onVerticalNavigation: (isUp) {
              if (!isUp) {
                _railKey.currentState?.requestFocusAt(0);
                return true;
              }
              return widget.onVerticalNavigation?.call(true) ?? false;
            },
          ),
          const SizedBox(height: 18),
        ],
        SizedBox(
          key: const ValueKey('minimalist-episode-rail'),
          height: railHeight,
          child: LockedFocusRow<AggregatedItem>(
            key: _railKey,
            items: episodes,
            hubKey: 'minimalist-episodes-${_vm.item?.id ?? ''}-$selected',
            itemExtent: cardWidth,
            itemSpacing: 20,
            height: railHeight,
            controller: _railController,
            focusNode: showTabs ? null : widget.episodesFocusNode,
            clipBehavior: Clip.none,
            // The row handles the remote's select and hold. The card below
            // handles the pointer, so both have to agree.
            onTap: (_, episode) => _openEpisode(context, episode),
            onLongPress: (_, episode) => _showEpisodeMenu(context, episode),
            onVerticalNavigation: (isUp) {
              if (isUp && showTabs) {
                widget.episodesFocusNode?.requestFocus();
                return true;
              }
              return widget.onVerticalNavigation?.call(isUp) ?? false;
            },
            itemBuilder: (context, episode, index, isFocused) {
              return MinimalistEpisodeCard(
                episode: episode,
                width: cardWidth,
                isFocused: isFocused,
                imageUrl: minimalistEpisodeImageUrl(
                  episode,
                  _vm,
                  prefs: widget.prefs,
                  cardWidth: cardWidth,
                ),
                onTap: () => _openEpisode(context, episode),
                onLongPress: () => _showEpisodeMenu(context, episode),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The picture for one episode card.
///
/// Specials are the case worth knowing about: an episode outside a numbered
/// season often has no still of its own, so the series thumb is all there is.
String? minimalistEpisodeImageUrl(
  AggregatedItem episode,
  ItemDetailViewModel viewModel, {
  required UserPreferences prefs,
  required double cardWidth,
}) {
  final imageApi = viewModel.imageApi;
  final maxWidth = (cardWidth * 2).round();

  if (prefs.effectiveDetailUseSeriesThumbnails) {
    final series = resolveSeriesLandscapeThumbnailUrl(
      episode,
      imageApi,
      maxWidth: maxWidth,
    );
    if (series != null) return series;
  }

  final ownTag = episode.primaryImageTag;
  if (ownTag != null && ownTag.isNotEmpty) {
    return imageApi.getPrimaryImageUrl(
      episode.id,
      maxWidth: maxWidth,
      tag: ownTag,
    );
  }

  return resolveSeriesLandscapeThumbnailUrl(
    episode,
    imageApi,
    maxWidth: maxWidth,
  );
}
