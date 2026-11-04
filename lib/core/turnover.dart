/// Turnover thresholds, and when to warn the owner about them.
///
/// Two limits matter to this restaurant:
///
///   - **₹20 lakh** — the GST registration threshold for a service provider
///     in most states. Cross it while unregistered and registration becomes
///     compulsory.
///   - **₹1.5 crore** — the composition scheme limit. Cross it and the
///     restaurant must move to regular GST.
///
/// Both are measured on turnover in the **financial year**, not a rolling
/// twelve months, which is why everything here takes a [FinancialYear].
///
/// The app warns; it does not advise. Crossing a threshold has consequences
/// this app is in no position to explain, so every warning points at the CA.
/// See CA_REVIEW.md.
library;

import 'business_date.dart';
import 'money.dart';
import 'tax.dart';

/// The GST registration threshold for services. ₹20 lakh.
///
/// Some special-category states use ₹10 lakh. Andhra Pradesh is not one, but
/// the figure is a constant here rather than scattered, so changing it is one
/// edit. The CA confirms it; see CA_REVIEW.md section 6.
final Paise kRegistrationThreshold = Paise.fromRupees(2000000);

/// The composition scheme turnover limit. ₹1.5 crore.
final Paise kCompositionThreshold = Paise.fromRupees(15000000);

/// Warn at 80% rather than on the day it is crossed.
///
/// By the time a threshold is actually crossed it is too late to plan: the
/// restaurant needs to have registered already. 80% gives roughly a couple of
/// months' notice at a steady run rate.
const double kWarnAtFraction = 0.8;

/// How close the restaurant is to the limit that applies to it.
enum TurnoverLevel {
  /// Nothing to say.
  fine,

  /// Past 80%. Time to talk to the CA.
  approaching,

  /// Past the limit. Something must change.
  exceeded,
}

/// A warning to show the owner, or null when there is nothing to say.
class TurnoverWarning {
  const TurnoverWarning({
    required this.level,
    required this.turnover,
    required this.threshold,
    required this.headline,
    required this.detail,
  });

  final TurnoverLevel level;
  final Paise turnover;
  final Paise threshold;

  /// One line, for a banner.
  final String headline;

  /// What to do about it. Always points at the CA.
  final String detail;

  /// 0 to 1, clamped. For a progress bar.
  double get fraction {
    if (threshold.value <= 0) return 0;
    final f = turnover.value / threshold.value;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }

  /// What is left before the limit. Zero once it is passed.
  Paise get remaining =>
      turnover >= threshold ? Paise.zero : threshold - turnover;
}

/// Works out whether the owner needs telling.
///
/// Returns null in the regular GST modes: there is no turnover limit to warn
/// about once the restaurant is already registered and charging tax.
TurnoverWarning? turnoverWarning({
  required TaxMode mode,
  required Paise turnoverThisYear,
  required FinancialYear fy,
}) {
  final threshold = switch (mode) {
    TaxMode.unregistered => kRegistrationThreshold,
    TaxMode.composition => kCompositionThreshold,
    // Already registered under regular GST: no ceiling to cross.
    TaxMode.regular5 || TaxMode.regular18 => null,
  };
  if (threshold == null) return null;

  final warnAt = Paise((threshold.value * kWarnAtFraction).round());
  if (turnoverThisYear < warnAt) return null;

  final exceeded = turnoverThisYear >= threshold;
  final level = exceeded ? TurnoverLevel.exceeded : TurnoverLevel.approaching;

  final (headline, detail) = switch ((mode, exceeded)) {
    (TaxMode.unregistered, false) => (
        'Approaching the GST registration limit',
        'Turnover for ${fy.label} is ${turnoverThisYear.rupeesWhole} of '
            '${threshold.rupeesWhole}. Registration becomes compulsory once '
            'you cross it. Speak to your CA before that happens.',
      ),
    (TaxMode.unregistered, true) => (
        'Past the GST registration limit',
        'Turnover for ${fy.label} is ${turnoverThisYear.rupeesWhole}, over '
            'the ${threshold.rupeesWhole} limit. Registration is compulsory. '
            'Speak to your CA now.',
      ),
    (TaxMode.composition, false) => (
        'Approaching the composition limit',
        'Turnover for ${fy.label} is ${turnoverThisYear.rupeesWhole} of '
            '${threshold.rupeesWhole}. Past this you must move to regular '
            'GST. Speak to your CA before that happens.',
      ),
    (TaxMode.composition, true) => (
        'Past the composition limit',
        'Turnover for ${fy.label} is ${turnoverThisYear.rupeesWhole}, over '
            'the ${threshold.rupeesWhole} limit. You must move to regular '
            'GST. Speak to your CA now.',
      ),
    _ => ('', ''),
  };

  return TurnoverWarning(
    level: level,
    turnover: turnoverThisYear,
    threshold: threshold,
    headline: headline,
    detail: detail,
  );
}
