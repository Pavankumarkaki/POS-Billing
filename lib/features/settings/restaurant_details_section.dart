/// The Restaurant card in Settings: name, address and phone.
///
/// The three lines at the top of every bill. From the design canvas's setup
/// and Settings artboards, which both group them as "Restaurant", separate
/// from the licence and tax card.
///
/// No confirmation dialog here, unlike a tax type change. Correcting a phone
/// number changes nothing about what a bill IS, and bills already printed
/// keep the details they were printed with, because each one snapshots its
/// own header. See the note on those columns in data/tables.dart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/outlet_repository.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';

class RestaurantDetailsSection extends ConsumerStatefulWidget {
  const RestaurantDetailsSection({super.key});

  @override
  ConsumerState<RestaurantDetailsSection> createState() =>
      _RestaurantDetailsSectionState();
}

class _RestaurantDetailsSectionState
    extends ConsumerState<RestaurantDetailsSection> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();

  OutletIdentity? _stored;
  bool _busy = false;
  String? _message;
  bool _messageIsBad = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _adopt(OutletIdentity stored) {
    _stored = stored;
    _name.text = stored.name;
    _address.text = stored.address;
    _phone.text = stored.phone;
  }

  OutletIdentity get _draft => OutletIdentity(
        name: _name.text.trim(),
        address: _address.text.trim(),
        phone: _phone.text.trim(),
      );

  bool get _dirty {
    final s = _stored;
    if (s == null) return false;
    final d = _draft;
    return d.name != s.name || d.address != s.address || d.phone != s.phone;
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final changed = await ref
          .read(outletRepositoryProvider)
          .updateIdentity(_draft, byUserId: session.userId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsBad = false;
        _message = changed ? 'Saved.' : 'Nothing to change.';
      });
    } on OutletError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsBad = true;
        _message = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(outletIdentityProvider);

    return identity.when(
      loading: () => const _Card(
        children: [Center(child: CircularProgressIndicator())],
      ),
      error: (e, _) => _Card(children: [Text('$e')]),
      data: (stored) {
        if (stored == null) {
          return const _Card(
            children: [Text('Finish first-run setup first.')],
          );
        }

        // Adopted the first time, and again if it changes underneath, for
        // example after a restore. An edit in progress is left alone.
        if (_stored == null ||
            (!_dirty &&
                (_stored!.name != stored.name ||
                    _stored!.address != stored.address ||
                    _stored!.phone != stored.phone))) {
          _adopt(stored);
        }

        return _Card(
          children: [
            const Text(
              'Restaurant',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const Key('outlet-name-field'),
              controller: _name,
              enabled: !_busy,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Restaurant name',
                helperText: 'Printed at the top of every bill',
              ),
              onChanged: (_) => setState(() => _message = null),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const Key('outlet-address-field'),
              controller: _address,
              enabled: !_busy,
              minLines: 2,
              maxLines: 3,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Address'),
              onChanged: (_) => setState(() => _message = null),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const Key('outlet-phone-field'),
              controller: _phone,
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
              onChanged: (_) => setState(() => _message = null),
            ),
            const SizedBox(height: AppSpace.md),
            const Text(
              // The reassurance worth giving unprompted: an owner about to
              // fix a typo wonders whether it rewrites what customers hold.
              'Bills already printed keep the details they were printed '
              'with. This changes bills from now on.',
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: AppColors.muted,
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: AppSpace.md),
              Container(
                key: const Key('restaurant-message'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color:
                      _messageIsBad ? AppColors.dangerBg : AppColors.softGreen,
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: _messageIsBad
                        ? AppColors.dangerText
                        : AppColors.primary,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            FilledButton(
              key: const Key('save-restaurant'),
              onPressed: _busy || !_dirty ? null : _save,
              style: primaryActionStyle(),
              child: _busy
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save restaurant details'),
            ),
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: AppSpace.lg),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.large),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      );
}
