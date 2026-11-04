/// Export for the accountant: CSV and Excel.
///
/// The shape of the export is built first, as plain [ExportSheet] values, and
/// only then encoded as CSV or as a workbook. That split is deliberate: the
/// part worth testing is which figures end up in which column, and testing
/// that through a zip file full of XML would prove very little. The encoders
/// are then thin enough to read in one sitting.
///
/// Money is written as a number, not as a string. An accountant opens the
/// workbook and sums a column, and a column of text sums to zero. Internally
/// money stays integer paise everywhere; the division by 100 happens here, at
/// the boundary, and nowhere else. See [ExportMoney].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xl;

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/money.dart';
import '../core/tax.dart';
import 'bills_query.dart';
import 'db.dart';
import 'reports_query.dart';

/// One cell. A small closed set, so an encoder cannot be handed something it
/// has no rule for.
sealed class ExportCell {
  const ExportCell();
}

class ExportText extends ExportCell {
  const ExportText(this.value);
  final String value;
}

class ExportNumber extends ExportCell {
  const ExportNumber(this.value);
  final int value;
}

/// An amount, carried as paise and written out as rupees.
///
/// The conversion to a double happens only in the workbook encoder. Rupee
/// amounts in a restaurant's year reach a few crore at most, which is far
/// inside the range a double represents to better than a paisa, and the CSV
/// path does not use a double at all: it formats the integer by hand.
class ExportMoney extends ExportCell {
  const ExportMoney(this.amount);
  final Paise amount;
}

class ExportDate extends ExportCell {
  const ExportDate(this.value);
  final DateTime value;
}

/// An empty cell, for spacing inside a sheet.
class ExportBlank extends ExportCell {
  const ExportBlank();
}

/// One sheet, which is also one CSV file.
class ExportSheet {
  const ExportSheet({required this.name, required this.rows});

  /// Also the CSV file name. Kept under 31 characters and free of `[]*?/\`,
  /// because Excel refuses a sheet name that breaks either rule and the
  /// failure is a corrupt-looking file rather than an error.
  final String name;

  final List<List<ExportCell>> rows;
}

/// Everything an export needs that is not in the report itself.
class ExportHeader {
  const ExportHeader({
    required this.outletName,
    required this.address,
    required this.phone,
    required this.fssaiNo,
    required this.gstin,
    required this.sacCode,
    required this.taxMode,
    required this.generatedAt,
  });

  final String outletName;
  final String address;
  final String phone;
  final String fssaiNo;
  final String? gstin;
  final String sacCode;
  final TaxMode taxMode;
  final DateTime generatedAt;
}

class ExportService {
  ExportService(this._db);

  final PosDatabase _db;

  /// Builds the sheets for a business-date range, inclusive at both ends.
  Future<List<ExportSheet>> build(BusinessDate from, BusinessDate to) async {
    final outlet = await _db.select(_db.outlets).getSingleOrNull();
    if (outlet == null) {
      throw StateError('Cannot export before first-run setup is complete.');
    }

    final report = await ReportsQuery(_db).forRange(from, to);
    final bills = await BillsQuery(_db).forRange(from, to);

    final header = ExportHeader(
      outletName: outlet.name,
      address: outlet.address,
      phone: outlet.phone,
      fssaiNo: outlet.fssaiNo,
      gstin: outlet.gstin,
      sacCode: outlet.sacCode,
      taxMode: outlet.taxMode,
      generatedAt: DateTime.now(),
    );

    return buildSheets(header: header, report: report, bills: bills);
  }
}

/// The sheets, from values alone. Pure, and therefore the part under test.
List<ExportSheet> buildSheets({
  required ExportHeader header,
  required SalesReport report,
  required List<BillListEntry> bills,
}) =>
    [
      _summarySheet(header, report),
      _byRateSheet(report),
      _sacSheet(header, report),
      _docCountsSheet(report),
      _billsSheet(bills),
      _itemsSheet(report),
    ];

ExportSheet _summarySheet(ExportHeader h, SalesReport r) {
  final rows = <List<ExportCell>>[
    [const ExportText('Outlet'), ExportText(h.outletName)],
    [const ExportText('Address'), ExportText(h.address)],
    [const ExportText('Phone'), ExportText(h.phone)],
    // The brief requires the FSSAI number on every bill in every tax mode, so
    // it belongs on the accountant's copy too.
    [const ExportText('FSSAI'), ExportText(h.fssaiNo)],
    [const ExportText('GSTIN'), ExportText(h.gstin ?? 'Not registered')],
    [const ExportText('Tax mode'), ExportText(_taxModeLabel(h.taxMode))],
    [const ExportText('SAC'), ExportText(h.sacCode)],
    const [ExportBlank()],
    [const ExportText('Period from'), ExportText(r.from.iso)],
    [const ExportText('Period to'), ExportText(r.to.iso)],
    // Said plainly, because it moves money between days and nobody reading a
    // spreadsheet would guess it.
    const [
      ExportText('Day boundary'),
      ExportText('A day runs 4 AM to 4 AM, so a 1 AM bill belongs to the '
          'night before'),
    ],
    [const ExportText('Generated'), ExportDate(h.generatedAt)],
    const [ExportBlank()],
    [const ExportText('Bills'), ExportNumber(r.billCount)],
    [const ExportText('Sales (total of bills)'), ExportMoney(r.total)],
    [const ExportText('Discount given'), ExportMoney(r.discount)],
    [const ExportText('Taxable value'), ExportMoney(r.taxable)],
    [const ExportText('CGST'), ExportMoney(r.cgst)],
    [const ExportText('SGST'), ExportMoney(r.sgst)],
    [const ExportText('Rounding'), ExportMoney(r.roundOff)],
    [const ExportText('Average bill'), ExportMoney(r.averageBill)],
    const [ExportBlank()],
    // Cancelled bills are counted and never added in. Stated here so the
    // accountant does not have to infer it from the numbers not adding up.
    [const ExportText('Cancelled bills'), ExportNumber(r.cancelledCount)],
    [
      const ExportText('Cancelled value (not in sales)'),
      ExportMoney(r.cancelledTotal),
    ],
    const [ExportBlank()],
    [const ExportText('Aggregator sales'), ExportMoney(r.aggregatorTotal)],
    [
      const ExportText('GST on aggregator sales'),
      ExportMoney(r.aggregatorTax),
    ],
    [const ExportText('GST you owe'), ExportMoney(r.gstPayable)],
  ];

  if (r.aggregatorTotal.value > 0) {
    // Section 9(5): the aggregator pays the GST on those orders, so it is out
    // of "GST you owe" while the turnover still counts. CA_REVIEW.md item 3.
    rows.add(const [
      ExportText('Note'),
      ExportText('Aggregator orders carry no GST on this bill: under section '
          '9(5) the aggregator pays it. The turnover still counts.'),
    ]);
  }

  if (h.taxMode == TaxMode.composition) {
    rows
      ..add(const [ExportBlank()])
      ..add([
        const ExportText('Composition levy at 5% of turnover'),
        ExportMoney(r.compositionTurnover),
      ])
      ..add(const [
        ExportText('Note'),
        ExportText('Composition levy is payable by the outlet and was never '
            'charged to a customer.'),
      ]);
  }

  return ExportSheet(name: 'Summary', rows: rows);
}

ExportSheet _byRateSheet(SalesReport r) {
  final rows = <List<ExportCell>>[
    const [
      ExportText('Rate'),
      ExportText('Taxable value'),
      ExportText('CGST'),
      ExportText('SGST'),
      ExportText('Total tax'),
    ],
  ];

  for (final rate in r.byRate) {
    rows.add([
      ExportText(rate.label),
      ExportMoney(rate.taxable),
      ExportMoney(rate.cgst),
      ExportMoney(rate.sgst),
      ExportMoney(rate.tax),
    ]);
  }

  if (r.byRate.isEmpty) {
    rows.add(const [ExportText('No taxable sales in this period')]);
  } else {
    rows.add([
      const ExportText('Total'),
      ExportMoney(r.taxable),
      ExportMoney(r.cgst),
      ExportMoney(r.sgst),
      ExportMoney(r.cgst + r.sgst),
    ]);
  }

  return ExportSheet(name: 'Sales by tax rate', rows: rows);
}

ExportSheet _sacSheet(ExportHeader h, SalesReport r) {
  final rows = <List<ExportCell>>[
    const [
      ExportText('SAC'),
      ExportText('Description'),
      ExportText('Rate'),
      ExportText('Taxable value'),
      ExportText('CGST'),
      ExportText('SGST'),
    ],
  ];

  for (final rate in r.byRate) {
    rows.add([
      ExportText(h.sacCode),
      const ExportText('Restaurant service'),
      ExportText(rate.label),
      ExportMoney(rate.taxable),
      ExportMoney(rate.cgst),
      ExportMoney(rate.sgst),
    ]);
  }

  if (r.byRate.isEmpty) {
    rows.add(const [ExportText('No taxable sales in this period')]);
  }

  // Said rather than implied. This app sells restaurant service and nothing
  // else, so there is one SAC for the whole outlet and the summary is the rate
  // table tagged with it. A kitchen that starts selling packaged goods would
  // need per-item SAC, and this sheet would be wrong rather than incomplete.
  rows
    ..add(const [ExportBlank()])
    ..add(const [
      ExportText('Note'),
      ExportText('Every item is restaurant service under one SAC, taken from '
          'the outlet settings. Confirm the code with your CA before filing: '
          'returns usually want the six-digit SAC, such as 996331 for '
          'restaurant service.'),
    ]);

  return ExportSheet(name: 'SAC summary', rows: rows);
}

ExportSheet _docCountsSheet(SalesReport r) {
  final rows = <List<ExportCell>>[
    const [ExportText('Document type'), ExportText('Count')],
  ];

  // Every type listed, including the ones at zero. A missing row reads as "we
  // did not record that", and a zero reads as "there were none"; for a
  // document count the difference matters.
  for (final type in DocType.values) {
    rows.add([
      ExportText(_docTypeLabel(type)),
      ExportNumber(r.docCounts[type] ?? 0),
    ]);
  }

  rows
    ..add(const [ExportBlank()])
    ..add([
      const ExportText('Of which cancelled'),
      ExportNumber(r.cancelledCount),
    ])
    ..add(const [
      ExportText('Note'),
      ExportText('A cancelled bill keeps its number and is counted above. '
          'Numbers are never reused and no bill is ever deleted.'),
    ]);

  return ExportSheet(name: 'Document counts', rows: rows);
}

ExportSheet _billsSheet(List<BillListEntry> bills) {
  final rows = <List<ExportCell>>[
    const [
      ExportText('Invoice no'),
      ExportText('Business date'),
      ExportText('Time'),
      ExportText('Type'),
      ExportText('Status'),
      ExportText('Order'),
      ExportText('Payment'),
      ExportText('Items'),
      ExportText('Subtotal'),
      ExportText('Discount'),
      ExportText('Taxable'),
      ExportText('CGST'),
      ExportText('SGST'),
      ExportText('Rounding'),
      ExportText('Total'),
      ExportText('Cancel reason'),
    ],
  ];

  for (final e in bills) {
    final b = e.bill;
    rows.add([
      ExportText(b.invoiceNo),
      ExportText(b.businessDate.iso),
      ExportDate(b.createdAt),
      ExportText(_docTypeLabel(b.docType)),
      ExportText(b.status == BillStatus.cancelled ? 'Cancelled' : 'Paid'),
      ExportText(_orderTypeLabel(b.orderType)),
      ExportText(e.paymentModes.map(_modeLabel).join(' + ')),
      ExportNumber(e.itemCount),
      ExportMoney(b.subtotal),
      ExportMoney(b.discount),
      ExportMoney(b.taxable),
      ExportMoney(b.cgst),
      ExportMoney(b.sgst),
      ExportMoney(b.roundOff),
      ExportMoney(b.total),
      ExportText(b.cancelReason ?? ''),
    ]);
  }

  if (bills.isEmpty) {
    rows.add(const [ExportText('No bills in this period')]);
  }

  return ExportSheet(name: 'Bills', rows: rows);
}

ExportSheet _itemsSheet(SalesReport r) {
  final rows = <List<ExportCell>>[
    const [
      ExportText('Item'),
      ExportText('Quantity'),
      ExportText('Value'),
    ],
  ];

  for (final i in r.byItem) {
    rows.add([
      ExportText(i.name),
      ExportNumber(i.qty),
      ExportMoney(i.total),
    ]);
  }

  if (r.byItem.isEmpty) {
    rows.add(const [ExportText('No items sold in this period')]);
  }

  rows
    ..add(const [ExportBlank()])
    ..add(const [
      ExportText('Note'),
      ExportText('Items are grouped by the name they were sold under, so a '
          'renamed item still reports under its old name for past sales.'),
    ]);

  return ExportSheet(name: 'Items', rows: rows);
}

/// One sheet as CSV text.
///
/// `\r\n` line endings, because the readers these files go to are Excel on
/// Windows and Tally, and both are happier with them.
String toCsv(ExportSheet sheet) {
  final rows = [
    for (final row in sheet.rows)
      [for (final cell in row) _csvValue(cell)],
  ];
  // Comma, not the semicolon that Csv.excel() uses: that preset is for
  // locales where the comma is the decimal separator, and this file's readers
  // are Excel and Tally in India, which expect a comma.
  return Csv(lineDelimiter: '\r\n').encode(rows);
}

/// The sheets as a single `.xlsx`.
Uint8List toXlsx(List<ExportSheet> sheets) {
  final book = xl.Excel.createExcel();

  // Sanitised once, here, and used for every lookup below. Doing it per call
  // is how you end up renaming the default sheet to one name and then writing
  // the rows into a second sheet under another, leaving a stray empty tab and
  // a name Excel refuses.
  final names = [for (final s in sheets) _safeSheetName(s.name)];

  // createExcel() starts with one sheet called Sheet1. Renaming it rather than
  // adding and deleting avoids a workbook with no sheets at all, which Excel
  // treats as corrupt.
  book.rename(book.getDefaultSheet()!, names.first);

  for (var i = 0; i < sheets.length; i++) {
    final target = book[names[i]];
    for (final row in sheets[i].rows) {
      target.appendRow([for (final cell in row) _xlsxValue(cell)]);
    }
  }

  book.setDefaultSheet(names.first);

  final bytes = book.encode();
  if (bytes == null) {
    throw StateError('The workbook could not be encoded.');
  }
  return Uint8List.fromList(bytes);
}

/// Excel refuses a sheet name over 31 characters or containing `[]:*?/\`, and
/// reports it as a damaged file rather than as an error. Every name in this
/// file is already within the rules; this is here so that adding one later
/// cannot produce a workbook that will not open.
String _safeSheetName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  return cleaned.length <= 31 ? cleaned : cleaned.substring(0, 31);
}

String _csvValue(ExportCell cell) => switch (cell) {
      ExportText(:final value) => value,
      ExportNumber(:final value) => value.toString(),
      // Formatted from the integer, so no float is involved on this path.
      ExportMoney(:final amount) => amount.plain,
      ExportDate(:final value) => _isoMinutes(value),
      ExportBlank() => '',
    };

xl.CellValue? _xlsxValue(ExportCell cell) => switch (cell) {
      ExportText(:final value) => xl.TextCellValue(value),
      ExportNumber(:final value) => xl.IntCellValue(value),
      // A real number, so the accountant can sum the column. This is the only
      // place in the app where money becomes a double.
      ExportMoney(:final amount) => xl.DoubleCellValue(amount.value / 100),
      ExportDate(:final value) => xl.TextCellValue(_isoMinutes(value)),
      ExportBlank() => null,
    };

/// `2026-11-04 21:35`. Local time, to the minute, which is what a till
/// receipt shows and therefore what reconciles against one.
String _isoMinutes(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

String _taxModeLabel(TaxMode mode) => switch (mode) {
      TaxMode.regular5 => 'Regular, 5% GST',
      TaxMode.regular18 => 'Regular, 18% GST',
      TaxMode.composition => 'Composition scheme',
      TaxMode.unregistered => 'Not registered for GST',
    };

String _docTypeLabel(DocType type) => switch (type) {
      DocType.invoice => 'Tax invoice',
      DocType.billOfSupply => 'Bill of supply',
      DocType.creditNote => 'Credit note',
    };

String _orderTypeLabel(OrderType type) => switch (type) {
      OrderType.dine => 'Dine in',
      OrderType.takeaway => 'Takeaway',
      OrderType.aggregator => 'Online',
    };

String _modeLabel(PaymentMode m) => switch (m) {
      PaymentMode.cash => 'Cash',
      PaymentMode.upi => 'UPI',
      PaymentMode.card => 'Card',
      PaymentMode.aggregator => 'Aggregator',
      PaymentMode.credit => 'Credit',
    };

/// UTF-8 with a byte-order mark.
///
/// Without the mark, Excel on Windows opens a UTF-8 CSV in the system code
/// page and the Telugu item names come out as mojibake. The mark is three
/// bytes and fixes it.
Uint8List csvBytes(String csv) =>
    Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
