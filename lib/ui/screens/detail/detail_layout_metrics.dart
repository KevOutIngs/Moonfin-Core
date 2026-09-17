/// The geometry the detail screens and their loading skeleton both depend on.
///
/// The skeleton has to land where the content will land, so anything deciding
/// a hero inset, a poster size or which form factor a style draws for belongs
/// here rather than in one of the two and copied into the other.
///
/// The helpers that read a preference take an optional one, because the
/// skeleton can be built before any is registered and they fall back to the
/// defaults rather than throwing.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../preference/preference_constants.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/platform_detection.dart';
import '../../widgets/top_toolbar.dart';

const double _kCompactBreakpoint = 600.0;

UserPreferences? _resolvePrefs(UserPreferences? prefs) =>
    prefs ??
    (GetIt.instance.isRegistered<UserPreferences>()
        ? GetIt.instance<UserPreferences>()
        : null);

double detailDesktopScale({UserPreferences? prefs}) =>
    _resolvePrefs(prefs)?.get(UserPreferences.desktopUiScale).scaleFactor ??
    1.0;

/// A bottom navbar leaves the hero as much room as a left one does, so the
/// three way preference collapses to the one question the layouts ask.
bool _navbarIsTop({UserPreferences? prefs}) =>
    (_resolvePrefs(prefs)?.get(UserPreferences.navbarPosition) ??
        NavbarPosition.top) ==
    NavbarPosition.top;

bool detailIsCompact(BuildContext context) =>
    !PlatformDetection.isTV &&
    (PlatformDetection.useMobileUi ||
        MediaQuery.sizeOf(context).width < _kCompactBreakpoint);

/// Whether the Classic style draws its two column header. A phone held
/// sideways gets the desktop header once it's wide enough to fit one.
bool useDesktopDetailLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final isLandscape = size.width > size.height;
  return !detailIsCompact(context) ||
      (PlatformDetection.useMobileUi && isLandscape && size.width >= 700);
}

/// Whether Modern and Spotlight draw their landscape layout. Both treat a TV
/// and a desktop as landscape whatever the window shape says, so this isn't
/// the same question as `width > height`.
bool detailUsesLandscapeLayout(BuildContext context) =>
    PlatformDetection.isTV ||
    PlatformDetection.useDesktopUi ||
    MediaQuery.orientationOf(context) == Orientation.landscape;

/// The Classic poster, which is the only detail style that has one.
Size classicDetailPosterSize(BuildContext context, {UserPreferences? prefs}) {
  if (!useDesktopDetailLayout(context)) {
    return const Size(120, 180);
  }
  final scale = detailDesktopScale(prefs: prefs);
  return Size(165.0 * scale, 248.0 * scale);
}

/// The gap Modern and Spotlight portrait reserve above the hero so the
/// backdrop shows through the top of the page.
double detailPortraitBackdropGap(Size size, double topInset) =>
    size.height * 0.26 + topInset;

double nouveauHeroScale(Size size) {
  if (size.height > size.width) {
    return (size.width / 430.0).clamp(0.84, 1.0);
  }
  return (size.width / 1920.0).clamp(0.90, 1.08);
}

/// How far down the Nouveau landscape hero starts.
///
/// The designed inset is a share of a desktop screen, so on a 540 tall TV it
/// takes a third of the viewport and leaves the action row no room. Cap it at
/// a fifth of the screen, with the toolbar it sits under as the floor. Taller
/// screens keep the inset they had.
double nouveauHeroTop(BuildContext context, {UserPreferences? prefs}) {
  final navbarIsTop = _navbarIsTop(prefs: prefs);

  final size = MediaQuery.sizeOf(context);
  final scale = nouveauHeroScale(size);

  final designed = navbarIsTop
      ? (212.0 * scale).clamp(190.0, 232.0)
      : (152.0 * scale).clamp(136.0, 166.0);

  return math.min(
    designed,
    math.max(
      navbarIsTop ? TopToolbar.baseHeightFor(context) : 0.0,
      size.height * 0.20,
    ),
  );
}

/// The Nouveau portrait hero is a tall box with its text pinned to the bottom,
/// so the backdrop fills everything above it. A tablet gives it more room than
/// a phone.
double nouveauHeroMinHeight(Size size) {
  final isPhonePortrait = size.height > size.width && size.width < 600;
  return isPhonePortrait
      ? (size.height * 0.60).clamp(500.0, 610.0)
      : (size.height * 0.74).clamp(560.0, 720.0);
}

/// The horizontal inset either side of the Nouveau landscape hero.
double nouveauHorizontalInset(Size size) => PlatformDetection.isTV
    ? 56.0
    : (size.width * 0.046).clamp(56.0, 96.0);
