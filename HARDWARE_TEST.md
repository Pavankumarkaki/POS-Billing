# Hardware test checklist

Everything in this document is something **I could not test**. There is no
thermal printer, no Bluetooth adapter and no Android phone on the machine this
was built on. What is proven elsewhere is that the code compiles, honours the
`Printer` interface, and sends byte sequences that a real TCP socket accepts
and that match the ESC/POS spec. Whether paper comes out of your printer is
unknown until you run this.

Work through it in order. Each step says what to do, what should happen, and
what it means if it does not.

**Before you start:** take a photo of each receipt that comes out. If something
is wrong, the photo is far more useful to me than a description.

---

## What is already verified, so you can skip worrying about it

| Thing | How |
| --- | --- |
| The receipt layout, in every tax mode | 41 tests on the document, 10 sample images in `build/receipts/` |
| Telugu shaping and the ₹ sign | Rendered with the real bundled font and inspected |
| Mixed 5% and 18% on one bill | Arithmetic checked against the tax engine |
| The ESC/POS byte stream | Sent to a real TCP socket and asserted byte by byte |
| LAN connect, timeout and failure messages | 12 tests against a local server, including a wedged printer |
| A printer failure not losing a bill | Tested at the repository and the UI |
| Jobs never overlapping | Queue tested with out-of-order durations |

**Not verified at all:** Bluetooth, anything involving real paper, real cutting,
real reconnection after sleep, and print speed.

---

## 0. Before the printer

- [ ] Install the debug APK on the phone or tablet that will be used at the till.
- [ ] Complete first-run setup with the **real** restaurant details and the
      **real** 14-digit FSSAI number.
- [ ] Add five or six real menu items, including at least one with a Telugu
      name and one with a very long English name.

> If the app will not get past setup, the FSSAI number is the usual reason: it
> must be exactly 14 digits.

---

## 1. Bluetooth pairing

Do this in Android's own Settings, not in the app. The app deliberately does
not handle pairing: Android's dialog deals with the PIN properly and is
familiar.

- [ ] Printer switched on, paper loaded, cover closed.
- [ ] Android Settings → Bluetooth → pair the printer. The PIN is usually
      `0000` or `1234`; it is printed on the label underneath most units.
- [ ] Printer shows as **Paired** in Android Settings.

**Then in the app:** Settings → Printer → **Bluetooth**.

- [ ] A permission prompt appears the first time. Allow it.
- [ ] The printer appears in the **Paired printer** list, by name.
- [ ] Tap it. It shows a tick.

| If this goes wrong | What it means |
| --- | --- |
| No permission prompt at all | Permission was granted or denied earlier. Android Settings → Apps → Billing → Permissions → Nearby devices. |
| List is empty but the printer is paired | Bluetooth is off, or permission was denied. Tap **Look again** after fixing. |
| List is empty and permission was allowed | Tell me. This is the case I most expect to have got wrong. |

---

## 2. The test page over Bluetooth

Settings → Printer → **Print a test page**.

- [ ] Paper comes out.
- [ ] **The Telugu line reads correctly.** It should say చికెన్ దమ్ బిర్యానీ and
      మజ్జిగ · పెసరట్టు. Letters should be joined, not separate boxes or
      squares.
- [ ] **The ₹ sign appears** in `₹1,234.50`, not a box or a blank.
- [ ] **The ruler reaches both edges** of the paper without wrapping to a
      second line and without being cut off.
- [ ] The paper cuts automatically, leaving a small tab.

| Symptom | Try |
| --- | --- |
| Blank paper, printer whirrs | Turn on **Older printer mode (ESC \*)** and test again |
| Garbled dots or diagonal streaks | Same: ESC * mode |
| Telugu is boxes but English is fine | **Stop and tell me.** The bitmap path is not being used. |
| Ruler wraps to two lines | Paper width is set too wide. Switch to 58 mm. |
| Ruler is cut off at the right | Same: the printer is narrower than configured. |
| Ruler stops well short of the edge | Width set too narrow. Switch to 80 mm. |
| No cut, paper just advances | Turn **Cut paper after each bill** off; this printer has no cutter. |
| Nothing at all, app says "sent" | Out of paper, cover open, or a jam. The app cannot see any of these. |

> **Worth knowing:** "Test page sent" only means the printer accepted the
> bytes. Out of paper, cover open and jammed all look identical to the app.
> There is no way around this: the protocol has no acknowledgement.

---

## 3. A real bill over Bluetooth

- [ ] Ring up a bill with **three or more items**, one of them with a Telugu
      name and one with the long name.
- [ ] Charge it as cash.
- [ ] A receipt prints.

Check on the paper:

- [ ] Restaurant name, address and phone.
- [ ] **FSSAI number.** It must be there whatever the tax mode.
- [ ] GSTIN, if registered.
- [ ] `TAX INVOICE` if registered, `BILL OF SUPPLY` if composition or
      unregistered.
- [ ] Bill number in the form `A/2627/000001`.
- [ ] Each item with its quantity, Telugu name underneath, and amount.
- [ ] **The long item name wraps onto a second line rather than being cut off.**
- [ ] Subtotal, tax lines if applicable, round off if any, and TOTAL.
- [ ] Payment mode.
- [ ] Totals on paper **match the screen exactly**.

> If anything on the paper disagrees with the screen, stop and tell me. That is
> the most serious class of bug this app can have.

---

## 4. Reconnecting after the printer sleeps

This is the failure most likely to annoy you in daily use, and the one I am
least able to test.

- [ ] Print a bill. It works.
- [ ] **Leave the printer idle for ten minutes** so it sleeps. Do not touch
      the app.
- [ ] Ring up and charge another bill.

- [ ] It prints, perhaps after a short pause.

| If it fails | Note |
| --- | --- |
| Fails once, works on retry | Acceptable but not good. Tell me how long the pause was. |
| Fails repeatedly until the printer is power-cycled | **Tell me.** The reconnect logic is wrong. |
| App freezes | **Tell me immediately.** A hang at the counter is the worst outcome. |

Also try:

- [ ] Switch the printer **off**, charge a bill. The app should say the printer
      could not be reached, keep the bill, and offer **Try printing again**.
- [ ] **Confirm the bill is still saved.** Bills → it should be there with its
      number.
- [ ] Switch the printer on, tap **Try printing again**. It should print.
- [ ] Charge another bill straight away. It should get the **next** number, not
      reuse the failed one.

---

## 5. Walking out of range

- [ ] Start a bill at the counter.
- [ ] Walk far enough away that Bluetooth drops, or put the printer in another
      room behind a wall.
- [ ] Charge the bill.

- [ ] A clear message, not a crash or a hang.
- [ ] The bill is saved.
- [ ] Walking back and retrying prints it.

---

## 6. LAN printing

Only if the printer has an Ethernet or Wi-Fi port. Skip otherwise.

- [ ] Find the printer's IP address. Most print it on a self-test page, usually
      by holding the feed button while switching on.
- [ ] Printer and the till are on the **same Wi-Fi network**.
- [ ] Settings → Printer → **Wi-Fi (LAN)** → enter the IP → **Save address**.
- [ ] Print a test page. Same checks as section 2.
- [ ] Print a real bill.

| Message you may see | Meaning |
| --- | --- |
| "refused the connection" | Printer is on but not listening on port 9100, or busy with another device |
| "Check the printer is on the same Wi-Fi" | Wrong network or wrong IP |
| "did not answer" | Printer is off or asleep |
| "accepted the connection but stopped responding" | Usually a paper jam or open cover |

- [ ] Unplug the printer's network cable, charge a bill, confirm the message is
      sensible and the bill is saved.

---

## 7. Two jobs at once

The app queues print jobs so two never overlap, which matters because two
concurrent writes produce one corrupted receipt rather than two good ones.

- [ ] Charge a bill and, while it is printing, go to Bills and tap **Reprint**
      on an earlier one.
- [ ] Both receipts come out, one after the other, both complete.
- [ ] Neither is garbled or interleaved.

---

## 8. Speed, which decides whether this is usable

- [ ] Time from tapping **Save bill** to the paper being cut.

Write the number down. Under three seconds is fine. Over five and the queue at
the counter will notice, and I should look at the bitmap size or the strip
height.

- [ ] Ring up ten bills in a row at a realistic pace. Nothing should slow down
      or fall behind.

---

## 9. Paper and edge cases

- [ ] Let the paper run out mid-print. Note what the app says.
- [ ] Reload the paper and reprint from Bills. It should work.
- [ ] Open the cover mid-print. Note what the app says.
- [ ] Print a bill with **one** item. No layout oddities.
- [ ] Print a bill with **twenty** items. It should be one long receipt, not
      truncated.

---

## 10. Backup, restore and export

None of this can be tested without the phone. Three of the items below are
things I expect to break on at least one Android version, so please do them
before you rely on a backup existing.

### 10a. Where backups go

- [ ] Settings → **Open backup and export**. Note the folder shown.
- [ ] Tap **Back up now**. It should say how many bills went in and the file
      name. Note both.
- [ ] Find that file with a file manager, or over USB. Note whether you could.
      The default folder is `Android/data/<package>/files/backups`, which some
      file managers hide.
- [ ] Tap **Choose a folder** and pick something in Documents or on an SD card.
      **This is the one I most expect to fail.** Android 11 and later will hand
      the app a folder path it is not allowed to write to, and the app checks
      by writing a test file rather than assuming. Note exactly what it says.
- [ ] If it was refused, back up to the default folder instead and note that
      the owner has to copy files off the phone by hand.
- [ ] If it was accepted, tap **Back up now** again and confirm a file really
      appears in that folder.

### 10b. Whether the nightly backup actually runs

This is the one the app cannot know for itself, and the reason the last-backup
time is at the top of that screen rather than a "backup is on" tick.

- [ ] Leave **Back up automatically** on. Use the app normally for three days.
- [ ] Each morning, open the backup screen and note the **Last backup** line.
- [ ] If it says Today most mornings, WorkManager is running on this phone.
- [ ] If it stops moving, note the phone's make, model and Android version, and
      whether battery saver is on. Some manufacturers, Xiaomi, Oppo, Vivo and
      Samsung among them, kill background work for apps not on an allow list.
      The app has a second path that backs up when it starts if the last one is
      more than two days old, so backups still happen; they happen when the app
      is opened rather than overnight.
- [ ] Check `Settings → Apps → <the app> → Battery` and note whether it is set
      to Unrestricted. If the nightly job is not running, setting that is the
      first thing to try.

### 10c. Restore, which has to be tested before it is needed

Do this on a phone with bills you can afford to lose, or right after a backup
you have copied somewhere safe.

- [ ] Back up. Note the bill count it reports.
- [ ] Take two or three more bills.
- [ ] **Restore from a backup** → pick that file. It should say how many bills
      are in it and when the newest one is from, **before** asking for the PIN.
- [ ] Enter the wrong PIN once. It must be refused.
- [ ] Enter the right PIN. It should say to close the app completely and reopen
      it.
- [ ] Close the app from the recent-apps list, not just Back. Reopen it.
- [ ] The backup screen should show a Restore notice saying how many bills came
      back. The Bills tab should show the backed-up bills and **not** the two
      or three taken afterwards.
- [ ] Take one more bill. Its number must not repeat a number already on a
      printed bill.
- [ ] Confirm a file named `pos.replaced-<date>.sqlite` is in the app's
      documents folder, **and a `-wal` file beside it with the same name**.
      That pair is the database the restore replaced, kept rather than
      deleted, and it is how a restore from the wrong file is undone. The
      `-wal` holds the most recent bills, so a copy without it is not a
      complete one; this was wrong once and is worth checking.

**One thing the restore does not do yet, so you know before you rely on it.**
The picker was not exercised on the emulator: the restore there was tested by
putting the file in place directly. So step three above, picking the file
through Android's own file chooser, is genuinely untested, and it is the step
most likely to behave differently on a real phone.

### 10d. Restore onto a fresh install

The case that matters if the phone is lost or wiped.

- [ ] Copy a backup file onto a computer first. The app's default folder is
      deleted when the app is uninstalled, so a backup that only ever lived
      there will not survive this step.
- [ ] Uninstall the app. Install it again.
- [ ] It will ask for first-run setup. Complete it with anything.
- [ ] Settings → backup → **Restore from a backup**, pick the copied file,
      confirm, close and reopen.
- [ ] The real outlet details, menu, users and bills should all be back.
- [ ] Sign in with the **old** PIN, not the one typed during setup: the restore
      brings the old users back with it.

### 10e. The accountant's copy

- [ ] On the backup screen, pick **This month** and tap **Excel**. Note where
      it says it saved the file.
- [ ] Open that `.xlsx` on a computer, or in Google Sheets on the phone.
- [ ] Six tabs: Summary, Sales by tax rate, SAC summary, Document counts,
      Bills, Items.
- [ ] Telugu item names must read correctly, not as boxes or question marks.
- [ ] Click a money column and sum it. If it sums, the numbers are numbers; if
      it gives zero, they came out as text and I need to know.
- [ ] Tap **CSV** as well. Open one of the files in Excel and check the Telugu
      again: CSV is where encoding usually goes wrong.
- [ ] Show the Summary and SAC summary tabs to the CA and ask the questions in
      CA_REVIEW.md, particularly the SAC code. The export prints whatever is in
      the outlet settings and says in the sheet that it needs confirming.

---

## What to send me

For anything that fails:

1. A photo of the paper, or a note that nothing came out.
2. Exactly what the app said on screen.
3. Printer make and model.
4. Which connection, Bluetooth or LAN.
5. Whether a retry worked.

For anything in section 10:

1. The phone's make, model and Android version.
2. Exactly what the app said, word for word. The messages name the folder and
   the reason, and that is what tells me whether it is a permission problem or
   something else.
3. For section 10b, the Last backup line each morning, and whether the battery
   setting is Unrestricted.

The app also writes every print to the audit log, and in **Save to a file**
mode it writes both a `.png` of what it tried to print and a `.bin` of the
exact bytes it sent. If a printer behaves strangely, switching to file mode and
sending me those two files tells me whether the app or the printer is at fault.
