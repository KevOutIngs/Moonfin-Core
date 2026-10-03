import '../../util/season_queue_context.dart';
import '../models/aggregated_item.dart';
import 'auto_download_planner.dart';

/// Decides what smart downloads should swap in one series: every downloaded
/// episode watched since it was downloaded is deleted, and the episodes
/// after it are queued in its place.
///
/// Pure, like [planAutoDownload]: the caller snapshots the server's
/// episodes, the downloads database and the queue.
///
/// - [downloadedAt] maps each completed download of the series to when it
///   finished. Only an episode the server says was played after that is
///   swapped, so a download of something already watched, kept to rewatch,
///   stays.
/// - The series' final episode is never deleted, and the one in
///   [playingItemId] waits for the next check: servers flip Played near the
///   end of playback, while the file is open. Specials are left alone.
/// - Each swapped episode is replaced one for one by the next unwatched
///   episodes after the furthest one watched, and the series is topped up
///   to [keepReady] unwatched episodes downloaded or in flight after it.
/// - Nothing is planned until a downloaded episode has been watched, so
///   downloading a series by hand never starts a swap on its own.
AutoDownloadPlan planSmartDownload({
  required List<AggregatedItem> episodes,
  required Map<String, DateTime?> downloadedAt,
  required Set<String> inFlightIds,
  required int keepReady,
  required int? storageBudgetBytes,
  required int Function(AggregatedItem episode) sizeOf,
  String? playingItemId,
}) {
  final ordered = [
    for (final episode in episodes)
      if (!isSpecialEpisode(episode)) episode,
  ]..sort(airedOrder);
  final aired = ordered.where(isDownloadableEpisode);
  final finale = aired.isEmpty ? null : aired.last;

  final watched = [
    for (final episode in ordered)
      if (downloadedAt.containsKey(episode.id) &&
          episode.id != playingItemId &&
          episode.id != finale?.id &&
          watchedSinceDownload(episode, downloadedAt[episode.id]))
        episode,
  ];
  if (watched.isEmpty) return const AutoDownloadPlan();

  final after = ordered.sublist(ordered.indexOf(watched.last) + 1);
  var held = 0;
  final queueable = <AggregatedItem>[];
  for (final episode in after) {
    if (episode.isPlayed) continue;
    if (downloadedAt.containsKey(episode.id) ||
        inFlightIds.contains(episode.id)) {
      held++;
    } else if (isDownloadableEpisode(episode)) {
      queueable.add(episode);
    }
  }

  final wanted = watched.length > keepReady - held
      ? watched.length
      : keepReady - held;
  // The swapped episodes are deleted before anything is queued, so their
  // space counts toward the budget.
  final budget = storageBudgetBytes == null
      ? null
      : storageBudgetBytes + watched.fold<int>(0, (sum, e) => sum + sizeOf(e));
  final (toQueue, blocked) = fitStorageBudget(
    queueable.take(wanted.clamp(0, queueable.length)).toList(),
    budgetBytes: budget,
    sizeOf: sizeOf,
  );

  return AutoDownloadPlan(
    toQueue: toQueue,
    toDelete: watched,
    blocked: blocked,
  );
}

/// Played, and last played after the download finished. Without either
/// date there is no telling a fresh watch from a rewatch, so it stays.
bool watchedSinceDownload(AggregatedItem episode, DateTime? downloadedAt) {
  final playedAt = episode.lastPlayedDate;
  return episode.isPlayed &&
      playedAt != null &&
      downloadedAt != null &&
      playedAt.isAfter(downloadedAt);
}
