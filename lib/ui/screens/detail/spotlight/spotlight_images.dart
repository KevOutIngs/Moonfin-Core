import 'package:server_core/server_core.dart';

import '../../../../data/models/aggregated_item.dart';
import '../../../widgets/seerr/seerr_image_urls.dart';

/// The poster or primary image for [item], with the TMDB fallbacks a
/// Seerr-only item needs.
String? spotlightItemImageUrl(ImageApi imageApi, AggregatedItem item) {
  final tag = item.primaryImageTag;
  if (tag != null && !item.id.startsWith('tmdb:')) {
    return imageApi.getPrimaryImageUrl(item.id, maxHeight: 360, tag: tag);
  }
  return spotlightSeerrPosterUrl(item.rawData['PosterPath'] as String?) ??
      spotlightPersonImageUrl(
        imageApi,
        profilePath: item.rawData['ProfilePath'] as String?,
        maxHeight: 360,
        tmdbProfileBase: seerrProfileLargeBase,
      );
}

/// A person's portrait: the server image when [id] and [tag] name a library
/// person, else the TMDB profile at [tmdbProfileBase], else null.
String? spotlightPersonImageUrl(
  ImageApi imageApi, {
  String? id,
  String? tag,
  String? profilePath,
  required int maxHeight,
  String tmdbProfileBase = seerrProfileBase,
}) {
  if (id != null && tag != null && !id.startsWith('tmdb:')) {
    return imageApi.getPrimaryImageUrl(id, maxHeight: maxHeight, tag: tag);
  }
  if (profilePath != null && profilePath.isNotEmpty) {
    return '$tmdbProfileBase$profilePath';
  }
  return null;
}

/// A Seerr poster path as a TMDB URL, or null when Seerr sent none.
String? spotlightSeerrPosterUrl(String? posterPath) =>
    posterPath == null || posterPath.isEmpty
    ? null
    : '$seerrPosterBase$posterPath';
