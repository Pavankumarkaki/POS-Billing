# Phase 1 MVP plan: offline-first Android POS billing

Restaurant POS for a single outlet in Andhra Pradesh. One Android phone or tablet,
one 80 mm thermal printer, no server, no internet.

Written 2026-11-03. Nothing in this plan has been built or run yet.

---

## 1. Toolchain check (done, and it is a blocker)

I checked the machine before planning. Result:

| Thing | State |
| --- | --- |
| `flutter` | **not installed** (not on PATH, not in `~`, `/opt` or snap) |
| `dart` | not installed (ships with Flutter) |
| Android SDK / `adb` | **not installed** |
| JDK | OpenJDK 25.0.4.1 present. Too new for Android Gradle Plugin, which wants JDK 17 or 21 |
| git, curl, unzip, python3 | present |
| Disk free on `/` | 209 GB, plenty |
| OS | Ubuntu 26.04.1 LTS |

Current Flutter stable, read from the release index today, is **3.47.9 (Dart 3.13.7,
released 2026-10-29)**.

So "check that the Flutter toolchain works" currently answers: it does not exist. Nothing
in the definition of done (`flutter analyze`, tests, debug APK) can run until roughly
4 to 5 GB is installed:

- Flutter SDK 3.47.9, into `~/flutter` (~1.5 GB after first run)
- Android `cmdline-tools`, `platform-tools`, `platforms;android-36`, `build-tools;36.0.0`,
  into `~/Android/Sdk` (~2.5 GB)
- A JDK 21 (`openjdk-21-jdk` from apt), because AGP does not support JDK 25

This is question Q1 below. Everything else in this plan is ready to start the moment
the toolchain is in place.

## 2. Package check (done, with three substitutions I need to flag)

Every version below was read from the pub.dev API today, not from memory.

### Confirmed good, used as specified

| Package | Version | Last published | Note |
| --- | --- | --- | --- |
| `drift` / `drift_dev` | 2.35.3 / 2.35.2 | 2026-10-23 | actively maintained |
| `flutter_riverpod` | 3.4.3 | 2026-09-03 | needs Dart ^3.12, satisfied by 3.13.7 |
| `riverpod_generator` | 4.0.9 | 2026-09-03 | |
| `print_bluetooth_thermal` | 1.2.5 | 2026-09-28 | needs Flutter >= 3.44, satisfied |
| `permission_handler` | 13.0.2 | 2026-09-04 | for `BLUETOOTH_CONNECT` |
| `workmanager` | 0.10.10 | 2026-09-07 | nightly backup |
| `file_picker` | 13.3.2 | 2026-11-02 | pick the backup folder |
| `intl` | 0.20.3 | 2026-06-25 | |
| `uuid` | 4.6.0 | 2026-07-15 | has UUIDv7 (`Uuid().v7()`) |
| `crypto` | 3.0.8 | 2026-10-26 | PIN hashing, see §6 |
| `csv` | 8.0.0 | 2026-03-19 | |
| `image` | 4.12.0 | 2026-10-11 | 1-bit receipt bitmap |
| `path_provider` | 2.1.6 | 2026-06-15 | |

### Substitution 1: `sqlite3_flutter_libs` is dead. This one matters.

Its latest release is literally `0.6.0+eol`, described by its author as *"Not used
anymore, update to version 3.x of package:sqlite3 instead"*.

`sqlite3` 3.x (now 3.8.0) replaced `DynamicLibrary` loading with Dart **build hooks**
(native assets): it compiles or downloads SQLite at build time. Its changelog says
plainly to drop `sqlite3_flutter_libs` when upgrading.

So the DB dependency becomes `drift` + `sqlite3: ^3.8.0`, with no `sqlite3_flutter_libs`
and no `drift_flutter` (which still depends on the dead package).

**This is the single biggest technical risk in the plan.** Build hooks are a newer
mechanism and I cannot confirm, without the toolchain installed, whether Flutter 3.47.9
runs them for an Android release build without an `--enable-experiment` flag. Milestone 0
exists purely to prove this end to end on a real build before any feature code is written.
If it fails, the fallback is pinning `sqlite3: ^2.x` with `sqlite3_flutter_libs: 0.5.42`
(the last pre-EOL release, March 2026) and revisiting later. I will report which one we
are on rather than quietly picking.

### Substitution 2: `golden_toolkit` is abandoned

Last published 2023-02-21, and its SDK constraint is `<3.0.0`, so it cannot even resolve
against Dart 3. Golden receipt tests will use Flutter's built-in `matchesGoldenFile`,
which needs no dependency. This changes nothing about test coverage.

### Substitution 3 (flagged, not changed): two stale packages I will still use

- `esc_pos_utils_plus` 2.0.4, last published **2024-09-01**. Fourteen months stale but
  pure Dart with no native side, so staleness is low risk. Because we render our own
  bitmap and only need a handful of byte sequences (`GS v 0`, `ESC *`, init, cut), I will
  put it behind our own thin `EscPosCommands` wrapper. If it ever breaks, replacing it is
  about 100 lines and touches one file.
- `excel` 4.0.6, last published **2024-08-20**. Needed for the `.xlsx` the accountant
  wants. The maintained alternatives are commercial-licensed, which your brief rules out,
  so this stays. CSV export does not depend on it, so a failure here degrades to CSV only.

`qr_flutter` 4.1.0 (2023) is also stale, but the UPI QR must go on a **1-bit bitmap**, not
a widget, so I will generate the QR matrix directly rather than depend on it.

---

## 3. Architecture

Four layers. The brief's requirement that billing, tax and numbering be plain Dart drives
the whole shape: the `core` package below has **no `import 'package:flutter/...'` anywhere**,
which is enforced by a test, not just by discipline.

```
lib/
  core/              <-- pure Dart. No Flutter, no Drift. Unit-testable in milliseconds.
    money.dart          Paise, an int extension type. No doubles anywhere near money.
    tax.dart            TaxMode, TaxClass, computeBill(). The heart of the thing.
    invoice_no.dart     FY from a business date, A/2627/000123, the 16-char guard.
    business_date.dart  04:00 cutoff arithmetic.
    receipt_doc.dart    A printer-independent description of a receipt.
  data/              <-- Drift. Tables, DAOs, migrations, the one big transaction.
    db.dart, tables/, daos/, migrations/
  printing/          <-- Printer interface + three implementations.
    printer.dart        abstract class Printer
    bitmap.dart         ReceiptDoc -> 1-bit bitmap, 576 px default
    esc_pos.dart        our wrapper over esc_pos_utils_plus
    bluetooth_printer.dart, lan_printer.dart, fake_printer.dart
    queue.dart          serialises jobs so two never overlap
  features/          <-- Riverpod providers + screens, one folder per feature
    setup/ auth/ menu/ billing/ bills/ reports/ settings/ backup/
  l10n/              app_en.arb, app_te.arb
```

### Why these Flutter-specific choices (expanded in the README for a Go developer)

- **Riverpod over `setState`**: providers are a dependency-injection container plus a
  cache, closer to wiring interfaces in a Go `main()` than to a UI framework. It lets the
  billing screen depend on an *interface* (`Printer`) that tests swap for the fake one.
- **Drift over raw SQL**: generates typed Dart from table definitions, like `sqlc` for Go.
  You write schema and queries, it writes the boilerplate. Migrations are versioned and
  numbered, with generated schema snapshots so a migration test can verify every step.
- **Code generation** (`build_runner`): Drift and Riverpod both generate `.g.dart` files.
  Committed to the repo, so a fresh clone builds without running the generator.
- **`extension type Paise(int)`**: a compile-time-only wrapper. Zero runtime cost, but
  assigning a `double` to a `Paise` will not compile. This is the money rule enforced by
  the type system rather than by review.

### The transaction

One method, `BillRepository.commitSale()`, inside a single `db.transaction()`:

1. `SELECT next_seq FROM device` ... `UPDATE device SET next_seq = next_seq + 1`
2. insert `bill` (UUIDv7 id, invoice_no built from the seq just claimed)
3. insert all `bill_line` rows, each with its name/price/tax-rate snapshot
4. insert `payment` rows (one per split)
5. insert the `audit_log` entry
6. insert the `outbox` entry

Any throw rolls all six back, including the sequence increment, so a failed save leaves no
partial bill and no gap in the numbering. Tested by injecting a failure at each of the six
steps. `UNIQUE(device_id, device_seq)` is the backstop if two writers ever race.

Printing happens **after** this returns and commits. It cannot affect the bill.

### Tax engine shape

`computeBill()` is one pure function: cart lines plus an outlet tax config in, a fully
resolved bill out. Order of operations, fixed and tested:

1. line discounts, then the bill discount, spread across lines proportionally
2. if prices are tax-inclusive, back out the tax from the discounted amount
3. per line: tax at that line's rate, rounded to 2 decimals (paise)
4. sum CGST and SGST separately
5. round the total to the nearest rupee, and put the difference in `round_off`

`composition` computes a 5 % turnover figure for reports while printing no tax and the
required declaration. `aggregator` order types are tagged so reports can exclude their GST
from what the restaurant owes.

---

## 4. Milestones

Each is one commit, with `flutter analyze` clean and its tests passing. I will not call a
milestone done on anything I have not run.

| # | Milestone | Proves |
| --- | --- | --- |
| **0** | **Toolchain spike.** Empty app, `drift` + `sqlite3` 3.x, write and read one row, debug APK builds. | Settles the §2 native-assets risk before anything is built on it. |
| 1 | `core/`: money, tax, invoice numbering, business date. No Flutter, no DB, no UI. | The rules. Heaviest test suite in the project. |
| 2 | `data/`: schema v1, DAOs, `commitSale()` transaction, audit log, outbox. | Immutability, rollback, snapshots. |
| 3 | First-run setup, PIN login, roles, lockout. FSSAI gate blocking billing. | Permission checks. |
| 4 | Menu management, EN/TE names, enable/disable. | Snapshots stay fixed after menu edits. |
| 5 | Billing screen, phone one-handed and tablet two-pane, split payments. | A sale, end to end, saved. |
| 6 | `printing/`: interface, bitmap renderer, fake printer, golden receipts EN + TE. | Receipts, inspectable as PNG without hardware. |
| 7 | Bluetooth + LAN printers, queue, reconnect, failure and retry UI. | Printer failure never loses a bill. Hardware-blocked, see below. |
| 8 | Cancel with owner PIN and reason, reprint marked DUPLICATE. | Invoice number survives cancellation. |
| 9 | Reports: day/week/month, breakdowns, cutoff grouping, turnover warnings. | Cancelled bills excluded. |
| 10 | CSV + Excel export, nightly WorkManager backup, tested restore. | Backup and restore round-trip. |
| 11 | Docs: README, HARDWARE_TEST.md, CA_REVIEW.md. Airplane-mode run-through. | Definition of done. |

### What I will not be able to verify, and will say so

I have no 80 mm thermal printer, no Android device and no Bluetooth adapter here. The
Bluetooth and LAN printers in milestone 7 can only be verified as: code compiles, analyze
clean, interface honoured, fake implementation tested, bytes asserted against a recorded
expected sequence. **Whether real paper comes out of a real printer is untested by me.**
That is exactly what HARDWARE_TEST.md is for, and I will mark these items "not run"
rather than "working".

---

## 5. UI, from your design canvas

Taken from the Design artifact, which has 13 mobile screens at 390x844 and 9 tablet
screens at 1280x800. I will build to these tokens rather than inventing a theme.

| Token | Value | Used for |
| --- | --- | --- |
| Primary | `#0F4A33` deep green | nav rail, headers, selected state, bar charts |
| Ink | `#14231B` | body text |
| Accent | `#F4B400` amber | the one primary action per screen (Save, Charge) |
| Surface | `#FFFFFF` | cards, panels |
| Background | `#F4F6F1` | app background |
| Muted text | `#47564D` | secondary labels, help text |
| Border | `#A9B5AD` / `#D5DBD6` | inputs / card outlines |
| Soft green | `#DDEBE2` | selected chips, "Connected" badge |
| Danger | `#A3241C`, on `#FBE6E4`, text `#7E1B14` | cancel, cancelled badge |
| Radius | 12 px (10 and 14 px for small and large) | |
| Touch target | 44 px minimum, 52 to 68 px for primary buttons | matches the design |

Layout, as the design has it: 88 px nav rail plus content plus a 372 to 400 px bill or
detail panel on tablet; bottom-nav and full-screen steps on phone, driven by a width
breakpoint. Type scale 13/14/15/16/17/18/20/22/26/28/36 px.

**One conflict to settle, Q2 below:** the design uses **Anek Telugu** (a Google font), the
brief says bundle **Noto Sans Telugu**. Both must be bundled, not fetched, since the app
has to work offline.

---

## 6. Decisions I am making without asking

Stated so you can veto any of them, rather than discovering them later.

1. **PIN hashing: PBKDF2-HMAC-SHA256, 100k iterations, 16-byte random salt per user.**
   The brief says "salted PIN hashes". A bare salted SHA-256 over a 4-digit PIN is
   brute-forceable in milliseconds, since there are only 10,000 possibilities. PBKDF2 at
   100k iterations makes each guess cost ~50 ms, which with the lockout is adequate.
   Implemented on `crypto`, no new dependency. Argon2 would be better but needs a native
   dependency, which is not worth it here.
2. **Lockout: 5 failures, then 60 s, doubling to a 15 min cap, per user, stored in the DB**
   so it survives an app restart. Owner can always reset by reinstall-free DB access;
   there is no backdoor PIN.
3. **`round_off` is a bill-level field, not a line**, as in your data model. The printed
   receipt shows it as a line.
4. **SAC 9963 is one row in a `settings` key-value table**, not a constant, so it is
   configurable as the brief asks without a schema change.
5. **The fake printer writes `receipt-<invoice_no>.png` plus the raw byte stream as
   `.bin`** into the app documents directory, and golden tests write to `test/goldens/`.
6. **Turnover warnings are computed on demand from local bills**, not cached, and shown at
   80 % of the threshold (₹16 lakh, ₹1.2 crore) and again at 100 %.
7. **No `flutter_gen`, no `freezed`, no `go_router`.** Plain `Navigator`, hand-written
   `copyWith`. Fewer generators for someone new to Flutter to debug.
8. **Schema v1 is the full table set from your brief**, including `credit_note` as a
   `doc_type` value and `ref_bill_id`, both unused in Phase 1. Migration tests start from
   v1, so later phases have a real migration path.

---

## 7. Questions that blocked me: all four answered 2026-11-03

| # | Question | Answer |
| --- | --- | --- |
| Q1 | Install the toolchain? | **Yes, into `~/flutter` and `~/Android/Sdk`.** Install started. JDK 21 needs one sudo command from you, below. |
| Q2 | Which Telugu font? | **Anek Telugu**, matching the design canvas. One bundled family covers Latin and Telugu. |
| Q3 | Item vs outlet tax rate? | **Item wins.** Each line is taxed at its own `tax_class`; the outlet mode sets the default for new items. Receipts and tax summaries group by rate. |
| Q4 | Aggregator orders? | **No-tax chit marked "Aggregator order", and it consumes an invoice number.** Excluded from GST-payable, counted in turnover. |

### What Q3 changes

The tax engine groups lines by effective rate and emits one CGST/SGST block per rate, so
a bill can carry a 5 % block and an 18 % block at once. `round_off` is still computed once
on the bill total, not per rate block. The receipt template and the `sales by tax rate`
export both become rate-grouped. This is in the milestone 1 test suite:
a mixed-rate bill is one of the required cases.

### What Q4 changes

`order_type == aggregator` gets `doc_type = bill_of_supply` with an "Aggregator order"
header, prints no tax lines, and still draws from the normal device sequence. Reports
split "GST payable by the restaurant" from "total turnover", with aggregator GST in
neither the first nor excluded from the second. CA_REVIEW.md will ask their CA to confirm
this reading of section 9(5).

### The one command I need you to run

The Android Gradle Plugin does not support your JDK 25, so a JDK 21 has to go alongside
it. This needs sudo, so it is yours to run, not mine:

```bash
sudo apt-get install -y openjdk-21-jdk
```

Everything else installs into your home directory with no privileges.

<details>
<summary>The original four questions, as asked</summary>

**Q1. Can I install the toolchain, and where?**
Flutter 3.47.9 into `~/flutter`, Android SDK into `~/Android/Sdk`, plus `openjdk-21-jdk`
via apt (needs sudo; I will print the command for you to run rather than run it). About
4 to 5 GB of downloads. Nothing in the definition of done can be checked until this
exists, so this is the hard blocker. The alternative is that I write code I cannot
compile, analyze or test, which contradicts your rule 4.

**Q2. Anek Telugu or Noto Sans Telugu?**
Your design canvas uses Anek Telugu throughout. Your brief says to bundle Noto Sans
Telugu. Anek Telugu would match the design and covers Latin plus Telugu in one family.
Noto Sans Telugu is the more conservative choice with wider glyph coverage, and would
need a Latin companion. Either gets bundled as an asset, since nothing may be fetched at
runtime. I need one answer because it affects the golden receipt tests, which have to be
regenerated if the font changes.

**Q3. When the outlet is `regular_5`, what happens to an item whose `tax_class` is `gst18`?**
Your model has a tax mode per outlet *and* a tax class per item, and they can disagree.
Two readings:
  - **(a) Item wins.** `regular_5` and `regular_18` set the default for new items, but each
    line is taxed at its own class. This is how GST actually works: cooked food at 5 %,
    sealed bottled drinks or cigarettes at 18 %, on the same bill, with both rate blocks
    printed. More correct, slightly more complex receipt and reports.
  - **(b) Outlet wins.** The mode sets one rate for every taxed line, and `tax_class` only
    marks an item exempt (`non_gst`) or not. Simpler, but misstates the tax if the
    restaurant ever sells an 18 % item.

I lean to **(a)**, because it is the one that is still correct if they add a fridge of
soft drinks, and because the per-item `tax_class` field in your own model only earns its
place under (a). But (a) means receipts and tax summaries must group by rate, so I need
your answer before writing the tax engine and its tests.

**Q4. For an `aggregator` order, does the app print a customer bill, and does it show tax?**
The brief says to track them separately so their GST is not counted as tax the restaurant
must pay, which is right: on Swiggy and Zomato the aggregator is liable under section
9(5). But it does not say what to *print*. Options: no print at all (the aggregator
prints its own); a plain no-tax chit for the kitchen and the packet; or a full tax
invoice. I plan to default to **a no-tax chit marked "Aggregator order"**, excluded from
the GST-payable summary but included in turnover, unless you say otherwise. Confirm, since
it affects the invoice series: if aggregator orders do not get a printed invoice, should
they still consume an invoice number? I assume **yes**, so the series has no gaps.

</details>
---

## 8. Out of scope, as agreed

No server, sync, web dashboard, multiple devices, kitchen tickets, table management,
aggregator API integration, inventory, credit note screens, service charge or e-invoicing.
The `outbox` table is filled in Phase 1 but nothing reads it. `credit_note` and
`ref_bill_id` stay in the schema, unused.
