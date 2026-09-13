import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../l10n/app_localizations.dart';
import '../../../playback/live_tv_stream_status.dart';
import '../focus/focusable_button.dart';

/// What the live player shows over the video for a [LiveTvStreamStatus].
///
/// A normal channel change is only a spinner; once the wait has run long
/// enough to mean the tuner is retrying, or a playing channel has dropped,
/// a line under it says so. The two failure states get a card with Retry and Back,
/// since by then the tuner has already given up and a spinner would only
/// hide that. A screen that still has something usable behind the card, such
/// as its own channel controls and guide, passes [onDismiss] to add a
/// Dismiss button between the two. [compact] is for the mini-player box
/// behind the in-player guide, where there is no room for the card.
class LiveTvStreamStatusOverlay extends StatelessWidget {
  const LiveTvStreamStatusOverlay({
    super.key,
    required this.status,
    required this.onRetry,
    required this.onExit,
    required this.retryFocusNode,
    this.onDismiss,
    this.compact = false,
  });

  final LiveTvStreamStatus status;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  /// Hides the card and leaves the viewer in the player. Null when there is
  /// nothing behind the card to go back to, in which case only Retry and
  /// Back are offered.
  final VoidCallback? onDismiss;

  /// The owning screen moves the remote's focus onto this node when the card
  /// appears. Autofocus alone loses to whatever player control already holds
  /// focus in the same scope.
  final FocusNode retryFocusNode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (status) {
      case LiveTvStreamStatus.idle:
      case LiveTvStreamStatus.playing:
        return const SizedBox.shrink();
      case LiveTvStreamStatus.buffering:
      case LiveTvStreamStatus.connecting:
        return _spinner(null);
      case LiveTvStreamStatus.stillTrying:
        return _spinner(l10n.liveTvTunerStillTrying);
      case LiveTvStreamStatus.reconnecting:
        return _spinner(l10n.liveTvReconnecting);
      case LiveTvStreamStatus.unavailable:
      case LiveTvStreamStatus.lost:
        final text = failureText(l10n, status);
        return _failure(context, title: text.title, body: text.body);
    }
  }

  /// What the card says for a failure. The native Apple TV card says the
  /// same thing for the same verdict, so both read it from here.
  static ({String title, String body}) failureText(
    AppLocalizations l10n,
    LiveTvStreamStatus status,
  ) {
    assert(status.isFailure, '$status is not a failure');
    return status == LiveTvStreamStatus.lost
        ? (title: l10n.liveTvChannelLostTitle, body: l10n.liveTvChannelLostBody)
        : (
            title: l10n.liveTvChannelUnavailableTitle,
            body: l10n.liveTvChannelUnavailableBody,
          );
  }

  Widget _spinner(String? label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColorScheme.accent),
          if (label != null) ...[
            const SizedBox(height: AppSpacing.spaceLg),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.spaceLg,
                vertical: AppSpacing.spaceSm,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: AppRadius.circular(8),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppTypography.fontSizeMd,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _failure(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: compact
            ? Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppTypography.fontSizeSm,
                  fontWeight: FontWeight.w600,
                ),
              )
            : _card(title: title, body: body),
      ),
    );
  }

  Widget _card({required String title, required String body}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Container(
        margin: const EdgeInsets.all(AppSpacing.spaceXl),
        padding: const EdgeInsets.all(AppSpacing.spaceXl),
        decoration: BoxDecoration(
          color: AppColorScheme.surface,
          borderRadius: AppRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.tv_off_rounded,
              size: 40,
              color: AppColorScheme.onSurface.withValues(alpha: 0.8),
            ),
            const SizedBox(height: AppSpacing.spaceMd),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColorScheme.onSurface,
                fontSize: AppTypography.fontSizeXl,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.spaceSm),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColorScheme.onSurface.withValues(alpha: 0.62),
                fontSize: AppTypography.fontSizeSm,
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.spaceXl),
            _FailureActions(
              retryFocusNode: retryFocusNode,
              onRetry: onRetry,
              onDismiss: onDismiss,
              onExit: onExit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Retry over Dismiss over Back, on the app's own focusable buttons.
/// Material buttons never fire from a TV remote here: the select key is
/// consumed by the focus wrapper layer, so the buttons have to be that
/// layer. Up and down move between them, and the remote's back key leaves
/// the player. Dismiss is only there when the screen offers it.
class _FailureActions extends StatefulWidget {
  const _FailureActions({
    required this.retryFocusNode,
    required this.onRetry,
    required this.onDismiss,
    required this.onExit,
  });

  final FocusNode retryFocusNode;
  final VoidCallback onRetry;
  final VoidCallback? onDismiss;
  final VoidCallback onExit;

  @override
  State<_FailureActions> createState() => _FailureActionsState();
}

class _FailureActionsState extends State<_FailureActions> {
  final _dismissFocus = FocusNode(debugLabel: 'LiveTvDismiss');
  final _backFocus = FocusNode(debugLabel: 'LiveTvBack');

  @override
  void dispose() {
    _dismissFocus.dispose();
    _backFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final retryFocus = widget.retryFocusNode;
    final onDismiss = widget.onDismiss;
    final belowRetry = onDismiss != null ? _dismissFocus : _backFocus;
    final aboveBack = onDismiss != null ? _dismissFocus : retryFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableButton(
          focusNode: retryFocus,
          borderRadius: 14,
          padding: EdgeInsets.zero,
          onPressed: widget.onRetry,
          onNavigateDown: belowRetry.requestFocus,
          onBack: widget.onExit,
          semanticLabel: l10n.retry,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              color: AppColorScheme.accent,
              borderRadius: AppRadius.circular(14),
            ),
            child: Text(
              l10n.retry,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColorScheme.onAccent,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (onDismiss != null) ...[
          const SizedBox(height: AppSpacing.spaceSm),
          _secondaryButton(
            focusNode: _dismissFocus,
            label: l10n.dismiss,
            onPressed: onDismiss,
            onNavigateUp: retryFocus.requestFocus,
            onNavigateDown: _backFocus.requestFocus,
          ),
        ],
        const SizedBox(height: AppSpacing.spaceSm),
        _secondaryButton(
          focusNode: _backFocus,
          label: l10n.back,
          onPressed: widget.onExit,
          onNavigateUp: aboveBack.requestFocus,
        ),
      ],
    );
  }

  Widget _secondaryButton({
    required FocusNode focusNode,
    required String label,
    required VoidCallback onPressed,
    required VoidCallback onNavigateUp,
    VoidCallback? onNavigateDown,
  }) {
    return FocusableButton(
      focusNode: focusNode,
      borderRadius: 14,
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      onNavigateUp: onNavigateUp,
      onNavigateDown: onNavigateDown,
      onBack: widget.onExit,
      semanticLabel: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColorScheme.onSurface.withValues(alpha: 0.75),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
