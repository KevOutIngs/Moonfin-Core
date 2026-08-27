import 'package:flutter/widgets.dart';

/// Web stand-in for [hdr_overlay_benchmark.dart].
///
/// The real one measures a Windows-only readback and reaches for `dart:io` to
/// read its environment variable and write its results, neither of which exists
/// on web. Importing it conditionally keeps `dart:io` out of the web build
/// entirely rather than relying on a `kIsWeb` check that would still have to
/// compile the import.
class HdrOverlayBenchmarkApp extends StatelessWidget {
  const HdrOverlayBenchmarkApp({super.key});

  static bool get requested => false;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
