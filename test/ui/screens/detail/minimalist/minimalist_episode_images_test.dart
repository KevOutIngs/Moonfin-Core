import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/ui/screens/detail/detail_episode_images.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_core/server_core.dart';

class _ImageApi extends Mock implements ImageApi {}

AggregatedItem _episode(Map<String, dynamic> extra) => AggregatedItem(
  id: 'ep-1',
  serverId: 'srv1',
  rawData: {
    'Id': 'ep-1',
    'Name': 'An episode',
    'Type': 'Episode',
    ...extra,
  },
);

void main() {
  late _ImageApi imageApi;

  setUp(() {
    imageApi = _ImageApi();
    when(
      () => imageApi.getThumbImageUrl(
        any(),
        maxWidth: any(named: 'maxWidth'),
        tag: any(named: 'tag'),
      ),
    ).thenAnswer((i) => 'thumb:${i.positionalArguments.first}');
    when(
      () => imageApi.getPrimaryImageUrl(
        any(),
        maxWidth: any(named: 'maxWidth'),
        tag: any(named: 'tag'),
      ),
    ).thenAnswer((i) => 'primary:${i.positionalArguments.first}');
  });

  test('a special with no still of its own falls back to the series thumb', () {
    // The real case: episodes outside a numbered season often carry no
    // PrimaryImageTag at all, so without this the card comes up blank.
    final special = _episode({
      'SeriesId': 'series-1',
      'SeriesThumbImageTag': 'abc',
    });

    expect(
      resolveSeriesLandscapeThumbnailUrl(special, imageApi, maxWidth: 400),
      'thumb:series-1',
    );
  });

  test('the parent thumb wins over the series one when both are there', () {
    final episode = _episode({
      'ParentThumbItemId': 'season-1',
      'ParentThumbImageTag': 'def',
      'SeriesId': 'series-1',
      'SeriesThumbImageTag': 'abc',
    });

    expect(
      resolveSeriesLandscapeThumbnailUrl(episode, imageApi, maxWidth: 400),
      'thumb:season-1',
    );
  });

  test('with no thumb anywhere it tries the series poster', () {
    final episode = _episode({
      'SeriesId': 'series-1',
      'SeriesPrimaryImageTag': 'ghi',
    });

    expect(
      resolveSeriesLandscapeThumbnailUrl(episode, imageApi, maxWidth: 400),
      'primary:series-1',
    );
  });

  test('an episode naming nothing resolves to nothing', () {
    expect(
      resolveSeriesLandscapeThumbnailUrl(_episode({}), imageApi, maxWidth: 400),
      isNull,
    );
  });

  test('the width asked for follows the height the card reserves', () {
    expect(landscapeWidthFor(90), 160);
    expect(landscapeWidthFor(150), 267);
  });
}
