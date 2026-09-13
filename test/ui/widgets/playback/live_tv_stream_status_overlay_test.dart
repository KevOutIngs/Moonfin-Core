import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/playback/live_tv_stream_status.dart';
import 'package:moonfin/ui/widgets/playback/live_tv_stream_status_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppLocalizations> pumpCard(
    WidgetTester tester, {
    required FocusNode retryFocus,
    VoidCallback? onRetry,
    VoidCallback? onDismiss,
    VoidCallback? onExit,
    LiveTvStreamStatus status = LiveTvStreamStatus.unavailable,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LiveTvStreamStatusOverlay(
            status: status,
            retryFocusNode: retryFocus,
            onRetry: onRetry ?? () {},
            onDismiss: onDismiss,
            onExit: onExit ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('en'));
  }

  testWidgets('failure card offers Retry and Back only without onDismiss', (
    tester,
  ) async {
    final retryFocus = FocusNode();
    addTearDown(retryFocus.dispose);
    final l10n = await pumpCard(tester, retryFocus: retryFocus);

    expect(find.text(l10n.liveTvChannelUnavailableTitle), findsOneWidget);
    expect(find.text(l10n.retry), findsOneWidget);
    expect(find.text(l10n.back), findsOneWidget);
    expect(find.text(l10n.dismiss), findsNothing);
  });

  testWidgets('Dismiss sits between Retry and Back and fires its callback', (
    tester,
  ) async {
    final retryFocus = FocusNode();
    addTearDown(retryFocus.dispose);
    var dismissed = 0;
    var retried = 0;
    var exited = 0;
    final l10n = await pumpCard(
      tester,
      retryFocus: retryFocus,
      status: LiveTvStreamStatus.lost,
      onRetry: () => retried++,
      onDismiss: () => dismissed++,
      onExit: () => exited++,
    );

    expect(find.text(l10n.liveTvChannelLostTitle), findsOneWidget);
    final retryY = tester.getCenter(find.text(l10n.retry)).dy;
    final dismissY = tester.getCenter(find.text(l10n.dismiss)).dy;
    final backY = tester.getCenter(find.text(l10n.back)).dy;
    expect(retryY, lessThan(dismissY));
    expect(dismissY, lessThan(backY));

    await tester.tap(find.text(l10n.dismiss));
    await tester.pump();

    expect(dismissed, 1);
    expect(retried, 0);
    expect(exited, 0);
  });

  testWidgets('down from Retry lands on Dismiss, then Back, and up returns', (
    tester,
  ) async {
    final retryFocus = FocusNode();
    addTearDown(retryFocus.dispose);
    final l10n = await pumpCard(
      tester,
      retryFocus: retryFocus,
      onDismiss: () {},
    );
    retryFocus.requestFocus();
    await tester.pump();
    expect(retryFocus.hasPrimaryFocus, isTrue);

    Finder focusedLabel() => find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode?.hasPrimaryFocus == true,
      ),
      matching: find.byType(Text),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Text>(focusedLabel().first).data, l10n.dismiss);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Text>(focusedLabel().first).data, l10n.back);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<Text>(focusedLabel().first).data, l10n.dismiss);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(retryFocus.hasPrimaryFocus, isTrue);
  });
}
