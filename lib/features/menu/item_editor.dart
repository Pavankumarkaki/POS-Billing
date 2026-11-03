/// The item edit form, shared by the tablet's side panel and the phone's own
/// edit screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../core/tax.dart';
import '../../data/db.dart';
import '../../theme/app_theme.dart';

/// What the editor hands back when saved.
class ItemDraft {
  const ItemDraft({
    required this.nameEn,
    required this.nameTe,
    required this.price,
    required this.taxClass,
    required this.isActive,
  });

  final String nameEn;
  final String nameTe;
  final Paise price;
  final TaxClass taxClass;
  final bool isActive;
}

class ItemEditor extends StatefulWidget {
  const ItemEditor({
    super.key,
    required this.item,
    required this.onSave,
    this.onCancel,
    this.title = 'Edit item',
  });

  /// Null creates a new item.
  final ItemRow? item;

  final Future<void> Function(ItemDraft draft) onSave;
  final VoidCallback? onCancel;
  final String title;

  @override
  State<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<ItemEditor> {
  late final TextEditingController _nameEn;
  late final TextEditingController _nameTe;
  late final TextEditingController _price;
  late TaxClass _taxClass;
  late bool _isActive;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final i = widget.item;
    _nameEn = TextEditingController(text: i?.nameEn ?? '');
    _nameTe = TextEditingController(text: i?.nameTe ?? '');
    // Shown in rupees, stored in paise. The edges are the only place rupees
    // exist; see core/money.dart.
    _price = TextEditingController(text: i == null ? '' : i.pricePaise.plain);
    _taxClass = i?.taxClass ?? TaxClass.gst5;
    _isActive = i?.isActive ?? true;
  }

  @override
  void didUpdateWidget(ItemEditor old) {
    super.didUpdateWidget(old);
    // The tablet keeps one editor mounted and swaps which item it shows, so
    // the fields must follow the selection rather than keep the old one.
    if (old.item?.id != widget.item?.id) {
      final i = widget.item;
      _nameEn.text = i?.nameEn ?? '';
      _nameTe.text = i?.nameTe ?? '';
      _price.text = i == null ? '' : i.pricePaise.plain;
      setState(() {
        _taxClass = i?.taxClass ?? TaxClass.gst5;
        _isActive = i?.isActive ?? true;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _nameEn.dispose();
    _nameTe.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;

    if (_nameEn.trim().isEmpty) {
      setState(() => _error = 'An item needs an English name.');
      return;
    }
    final price = Paise.tryParse(_price.text);
    if (price == null || price.isNegative) {
      setState(() => _error = 'Enter a price, like 240 or 240.50.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.onSave(ItemDraft(
        nameEn: _nameEn.text,
        nameTe: _nameTe.text,
        price: price,
        taxClass: _taxClass,
        isActive: _isActive,
      ));
      if (mounted) setState(() => _busy = false);
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            if (widget.onCancel != null)
              IconButton(
                onPressed: widget.onCancel,
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
          ],
        ),
        const SizedBox(height: AppSpace.md),

        Expanded(
          child: ListView(
            children: [
              _labelled(
                'Name in English',
                TextField(
                  key: const Key('item-name-en'),
                  controller: _nameEn,
                  style: const TextStyle(fontSize: 17),
                ),
              ),
              _labelled(
                'Name in Telugu',
                TextField(
                  key: const Key('item-name-te'),
                  controller: _nameTe,
                  style: const TextStyle(fontSize: 17),
                ),
              ),
              _labelled(
                'Price (₹)',
                TextField(
                  key: const Key('item-price'),
                  controller: _price,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),

              const Text(
                'Tax',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  for (final c in TaxClass.values) ...[
                    if (c != TaxClass.values.first)
                      const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: _TaxChip(
                        taxClass: c,
                        selected: _taxClass == c,
                        onTap: () => setState(() => _taxClass = c),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpace.md),

              _AvailableToggle(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
              ),
              const SizedBox(height: AppSpace.sm),
              const Text(
                'A price change applies to new bills only. Old bills keep the '
                'price they were sold at.',
                style: TextStyle(fontSize: 15, color: AppColors.muted),
              ),

              if (_error != null) ...[
                const SizedBox(height: AppSpace.md),
                Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    color: AppColors.dangerBg,
                    borderRadius: BorderRadius.circular(AppRadius.medium),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.dangerText,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: AppSpace.md),
        FilledButton(
          key: const Key('item-save'),
          onPressed: _busy ? null : _save,
          style: primaryActionStyle(),
          child: Text(widget.item == null ? 'Add item' : 'Save changes'),
        ),
      ],
    );
  }

  Widget _labelled(String label, Widget field) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            field,
          ],
        ),
      );
}

extension on TextEditingController {
  String trim() => text.trim();
}

class _TaxChip extends StatelessWidget {
  const _TaxChip({
    required this.taxClass,
    required this.selected,
    required this.onTap,
  });

  final TaxClass taxClass;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = switch (taxClass) {
      TaxClass.gst5 => 'GST 5%',
      TaxClass.gst18 => 'GST 18%',
      TaxClass.nonGst => 'No GST',
    };

    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? AppColors.primary : AppColors.surface,
        foregroundColor: selected ? Colors.white : AppColors.ink,
        side: BorderSide(
          color: selected ? AppColors.primary : AppColors.border,
        ),
        minimumSize: const Size(0, AppTouch.comfortable),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.small),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _AvailableToggle extends StatelessWidget {
  const _AvailableToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('item-available'),
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(AppRadius.medium),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Available to sell',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.xs,
              ),
              decoration: BoxDecoration(
                color: value ? AppColors.softGreen : AppColors.dangerBg,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                value ? 'Yes' : 'No',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: value ? AppColors.primary : AppColors.dangerText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
