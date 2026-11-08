# Restaurant POS

Offline-first billing for a single restaurant. Android only, one device, one
80 mm thermal printer, no server and no internet.

Everything works in airplane mode. There is no login service, no analytics, no
cloud dependency and nothing that costs money to run.

**Status: Phase 1, milestones 1 and 2 of 11.** The tax engine and the database
are built and tested. There are no screens yet, so running the app shows a
placeholder. See [PLAN.md](PLAN.md) for the full milestone list.

---

## Setting up

You need the Flutter SDK, the Android SDK and a JDK. On this machine they are
already installed at `~/flutter` and `~/Android/Sdk`, with JDK 21 from apt.

```bash
# 1. Dependencies
flutter pub get

# 2. Code generation. REQUIRED: nothing compiles without it.
dart run build_runner build --delete-conflicting-outputs

# 3. Check it worked
flutter analyze
flutter test
```

Step 2 is not optional and is easy to forget. Drift generates `db.g.dart`, and
it is deliberately **not** committed: it is about 11,000 lines and would
dominate every diff. If you see hundreds of errors like `'Paise' isn't a type`
or `BillsCompanion isn't defined`, you have skipped step 2.

Re-run step 2 whenever you change anything in `lib/data/tables.dart`.

### JDK version

The Android Gradle Plugin does not support JDK 25, which is this machine's
system default. JDK 21 is pinned in Flutter's config and in `~/.bashrc`:

```bash
export JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
```

If a Gradle build fails with an error that does not obviously mention Java, the
JDK version is the first thing to check.

### The NDK, and why this project needs one

Most Flutter projects never touch the Android NDK. This one does, and the first
Android build will download about 1–2 GB of it.

The reason: `sqlite3_flutter_libs`, the package that used to ship prebuilt
SQLite binaries, is end-of-life. Its final release is literally `0.6.0+eol` and
its author says to use `sqlite3` 3.x instead. That version loads SQLite through
Dart **build hooks** (`hook/build.dart` in the `sqlite3` package), which compile
SQLite from C source at build time rather than shipping a prebuilt `.so`.
Compiling C for Android needs a C toolchain, which is the NDK.

Practical consequences:

- The first Android build is slow. Later builds reuse the NDK.
- A machine building a **release** APK needs the NDK too, not just a JDK.
- CI, if it is ever set up, must install the NDK.

## Running

```bash
flutter devices                     # what is available
flutter emulators                   # the AVDs you have
flutter emulators --launch <name>   # start one
flutter run                         # build, install, attach
```

In Android Studio: open the project root (the folder with `pubspec.yaml`, **not**
`android/`), pick the device in the toolbar dropdown, make sure the run
configuration says `main.dart`, and press Run.

If the run fails with `No Linux desktop project configured`, the device dropdown
is set to Linux. This project targets **Android only** by design, so there is no
desktop target. Change the dropdown to your emulator or phone. Do not accept
Android Studio's offer to add Linux desktop support.

While `flutter run` is attached: `r` hot reloads, `R` restarts, `q` quits.

### One build at a time

Android Studio runs Gradle automatically when the project is open. If you also
run `flutter build` or `flutter run` from a terminal, the two contend over the
same Gradle lock and both appear to hang rather than fail. If a build sits with
no output for several minutes, check whether a second one is running.

Orphaned Flutter processes can hold the same locks after a cancelled build:

```bash
pgrep -af flutter_tools      # look for ones minutes or hours old
kill <pid>                   # kill by PID, not by pattern
```

### Reading the database off a device

```bash
adb exec-out run-as com.deeptaai.restaurant_pos \
  cat /data/data/com.deeptaai.restaurant_pos/app_flutter/pos.sqlite > pos.sqlite
```

Two traps, both of which produce an **empty-looking database** and neither of
which is a real problem:

- Use `adb exec-out`, not `adb shell`. `adb shell` translates line endings and
  silently corrupts a binary file.
- Writes live in `pos.sqlite-wal` until SQLite checkpoints them, so copying only
  `pos.sqlite` can show nothing. Copy the `-wal` alongside it, or read the file
  after the app has closed cleanly.

## Testing

```bash
flutter test                                  # everything
flutter test test/core                        # the pure Dart logic, fast
flutter test test/data                        # database and transactions
flutter test --plain-name 'rollback'          # one group
flutter test --coverage
```

`test/core` has no Flutter, no database and no clock of its own, so it runs in
milliseconds. `test/core/core_is_pure_dart_test.dart` enforces that: it fails if
anything under `lib/core` imports Flutter, Drift, `dart:io` or calls
`DateTime.now()`.

### What the tests actually guarantee

| Area | Where |
| --- | --- |
| Tax, discounts, round-off, all four tax modes | `test/core/tax_test.dart` |
| Money arithmetic, exact parsing, Indian digit grouping | `test/core/money_test.dart` |
| Invoice numbering, financial-year rollover, 16-char limit | `test/core/invoice_no_test.dart` |
| Business-date boundaries either side of the 04:00 cutoff | `test/core/business_date_test.dart` |
| PIN hashing and the lockout | `test/core/pin_test.dart` |
| Owner and staff permissions, every permission enumerated | `test/core/permissions_test.dart` |
| Transaction rollback at each of the six writes | `test/data/sale_transaction_test.dart` |
| Bill immutability, cancellation, snapshots surviving menu edits | `test/data/immutability_test.dart` |
| Schema, constraints, money stored as INTEGER paise | `test/data/schema_test.dart` |

The rollback tests are the most important ones in the project, because they
cover the rule that a failed save must leave no partial bill and no skipped
invoice number. They were verified non-vacuous by mutation: removing the
transaction from `commitSale` makes all eight of them fail. If you change
`BillRepository`, do that mutation again rather than trusting a green run.

## How the code is laid out

```
lib/
  core/       pure Dart. No Flutter, no database, no clock.
  data/       Drift: tables, migrations, the one sale transaction.
  printing/   Printer interface, bitmap rendering, fake printer.   (milestone 6)
  features/   screens and Riverpod providers                       (milestone 3+)
  l10n/       English and Telugu strings
```

### Flutter notes for a backend developer

A few decisions that are not obvious coming from Go:

**Riverpod is dependency injection, not a UI framework.** A provider builds a
thing once and hands it to whatever asks, like wiring interfaces together in a
Go `main()`. Its value is that a screen depends on an *interface* (`Printer`)
which a test can swap for a fake.

**Drift is sqlc for Dart.** You write table definitions, it generates typed row
classes and query builders. The generated `db.g.dart` is the equivalent of
sqlc's output.

**`extension type Paise(int)` is a compile-time-only wrapper.** At runtime it is
an `int` with no allocation, but the type checker treats it as distinct, so
assigning a `double` to money will not compile. That is the "never use floating
point for money" rule enforced by the compiler instead of by review.

**`part` files share an import scope.** `db.g.dart` is `part of db.dart`, so it
resolves names using *that file's* imports. This is why `db.dart` imports things
it never visibly uses. Do not "tidy" those imports away.

**Generated code is not committed**, so a fresh clone needs `build_runner`
before it compiles.

## Building a release APK

The signing config is wired up and all three paths below were run on this
project. Never commit the keystore, `key.properties`, or any password: both
are already in `.gitignore`, in two places.

### Once: make a keystore

Outside the repository, somewhere you will not lose it:

```bash
keytool -genkey -v -keystore ~/pos-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias pos
```

Then `android/key.properties`, which is not in version control:

```properties
storePassword=<your password>
keyPassword=<your password>
keyAlias=pos
storeFile=/home/deepta/pos-release-key.jks
```

`storeFile` may be absolute, or relative to the `android/` directory.

### Then: build

```bash
flutter build apk --release --split-per-abi
```

Output lands in `build/app/outputs/flutter-apk/`. Measured on this project:

| What | Size | Use |
| --- | --- | --- |
| `app-arm64-v8a-release.apk` | 22.7 MB | **Almost every phone sold since 2017.** This is the one to install. |
| `app-armeabi-v7a-release.apk` | 20.3 MB | Older 32-bit phones |
| `app-x86_64-release.apk` | 24.2 MB | Emulators |
| `app-release.apk` (no split) | 63.5 MB | All three architectures in one file |

The unsplit APK is three times the size for no benefit on a specific phone,
and 63 MB is awkward to send over a phone connection. Build split unless you
genuinely do not know which phone it is going on.

### A release will not build without a key, on purpose

With no `key.properties`, `flutter build apk --release` stops with an error
naming the file. It does **not** fall back to the debug key, and the reason is
sharper in this app than in most:

An APK signed with the debug key cannot be upgraded by a properly signed one.
Android refuses the install with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, and the
only way out is to uninstall first. **Uninstalling deletes the default backup
folder**, because it lives in `Android/data/<package>/`, which Android removes
with the app. So a debug-signed release reaching the restaurant's phone can
cost them their bills. This was confirmed on a device, not assumed: the
`Android/data` folder is gone immediately after an uninstall.

`flutter build apk --debug` is unaffected and needs no key.

### Back the keystore up

Losing it means never being able to update an app installed from it, with the
same uninstall-and-lose-the-backups consequence. Keep a copy somewhere other
than the laptop that built it, and not on the till.

## Printer troubleshooting

Settings → Printer has three connection choices: **Bluetooth**, **Wi-Fi (LAN)**
and **Save to a file**. The last one writes receipts as images instead of
printing, which is how to work without a printer and how to diagnose one.

**The test page is the first thing to try.** It prints Telugu, the ₹ sign and a
full-width ruler. If the Telugu is boxes, the bitmap path is broken. If the
ruler wraps or is cut off, the paper width is wrong.

| Symptom | Cause and fix |
| --- | --- |
| Paper comes out blank, printer whirrs | Turn on **Older printer mode (ESC \*)**. Some printers do not understand `GS v 0`. |
| Garbled dots or diagonal streaks | Same: ESC * mode. |
| Ruler wraps to two lines | Width set too wide. Switch 80 mm → 58 mm. |
| Ruler stops short of the edge | Width set too narrow. |
| Telugu is boxes, English is fine | A real bug. The receipt should be an image, with no printer fonts involved. |
| No paired printers listed | Bluetooth off, or permission denied. Android Settings → Apps → Billing → Permissions → Nearby devices. |
| "refused the connection" (LAN) | Printer on but not listening on 9100, or busy with another device. |
| "same Wi-Fi" message | Wrong network or wrong IP. |
| "accepted the connection but stopped responding" | Usually a paper jam or an open cover. |
| App says sent, nothing printed | Out of paper, cover open or jammed. See below. |

**The app cannot tell whether paper came out.** ESC/POS over Bluetooth or port
9100 has no acknowledgement, so out of paper, cover open and jammed all look
exactly like success. "Test page sent" means the printer accepted the bytes and
nothing more.

**When a print fails, the bill is already saved.** It keeps its number, and the
failure offers a retry. You can also carry on and reprint later from Bills:
nothing is lost and the next sale is never blocked.

**To work out whether it is the app or the printer**, switch to **Save to a
file**. Each job writes a `.png` of what the app tried to print and a `.bin` of
the exact bytes it sent, both in the app's documents directory. If the PNG
looks right, the app is fine and the problem is the printer or its settings.

See [HARDWARE_TEST.md](HARDWARE_TEST.md) for the full checklist against real
hardware. Bluetooth has never been run against a real printer.

### Permissions the APK asks for, and why

Worth knowing, because three of them are not ours and look odd on a till app:

| Permission | Who asks | Why |
| --- | --- | --- |
| `BLUETOOTH_CONNECT` | us | Printing over Bluetooth. Requested at runtime. |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` | us | The same, on Android 11 and earlier. Capped at SDK 30. |
| `INTERNET`, `ACCESS_NETWORK_STATE` | us | LAN printing on port 9100. Nothing leaves the building: there is no server, no analytics and no cloud dependency. |
| `BLUETOOTH_SCAN` | `print_bluetooth_thermal` | **Declared but never used.** The app lists paired printers only and never scans. |
| `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE` | `workmanager` | The nightly backup. Neither is used by this app: no notification is posted and no foreground service is started. |

`INTERNET` is the one to be able to explain: it is there so the app can open a
TCP socket to a printer on the restaurant's own Wi-Fi, and for nothing else.

## Backup and restore

Owner only, under Settings → **Open backup and export**.

### What a backup is

One file: a complete copy of the database, named
`pos-backup-2026-11-04-0430.sqlite`. The newest fourteen are kept in the
destination folder and older ones are removed; bills themselves are never
touched by that, which is a different thing from the rule about never deleting
a bill.

Two details that are easy to get wrong and are worth knowing before changing
anything in `lib/data/backup_service.dart`:

- **The copy is made with `VACUUM INTO`, not a file copy.** The database runs
  in WAL mode, so recent writes live in `pos.sqlite-wal`, and a copy of
  `pos.sqlite` alone can be missing the last however-many bills while still
  opening perfectly cleanly. `test/data/backup_test.dart` proves a naive copy
  really would lose them, so if SQLite ever changes that, the test fails and
  the comment can go.
- **Every backup is verified before it counts.** The file is reopened, run
  through `PRAGMA integrity_check`, and its bill count compared with the
  source. A recorded success with no readable file behind it would be the worst
  outcome of this whole feature, because it reads as safe.

### Where it writes, and the thing to know about the default

The default folder is the app's own external files directory,
`Android/data/<package>/files/backups`. It needs no permission, works from the
background, and can be reached with a file manager or a USB cable.

**Android deletes it when the app is uninstalled.** A backup that only ever
lives there does not survive losing or wiping the phone, so the screen says so
and tells the owner to copy a file off the device now and then. This is the
manual step [CA_REVIEW.md](CA_REVIEW.md) section 5 is about: there is no
server, so nobody but the owner can do it.

Choosing another folder goes through the system picker. On Android 11 and later
that often hands back a path the app cannot actually write, so the app probes
the folder by writing a test file and **refuses to save a destination that
fails**, rather than accepting it and failing silently every night. If it is
refused, either grant all-files access or stay on the default folder.

### The nightly job, and why the screen does not trust it

`workmanager` registers a daily task aiming at 4:30 AM, just after the 4 AM
business-day cutoff so a run covers a whole trading day.

Android does not promise to run a periodic task on time, or at all. Doze,
battery saver, a phone switched off overnight and several manufacturers' own
task killers all interfere. So the app never presents "automatic backup is on"
as "a backup happened": the first thing on the backup screen is when the last
one actually succeeded, and it warns when that is more than two days ago or has
never happened.

There is a second path that does not involve `workmanager` at all.
`backupIfStale`, called at app start, backs up if the last good one is older
than two days. On a phone whose manufacturer has gutted background work, this
is the path that does the work, and backups then happen when the app is opened
rather than overnight. Section 10b of [HARDWARE_TEST.md](HARDWARE_TEST.md) is
how to find out which case a given phone is in.

### Restoring

A restore is **staged, not applied**. Replacing `pos.sqlite` under a live
connection is how a database gets corrupted, so the chosen file is copied to
`pos.sqlite.restore`, and `adoptStagedRestore` swaps it in at the next app
start, before anything opens the database. That call is the first thing in
`main()` for exactly that reason.

The database being replaced is renamed to `pos.replaced-<timestamp>.sqlite`
rather than deleted, so restoring the wrong file is itself recoverable. A
backup from an older schema version is fine: the migrations run when it is
opened. One from a newer version is refused with an explanation, because
migrating backwards is not a thing.

Restore asks for the owner's PIN even though the owner is already signed in,
for the same reason cancelling a bill does, and it says how many bills are in
the backup and when its newest bill is from **before** asking, so the cost is
visible before it is agreed to.

Test it before relying on it: section 10c of
[HARDWARE_TEST.md](HARDWARE_TEST.md). An untested restore is a file you hope
works.

## Export for the accountant

Same screen. Pick this month, last month or the financial year to date, then
Excel or CSV.

Six sheets: Summary, Sales by tax rate, SAC summary, Document counts, Bills and
Items. Excel gives one `.xlsx`; CSV gives a folder with one file per sheet.
Both land in `exports/` inside the backup folder, and the screen says where.

Three choices in there worth knowing:

- **Money is written as a number, not text.** An accountant opens the workbook
  and sums a column, and a text column sums to zero. This is the only place in
  the app where money becomes a floating-point value; everywhere else it is
  integer paise, and the conversion happens at the boundary in
  `lib/data/export_service.dart`.
- **CSV files carry a UTF-8 byte-order mark.** Without it, Excel on Windows
  opens them in the system code page and the Telugu item names come out as
  mojibake.
- **The SAC summary says its code needs confirming.** The app prints whatever
  is in the outlet settings, which defaults to `9963`, and returns usually want
  the six-digit code. That is item 1 of [CA_REVIEW.md](CA_REVIEW.md), and the
  sheet says so rather than presenting a default as settled.

## Changing the tax type, FSSAI number or GSTIN

Settings → Bill details. Owner only, like the rest of that tab.

These were set-once until recently, which meant a mistyped FSSAI number cost a
reinstall, and a reinstall costs the data and the default backup folder with
it. The realistic reason to change the tax type is the one the turnover
warning on the reports screen is for: an outlet crossing the ₹20 lakh
registration threshold part way through a year.

**A tax type change is dated.** `outlet.tax_mode` is only today's answer, so
every change also writes `tax_profile_history` with the business date it took
effect, and `OutletRepository.taxModeOn` reads it back. That is how a bill
from last October stays explicable after the outlet registers in November.
Two changes on the same day replace rather than accumulate, because that table
answers "which type applied on this date" and that has to be a single value;
both changes stay in the audit log.

**Bills already issued never move.** Every bill stores its own amounts, tax
splits and document type at the moment it was rung up, so this is safe by
construction rather than by care. The confirmation dialog says so, because it
is the thing an owner would reasonably worry about.

**Going unregistered clears the GSTIN**, because the receipt decides whether to
print one purely from whether one is stored, and an unregistered outlet
printing a GSTIN would be wrong. Composition keeps it: a composition dealer is
registered and their bill of supply carries it.

The name, address and phone are editable too, in the Restaurant card above
it. No confirmation there: correcting a phone number changes nothing about
what a bill *is*.

**Every bill snapshots its own header**, added in schema v3 when these became
editable. Before that, a reprint rebuilt the outlet header from the outlet
row, which was right only because the fields could not change. Once they
could, it was wrong in two ways that a test now pins:

* an old tax invoice reprinted after the outlet went unregistered came out
  with **no GSTIN on it**, which is not a valid tax invoice;
* an FSSAI correction stamped the new number onto every past bill.

So `bill` now carries the name, address, phone, FSSAI, GSTIN and SAC it was
printed with, and the print path reads those. Bills written before v3 have
none and fall back to the outlet row, which is exactly what they did before;
they are not backfilled, because stamping today's details onto them is the
bug being fixed. The footer and the UPI code stay live on purpose: the footer
is a message rather than part of the document, and the QR should route money
to the account the restaurant uses now.

## The documents

| File | What it is |
| --- | --- |
| [PLAN.md](PLAN.md) | Architecture, 11 milestones, decisions made without asking, package substitutions |
| [CA_REVIEW.md](CA_REVIEW.md) | What the restaurant's CA must confirm, and where the software is most likely wrong |
| [HARDWARE_TEST.md](HARDWARE_TEST.md) | Real-printer checklist: everything I could not test |

## Rules this codebase does not break

The ten rules from the brief, each with where it is enforced and where it is
tested. Checked against the code on 2026-11-04, not from memory.

| # | Rule | Enforced in | Tested in |
| --- | --- | --- | --- |
| 1 | A paid bill is immutable: no amount or line is ever updated, no bill is ever deleted | `data/bill_repository.dart` — the only `update` on `bill` is the cancel, and it writes status, reason and user only. There is no `delete` on `bill` anywhere | `test/data/immutability_test.dart` |
| 2 | Cancelling keeps the invoice number and records status, reason and user | `bill_repository.dart` `cancelBill` | `test/data/immutability_test.dart`, `test/widget/bills_screen_test.dart` |
| 3 | Every line stores a snapshot of name, price and tax rate, and every bill stores the outlet header it was printed with | `data/tables.dart`, `BillLines` for the lines and the `outlet*` columns on `Bills` for the header | `test/data/immutability_test.dart`, group "snapshots survive menu edits", and `test/printing/reprint_header_test.dart`, which reprints a bill after the outlet changes its tax type and licence numbers |
| 4 | Money is integer paise | `core/money.dart` `Paise`. The one exception is deliberate and at the boundary: `data/export_service.dart` converts to a real number so a spreadsheet column can be summed. Nothing reads it back | `test/core/money_test.dart`, `test/data/export_test.dart` |
| 5 | Bill, lines, payments, audit entry, outbox entry and sequence increment commit in one transaction | `bill_repository.dart` `commitSale` | `test/data/sale_transaction_test.dart` — a failure injected at each of the six writes leaves nothing behind |
| 6 | The bill is saved before printing; a printer failure never loses a bill, changes its number or blocks the next sale | `features/billing/payment_sheet.dart` — printing takes a bill id, which exists only after the commit | `test/widget/billing_screen_test.dart` (Next bill is enabled after a print failure) |
| 7 | Invoice numbers unique within a financial year, at most 16 characters, `A/2627/000123` | `core/invoice_no.dart`, plus `UNIQUE (device_id, fy, device_seq)` and `UNIQUE (fy, invoice_no)` in `data/tables.dart` | `test/core/invoice_no_test.dart`, `test/data/migration_test.dart` |
| 8 | The audit log is append-only | `data/` — there is no `update` or `delete` on `audit_log` anywhere in `lib/` | `test/data/immutability_test.dart` |
| 9 | Every bill shows the 14-digit FSSAI number in every tax mode, and billing is blocked until a valid one is saved | `bill_repository.dart` checks it **inside** the transaction against the stored row, not against what the UI believes. Settings can now edit it, and `outlet_repository.dart` applies the same rule there: a number that setup would have refused cannot be saved later either, and it cannot be blanked | `test/data/sale_transaction_test.dart`, `test/data/setup_test.dart`, `test/data/outlet_test.dart`, `test/core/receipt_test.dart` |
| 10 | Everything works with no internet | No HTTP client, no analytics, no cloud dependency. The only socket in `lib/` is `printing/lan_printer.dart`, which connects to a printer on the restaurant's own Wi-Fi | Run through on an emulator in airplane mode on 2026-11-04: sign in, bill, save, print, bills list, reports, backup and export all worked, with no network errors in the device log |

### Seeding an emulator

`test/seed_device_test.dart` builds a database with an outlet, an owner and a
menu item, using the app's own repositories. It is skipped in a normal run:

```bash
flutter test test/seed_device_test.dart --run-skipped
```

Then push `build/seed.sqlite` onto the device as `pos.sqlite.restore` and
restart the app, which lets the restore path install it. Much faster and less
error-prone than driving first-run setup through `adb input tap`, and the
result is a database the app really would have written.

### What the tests do not cover

Worth knowing before trusting a green suite:

- **Widget tests do not use the app's font.** `flutter test` runs with
  `--use-test-fonts`, so every layout and overflow test measures a fallback
  font rather than Anek Telugu. The fallback is wider, so the tests are
  conservative rather than permissive, but a layout judged only by them has
  not really been checked. Loading the real font in the harness was tried and
  reverted: the cached loader future deadlocked across test zones.
- **One sheet-width bug was fixed without a test that can fail.** The bill-saved
  panel rendered half the width of the phone, because a bottom sheet lays its
  child out with a loose width on a device and a tight one in a widget test. A
  test was written, measured 342 of 390 either way, and was removed rather than
  left looking like cover it does not give. The fix is verified on a device by
  measuring the pixels: the panel went from 536 px of 1080 to the full 1080.
- **Bluetooth printing is entirely unverified.** See HARDWARE_TEST.md.
- **The nightly backup running on a real phone is unverifiable from here**, which
  is why the backup screen reports the last success rather than the schedule.
- **The system folder picker and file picker were never driven.** Restores were
  tested by staging the file directly.
