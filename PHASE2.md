# Phase 2 scope

Written 2026-11-09, after phase 1 closed. Nothing here is built.

## Where phase 1 actually ended

Checked today, not taken from PLAN.md:

- `flutter analyze` clean.
- 915 tests pass, 1 skipped. The skip is `test/seed_device_test.dart`, the
  device-seeding tool, skipped on purpose by a tag.
- Working tree clean, all 11 milestones committed.

One thing in PLAN.md is now stale. It names the Settings gap (tax type, FSSAI,
GSTIN editable only during first-run setup) as "the one thing I would fix first
in phase 2". Commits `e12067a` and `b2f18c0` already fixed it, and added outlet
header snapshotting so a reprint carries the details the bill was originally
issued with. That is done.

## How this list was put together

By reading the code for repository methods and settings fields that no screen
reaches, and by collecting what PLAN.md, CA_REVIEW.md and HARDWARE_TEST.md
already flag as deferred. Every item below cites where the gap is, so none of
it is speculation about what a POS "should" have.

---

## Tier A: finish what phase 1 started

Three features are built and tested but cannot be reached by anyone using the
app. This is the same shape as the FSSAI gap that was just fixed: a repository
method with no screen. No decision from you or the CA is needed to do any of
them.

### A1. The UPI QR code can never print

`core/receipt.dart:366` prints a UPI QR when `outlet.upiVpa` is set, and the
block is covered by `receipt_render_test.dart` and `sample_receipts_test.dart`.
But nothing writes that column. `setup_screen.dart` never collects it, no
settings section edits it, and the only code that sets it is test code. In a
real install `upiVpa` is always null, so the QR never appears.

Cost: a field in Settings → Bill details, a field in first-run setup, and
validation of the VPA shape. Small.

Why it is first: UPI is how most customers in Andhra Pradesh pay, the feature
is already written and tested, and it is currently dead code. Best value per
line in this document.

### A2. Staff management has no screen. **DONE 2026-11-09**

`completeSetup` creates the owner and nobody else. `addUser` and
`deactivateUser` (`data/setup_repository.dart:247`, `:296`) and `changePin`
(`data/auth_repository.dart:233`) exist with tests, and nothing in
`lib/features` calls them.

Two consequences:

- Every sale is attributed to the owner, because the owner is the only user.
  The audit log and the two roles do not mean anything in practice until a
  cashier can have their own PIN.
- A forgotten PIN has no recovery path short of a reinstall, which costs the
  data. PLAN.md decision 2 deliberately has no backdoor PIN, which is right,
  but it assumes an owner screen that resets one. That screen was never built.

Cost: one screen, add and deactivate a user, owner resets a PIN, a cashier
changes their own. The data layer is done. Small to medium.

**Built.** `features/settings/staff_screen.dart`, reached from Settings, plus a
My PIN dialog also under Settings, which is now reachable by both roles: a
cashier sees that one card and nothing else, because they have to be able to
change the PIN the owner gave them. Two methods the
data layer turned out to be missing were added with it: `AuthRepository.resetPin`
(the owner's reset, which `changePin` cannot be because it needs the forgotten
PIN) and `SetupRepository.reactivateUser` (so removing someone is not a one-way
door). 40 tests, 18 on the data layer and 22 on the screens.

Resetting someone else's PIN asks for the owner's own PIN first, the same
re-entry the brief requires before cancelling a bill, because it is the one
action here that hands over the ability to sign in as another person. Not run
on hardware yet: the checklist item is in HARDWARE_TEST.md.

### A3. Credit sales have no ledger

`PaymentMode.credit` is recorded so the bill total reconciles, and
`core/domain.dart:110` says plainly "no ledger in Phase 1". So a sale can go on
the slate, but nothing tracks who owes what or lets it be settled later.

Cost: a customer table and a settle flow, so a schema migration. Largest of the
three. Worth doing only if the restaurant actually uses the slate, which is
worth asking before building.

### A4. No day close

Reports give day, week and month sales. Nothing states what the cash drawer
should hold so it can be counted against the till. Most single-outlet
restaurants want this before they want anything in Tier C.

Cost: medium. A shift or day record, expected against counted, and the
difference recorded.

---

## Tier B: waiting on the CA

Each depends on an answer in CA_REVIEW.md. Do not build these on a guess.

- **Credit notes.** The schema already reserves `credit_note` as a `doc_type`
  and `ref_bill_id`, both unused. CA_REVIEW asks whether the restaurant needs
  them before going live. If yes, this is a scope change and belongs in phase 2.
- **Separate invoice series** for tax invoices and bills of supply. The app uses
  one series. CA_REVIEW §7 lists this among the three things the software is
  most likely to have wrong, and notes that separating them later is painful.
  Cheap now, expensive after real bills exist.
- **Forbid composition plus aggregator**, if the CA says a composition dealer
  may not supply through an aggregator. The app currently allows the
  combination.

## Tier C: new scope, needs a business decision

Everything here was agreed out of scope for phase 1. None of it is a gap; each
is a new product decision.

- **Kitchen tickets.** The usual next request after billing works.
- **Table management**, running tabs for dine-in.
- **A second till, and sync.** `outbox` is already written by
  `bill_repository` and `menu_repository` and indexed on unsent, and nothing
  reads it. That table is the designed hook for this, and reading it is where
  phase 3 starts if this is the direction.
- **Inventory and stock.**
- **Service charge and e-invoicing.** Only if their turnover or policy demands
  it, which CA_REVIEW asks.

---

## Recommendation

**Phase 2 is Tier A.** It needs no answer from you or the CA, it finishes
features phase 1 already paid for, and A1 and A2 are the difference between a
demo and something two people can run a counter with. A3 and A4 depend on
whether the slate and the drawer count are things this restaurant actually
does, which is one conversation.

**Hold Tier B until the CA answers.** The invoice series question in particular
gets more expensive every day there are real bills.

**Do not start Tier C until HARDWARE_TEST.md comes back.** Bluetooth is
entirely unverified. If real paper does not come out of a real printer, the fix
lands in `printing/`, and that is not work to discover under a layer of new
features.

## The one question that decides phase 3

Is this app for **one restaurant running better**, or for **more restaurants**?

- One outlet running better points at kitchen tickets, tables and the day
  close, and the `outbox` stays dormant.
- More outlets points at the second till and sync, which means reading the
  outbox, and that is a much larger piece of work with a server in it.

Phase 2 as scoped above is the same either way, so this does not block
starting. It decides what comes after.
