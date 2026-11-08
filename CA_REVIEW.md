# What the restaurant's CA must confirm

This app makes tax decisions. I am not a chartered accountant and this is not
tax advice. Everything below is a choice the software currently makes, written
plainly enough that your CA can say yes or no to each one.

Take this document to them, get the answers, and tell me which ones to change.
Where an answer changes behaviour, the setting or the file to change is named so
nothing has to be hunted for.

**Nothing here is urgent until the app is used for real billing.** But all of it
should be settled before the first bill is given to a customer, because invoice
numbering and tax treatment are hard to correct afterwards.

---

## 1. SAC code: is 9963 right, and at what depth?

**What the app does now.** Prints `SAC 9963` on every tax invoice. It is stored
as a setting (`setting` table, key `sac_code`), so it can be changed without a
new build.

**Why it needs confirming.** 9963 is the two-level heading for "Accommodation,
food and beverage services". The six-digit codes underneath it are more
specific, for example 996331 for restaurant services. Which one is expected on
an invoice depends on turnover and on what the CA files.

**Ask them:**
- Should the printed code be `9963`, or a six-digit code such as `996331`?
- Does it need to appear per line, or once on the bill? The app prints it once.
- Should it appear on a Bill of Supply as well, or only on a tax invoice? The
  app currently prints it **only on tax invoices**.

**If the answer differs:** change the `sac_code` setting in Settings. No code
change needed unless they want it per line.

---

## 2. Invoice series: is one series per device acceptable?

**What the app does now.** `A/2627/000123`, where `A` is the device letter,
`2627` is financial year 2026-27, and the sequence restarts at 1 each April.
Phase 1 runs on one device, so there is one series, `A`.

The number is at most 16 characters, consecutive within the financial year, and
never reused. A cancelled bill keeps its number; the series has no gaps.

**Why it needs confirming.** Rule 46 of the CGST Rules wants a consecutive
serial number, unique for a financial year, up to 16 characters, of letters,
digits, slash and hyphen. I believe this format satisfies that, but your CA
should confirm the shape and in particular the device-letter prefix, which is
there so a second device can be added later without renumbering.

**Ask them:**
- Is `A/2627/000123` acceptable as the document number?
- Is a per-device prefix acceptable, or do they want one shared series across
  devices? **This matters now**, because changing it later means a new series.
- Aggregator orders currently **take a number from the same series**. Should
  they instead have their own series, or no number at all? (See section 3.)
- Does the restaurant need a separate series for Bills of Supply versus tax
  invoices? The app currently uses **one series for both**, distinguished by the
  `doc_type` on each bill.

**Sharper now that the tax type can be changed after setup.** It used to be
fixed at first-run, so in practice a financial year held one document type. The
owner can now switch, which is what an outlet crossing the registration
threshold in, say, November has to do. From that day the same series carries
bills of supply up to the switch and tax invoices after it, with no gap and no
restart. Verified on a device: numbering continues across the change rather
than repeating a number already on a printed bill.

That is the behaviour I believe is right, and it is the point on which I would
most like to be told otherwise, because it is cheap to change now and expensive
once a year of bills exists.

**Ask them as well:**
- When an outlet registers mid-year, should the tax invoices start a **new
  series**, or continue the existing one as the app does?
- The change is recorded with its effective date in `tax_profile_history`, so
  the split can be reported either way. Do they want that history in the
  accountant's export? It is not in it today.

**If the answer differs:** the device letter is set during first-run setup. A
separate series per document type would be a schema and code change, so flag it
before billing starts.

---

## 3. Aggregator orders: who pays the GST, and what gets printed?

**What the app does now.** An order marked `aggregator`:
- prints a chit headed "Aggregator order" with **no tax lines**
- is recorded as `doc_type = bill_of_supply`
- **takes an invoice number** from the normal series
- is **excluded** from the "GST payable by the restaurant" figure in reports
- is **included** in total turnover

**Why it needs confirming.** Under section 9(5) of the CGST Act and the
notifications under it, for restaurant service supplied through an e-commerce
operator, the operator (Swiggy, Zomato) pays the GST, not the restaurant. So
charging and remitting it again at the restaurant's end would be wrong. That is
the reading the app implements.

But the consequences are worth a second opinion, particularly:

**Ask them:**
- Is excluding aggregator GST from the restaurant's own liability correct for
  this restaurant's registration?
- Should aggregator sales count toward the **composition** turnover limit, or
  toward the **registration** threshold? The app currently counts them in
  turnover for both warnings. This is the question I am least sure about.
- Can a composition-scheme dealer supply through an aggregator at all? There are
  restrictions on composition dealers supplying through e-commerce operators,
  and if they apply, the combination of `composition` tax mode plus aggregator
  orders may be something the restaurant must not do. **If so, tell me and I
  will block the combination in the app.**
- Should an aggregator order print anything at all for the customer?

---

## 4. Composition scheme: eligibility and the wording on the bill

**What the app does now.** In `composition` mode:
- the document is headed **BILL OF SUPPLY**, not Tax Invoice
- **no tax is shown and none is charged**; the customer pays the menu price
- a 5% turnover figure is computed and stored per bill for the owner's own
  reporting, and appears in reports. It is never printed and never charged.
- the declaration printed is:

  > Composition taxable person, not eligible to collect tax on supplies.

**Why it needs confirming.** Rule 5(1)(f) of the CGST Rules requires a
composition dealer to carry a declaration to that effect at the top of every
bill of supply. The exact wording above is the conventional one, but the CA
should approve the words that go on the paper, and whether they want it in
Telugu as well as English.

**Ask them:**
- Is that declaration wording acceptable, exactly as printed?
- Should it also appear in Telugu? The app can print both.
- Is the restaurant actually eligible for the composition scheme, given its
  turnover and whether it supplies through aggregators (section 3)?
- The composition rate used for the turnover figure is **5%**, the restaurant
  rate. Confirm it is 5% and not 1%, which applies to traders and
  manufacturers.
- Is the turnover figure wanted on the restaurant's **taxable turnover** or on
  **total turnover including exempt items**? The app currently computes 5% of
  the taxable value of the bill.

**If the answer differs:** the declaration text lives in the receipt renderer
and the Telugu translation file. The rate is in `lib/core/tax.dart`.

---

## 5. Record retention: how long, and in what form?

**What the app does now.**
- Every bill, line, payment and audit entry is kept **forever** in the local
  SQLite database. Nothing is deleted or archived, by design.
- Backups run nightly to a folder the owner picks, with the last successful
  backup time shown in the app and a warning when it is stale.
- Export produces CSV and Excel files for the accountant, including sales by
  tax rate, a SAC summary and document counts.
- Everything lives on **one device**. There is no server and no cloud copy.

**One detail now that the backup is built, because it looks worse than it is.**
Only the newest **fourteen** backup files are kept; older ones are removed so
the folder does not grow without end. That is not a fourteen-day retention
policy. Retention is satisfied by the database itself, which holds every bill
ever written and from which nothing is ever deleted; the backups exist to
recover from a lost or broken phone, not to be the record. Worth saying out
loud to the CA, because "we keep two weeks of backups" and "we keep two weeks
of records" sound alike and only one of them would be a problem.

**Why it needs confirming.** Section 36 of the CGST Act requires records to be
kept for 72 months (six years) from the due date of the annual return. The app
keeps them indefinitely, which is more than enough, but only as long as the
device and its backups survive.

**Ask them:**
- Is a nightly local backup to a folder on the device adequate, or do they want
  a copy taken off the device on some schedule? **Phase 1 has no cloud sync**,
  so taking a copy off the device is a manual step someone must actually do.
- Should exports be kept per month, per quarter, or per year?
- Do they need the audit log itself in the export, or only the bills?
- Is there a retention requirement on the **audit log** specifically, separate
  from the bills?

**The honest risk to raise with them:** if this phone or tablet is lost and the
backup folder is on the same device, the records are gone. Whatever they say
about retention, the practical answer almost certainly involves copying the
backup file somewhere else regularly. The app will tell the owner how old the
last backup is, but it cannot make the copy leave the building.

---

## 6. Smaller things worth a yes or no

| Thing | What the app does | Confirm |
| --- | --- | --- |
| FSSAI number | 14 digits, printed on **every** bill in every tax mode. Billing is blocked until a valid one is saved. | That it must appear on a Bill of Supply too, not only a tax invoice. |
| Rounding | Tax computed to the paisa per line, then the bill total rounded to the nearest rupee with the difference on a **Round off** line. | That a round-off line is acceptable and that nearest-rupee, not always-up, is right. |
| Discounts | Taken off **before** tax, so tax is on the discounted value. Bill-level discounts are spread across lines in proportion to value. | That pre-tax discounting is right for their invoices. |
| Mixed rates | A bill can carry 5% and 18% lines at once, with a separate CGST/SGST block printed per rate. | That per-rate blocks are the expected presentation. |
| Tax-inclusive prices | Supported. With inclusive prices the customer pays the menu price and tax is backed out of it. | Which way this restaurant prices, and whether the invoice must state "prices inclusive of tax". |
| Cancelled bills | Keep their number, are marked `cancelled` with a reason and the user, and are **excluded from sales totals** but still listed. | That exclusion from totals while remaining on record is what they expect. |
| Reprints | Marked **DUPLICATE** and logged with user and time. | That "DUPLICATE" is sufficient marking. |
| Credit notes | **Not implemented.** The schema has `credit_note` and `ref_bill_id` for later. | Whether the restaurant needs credit notes before this goes live. If yes, that is a scope change. |
| Turnover warnings | Owner warned at 80% and 100% of ₹20 lakh (unregistered) and ₹1.5 crore (composition). | That those are the right thresholds for a restaurant in Andhra Pradesh. |
| E-invoicing | **Not implemented and out of scope.** | That the restaurant is below the e-invoicing turnover threshold. If not, that is a scope change. |
| Service charge | **Not implemented and out of scope.** | That they do not levy one. |

---

## 7. What I am least confident about

If your CA has limited time, these three are where the software is most likely
to be wrong:

1. **Whether aggregator turnover counts toward the composition limit and the
   registration threshold** (section 3). The app counts it. I could not satisfy
   myself this is right.
2. **Whether a composition dealer may supply through an aggregator at all**
   (section 3). If not, the app currently allows a combination it should
   forbid.
3. **Whether one invoice series may cover both tax invoices and bills of
   supply** (section 2). The app uses one. Separating them later is painful.

---

## 8. What the app deliberately does not do

So nobody assumes otherwise:

- **Should the document count include cancelled documents?** The export
  currently counts **paid** documents by type, and shows cancelled ones on a
  separate line beneath. On the test device that reads as 8 bills of supply
  plus 1 cancelled, from 9 numbers issued. The alternative reading is that 9
  documents were issued and one was later cancelled. Both are defensible; the
  numbers are all there either way, but which one they want as "the count"
  changes the top line.
- No GSTR filing, no return preparation, no e-invoicing, no e-way bills.
- No integration with Swiggy or Zomato. Aggregator orders are keyed in by hand.
- No TDS, TCS or reverse-charge handling.
- No credit notes, no service charge, no inventory, no multi-outlet.
- No accountant login. Data reaches the CA as exported CSV and Excel files.

The app records sales accurately and prints a compliant document. Everything
downstream of that is the CA's work, not the app's.
