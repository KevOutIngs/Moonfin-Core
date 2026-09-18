import 'package:flutter/material.dart';

/// TV and desktop: the title and buttons sit low on the left over the artwork,
/// with the episodes along the bottom. Nothing competes with them for the
/// upper half, which is where the picture is.
class MinimalistLandscapeLayout extends StatelessWidget {
  final Widget branding;
  final Widget actions;
  final Widget? episodes;

  /// Sits opposite the title, in the space the artwork was using. An episode
  /// puts its own still here, since the backdrop behind is the whole show and
  /// says nothing about which part of it you're on.
  final Widget? aside;

  const MinimalistLandscapeLayout({
    super.key,
    required this.branding,
    required this.actions,
    this.episodes,
    this.aside,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [branding, const SizedBox(height: 26), actions],
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 40, 56, 44),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: content,
                      ),
                    ),
                  ),
                  if (aside != null) ...[
                    const SizedBox(width: 48),
                    Align(alignment: Alignment.bottomRight, child: aside!),
                  ],
                ],
              ),
            ),
            if (episodes != null) ...[
              const SizedBox(height: 34),
              episodes!,
            ],
          ],
        ),
      ),
    );
  }
}
