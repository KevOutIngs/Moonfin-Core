import '../../util/season_queue_context.dart';
import '../models/aggregated_item.dart';
import 'auto_download_planner.dart';

/// Decides what smart downloads should do in one series: keep the episodes
/// after the furthest one watched downloaded, and delete downloaded episodes
/// once they are watched.
///
/// Pure, like [planAutoDownload]: the caller snapshots the server's
/// episodes, the downloads database and the queue.
///
/// - [finishedRecently] says an episode of the series, streamed or
///   downloaded, was finished since the last check. That is what starts a
///   top-up; nothing is queued for a series nobody is watching.
/// - [downloadedAt] maps each completed download of the series to when it
///   finished. A download is swapped out once the server says it was played
///   after that and after [since] (when smart downloads was turned on), so a
///   download of something already watched, kept to rewatch, stays.
/// - The series' final episode is never deleted, and the one in
///   [playingItemId] waits for the next check: servers flip Played near the
///   end of playback, while the file is open. Specials are left alone.
/// - The series is topped up to [keepReady] unwatched episodes downloaded or
///   in flight after the furthest episode watched, and each swapped download
///   is replaced at least one for one.
AutoDownloadPlan planSmartDownload({
  required List<AggregatedItem> episodes,
  required Map<String, DateTime?> downloadedAt,
  required Set<String> inFlightIds,
  required int keepReady,
  required int? storageBudgetBytes,
  required int Function(AggregatedItem episode) sizeOf,
  required DateTime since,
  bool finishedRecently = false,
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
          watchedSinceDownload(episode, downloadedAt[episode.id], since))
        episode,
  ];
  final furthest = ordered.lastIndexWhere((e) => e.isPlayed);
  if (furthest < 0 || (watched.isEmpty && !finishedRecently)) {
    return AutoDownloadPlan(toDelete: watched);
  }

  var held = 0;
  final queueable = <AggregatedItem>[];
  for (final episode in ordered.skip(furthest + 1)) {
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

/// Played, and last played after the download finished and after [since].
/// Without either date there is no telling a fresh watch from a rewatch, so
/// it stays.
bool watchedSinceDownload(
  AggregatedItem episode,
  DateTime? downloadedAt,
  DateTime since,
) {
  final playedAt = episode.lastPlayedDate;
  return episode.isPlayed &&
      playedAt != null &&
      downloadedAt != null &&
      playedAt.isAfter(downloadedAt) &&
      playedAt.isAfter(since);
}
