import 'dart:io';

/// Reads the DWM-composition experiment mode. See [hdr_composition.dart].
int readDwmMode() {
  if (!Platform.isWindows) return 0;
  final raw = Platform.environment['MOONFIN_HDR_DWM']?.trim();
  if (raw == null || raw.isEmpty) return 0;
  final mode = int.tryParse(raw) ?? 0;
  return mode >= 1 && mode <= 4 ? mode : 0;
}
