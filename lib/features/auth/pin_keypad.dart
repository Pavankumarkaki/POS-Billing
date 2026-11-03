/// The PIN keypad and its dots, shared by the login screen and the owner-PIN
/// confirmation that cancelling a bill needs.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Four dots that fill as digits are entered.
class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.entered, this.size = 20});

  final int entered;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$entered of 4 digits entered',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary, width: 2),
                color: i < entered ? AppColors.primary : Colors.transparent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The 3x4 keypad: 1-9, Clear, 0, backspace.
///
/// Sized by its parent rather than fixed, so the same widget works at 84px
/// rows on a tablet and fills the remaining sheet height on a phone.
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onClear,
    required this.onBackspace,
    this.enabled = true,
    this.fontSize = 26,
    this.spacing = 8,
    this.rowHeight,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onClear;
  final VoidCallback onBackspace;
  final bool enabled;
  final double fontSize;
  final double spacing;

  /// Fixed row height for the tablet layout. Null lets rows share the space.
  final double? rowHeight;

  @override
  Widget build(BuildContext context) {
    const keys = [
      '1', '2', '3',
      '4', '5', '6',
      '7', '8', '9',
      'clear', '0', 'back',
    ];

    Widget key(String k) {
      final isDigit = RegExp(r'^\d$').hasMatch(k);
      final label = switch (k) {
        'clear' => 'Clear',
        'back' => null,
        _ => k,
      };
      final semantic = switch (k) {
        'clear' => 'Clear',
        'back' => 'Delete last digit',
        _ => k,
      };

      return OutlinedButton(
        onPressed: enabled
            ? () {
                if (isDigit) {
                  onDigit(k);
                } else if (k == 'clear') {
                  onClear();
                } else {
                  onBackspace();
                }
              }
            : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          backgroundColor: AppColors.surface,
          side: const BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.large),
          ),
          padding: EdgeInsets.zero,
        ),
        child: Semantics(
          label: semantic,
          button: true,
          excludeSemantics: true,
          child: label == null
              ? const Icon(Icons.backspace_outlined, size: 24)
              : Text(
                  label,
                  style: TextStyle(
                    fontSize: k == 'clear' ? fontSize * 0.62 : fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      );
    }

    final rows = <Widget>[];
    for (var r = 0; r < 4; r++) {
      final row = Row(
        // Without this, Expanded sets each key's WIDTH but leaves its height
        // to the button's own minimum, so rowHeight is silently ignored.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var c = 0; c < 3; c++) ...[
            if (c > 0) SizedBox(width: spacing),
            Expanded(child: key(keys[r * 3 + c])),
          ],
        ],
      );
      rows.add(
        rowHeight == null
            ? Expanded(child: row)
            : SizedBox(height: rowHeight, child: row),
      );
      if (r < 3) rows.add(SizedBox(height: spacing));
    }

    return Column(
      mainAxisSize: rowHeight == null ? MainAxisSize.max : MainAxisSize.min,
      children: rows,
    );
  }
}
