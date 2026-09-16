import '../../l10n/app_localizations.dart';

const _connectionMarkers = [
  'timeout',
  'timed out',
  'connection',
  'socketexception',
  'network',
  'failed host lookup',
  'unreachable',
  'http 502',
  'http 503',
  'http 504',
];

String localizeSeerrError(String error, AppLocalizations l10n) {
  final lower = error.toLowerCase();
  if (_connectionMarkers.any(lower.contains)) {
    return l10n.unableToConnectToServer;
  }
  return l10n.failedToLoad;
}
