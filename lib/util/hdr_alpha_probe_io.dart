import 'dart:io';

/// Reads the technique the runner was told to apply. See
/// [hdr_alpha_probe.dart] for what the numbers mean.
int readMode() {
  if (!Platform.isWindows) return 0;
  final raw = Platform.environment['MOONFIN_HDR_Q4']?.trim();
  if (raw == null || raw.isEmpty) return 0;
  // The runner parses the whole string too, now that mode 10 exists.
  final mode = int.tryParse(raw) ?? 0;
  return mode >= 1 && mode <= 11 ? mode : 0;
}
