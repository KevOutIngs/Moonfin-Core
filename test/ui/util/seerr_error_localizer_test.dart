import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/ui/util/seerr_error_localizer.dart';

final _l10n = AppLocalizationsEn();

// Spelled out so the test fails if the wording changes, which comparing
// against the l10n getters wouldn't catch.
const _failedToLoad = 'Failed to load';
const _unableToConnect = 'Unable to connect to server';

void main() {
  group('localizeSeerrError', () {
    test('hides the raw exception behind the generic message', () {
      expect(
        localizeSeerrError(
          'DioException [unknown]: getRequests: HTTP 500 - '
              'Internal Server Error',
          _l10n,
        ),
        _failedToLoad,
      );
    });

    test('reports connection failures as unable to connect', () {
      const cases = [
        'DioException [receive timeout]: The request took longer than '
            '0:00:30.000000 to receive data.',
        'DioException [connection error]: The connection errored: '
            'Connection refused',
        'SocketException: No route to host (OS Error: No route to host, '
            'errno = 113)',
        'DioException [unknown]: getIssues: HTTP 502 - Cannot reach Seerr',
      ];
      for (final raw in cases) {
        expect(localizeSeerrError(raw, _l10n), _unableToConnect, reason: raw);
      }
    });

    test('uses the generic message when the server refuses', () {
      expect(
        localizeSeerrError(
          'DioException [unknown]: getIssues: HTTP 403 - Forbidden',
          _l10n,
        ),
        _failedToLoad,
      );
    });
  });
}
