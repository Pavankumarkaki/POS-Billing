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

Never commit the keystore, `key.properties`, or any password. Both are already
in `.gitignore`.

Create a keystore once, outside the repository:

```bash
keytool -genkey -v -keystore ~/pos-release-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias pos
```

Create `android/key.properties`, also outside version control:

```properties
storePassword=<your password>
keyPassword=<your password>
keyAlias=pos
storeFile=/home/deepta/pos-release-key.jks
```

Then wire it into `android/app/build.gradle.kts` signing config and build:

```bash
flutter build apk --release              # one APK
flutter build apk --split-per-abi        # smaller, per architecture
```

Output lands in `build/app/outputs/flutter-apk/`.

**Back the keystore up somewhere safe.** Losing it means you can never ship an
update to an app installed from it; Android will refuse an APK signed by a
different key. Keep it off the device running the till.

> Not yet done: the signing config is not wired into `build.gradle.kts` yet,
> because no release build has been needed. The steps above are the standard
> ones and have **not** been run on this project.

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

## Backup and restore

> **Not written yet.** Backup is milestone 10. It will cover the nightly
> WorkManager job, choosing a folder, how to check the last successful backup
> time, and how to restore onto a replacement device.
>
> Worth knowing now: with no server, a backup that never leaves the device is
> one lost phone away from losing every record. Whatever the schedule ends up
> being, copying the backup file somewhere else is a manual step someone has to
> actually do. See [CA_REVIEW.md](CA_REVIEW.md) section 5.

## The documents

| File | What it is |
| --- | --- |
| [PLAN.md](PLAN.md) | Architecture, 11 milestones, decisions made without asking, package substitutions |
| [CA_REVIEW.md](CA_REVIEW.md) | What the restaurant's CA must confirm, and where the software is most likely wrong |
| [HARDWARE_TEST.md](HARDWARE_TEST.md) | Real-printer checklist: everything I could not test |

## Rules this codebase does not break

Listed because they are easy to break by accident and each has a test.

1. A paid bill is immutable. No amount or line is ever updated. No bill is ever
   deleted.
2. Cancelling keeps the invoice number and records status, reason and user.
3. Every bill line stores a snapshot of name, price and tax rate. Menu edits
   cannot change past bills or past reports.
4. Money is integer paise. Never a double.
5. The bill, its lines, its payments, the audit entry, the outbox entry and the
   sequence increment commit in one transaction.
6. The bill is saved before printing. A printer failure never loses a bill,
   changes its number or blocks the next sale.
7. Invoice numbers are unique within a financial year, at most 16 characters,
   formatted `A/2627/000123`.
8. The audit log is append-only.
9. Every bill shows the 14-digit FSSAI number in every tax mode, and billing is
   blocked until a valid one is saved.
10. Everything works with no internet.
