/// Export for the accountant.
///
/// Two kinds of test here. The first builds the sheets from values and checks
/// which figures land in which column, which is the part that would be wrong
/// in a way nobody notices until a return is filed. The second encodes a real
/// workbook and reads it back, because an .xlsx that will not open is a
/// failure the sheet-level tests cannot see.
library;

import 'dart:convert';

import 'package:excel/excel.dart' as xl;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/export_service.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/reports_query.dart';
import 'package:restaurant_pos/data/setup_repository.dart';

ExportHeader header({
  TaxMode mode = TaxMode.regular5,
  String sac = '9963',
  String? gstin = '37ABCDE1234F1Z5',
}) =>
    ExportHeader(
      outletName: 'Annapurna Mess',
      address: 'Main Road, Guntur',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      gstin: gstin,
      sacCode: sac,
      taxMode: mode,
      generatedAt: DateTime(2026, 11, 4, 21, 35),
    );

SalesReport report({
  Paise total = const Paise(100800),
  int billCount = 4,
  Paise taxable = const Paise(96000),
  Paise cgst = const Paise(2400),
  Paise sgst = const Paise(2400),
  Paise roundOff = Paise.zero,
  Paise discount = Paise.zero,
  int cancelledCount = 0,
  Paise cancelledTotal = Paise.zero,
  List<ModeTotal> byMode = const [],
  List<ItemTotal> byItem = const [],
  List<RateTotal>? byRate,
  Paise aggregatorTotal = Paise.zero,
  Paise aggregatorTax = Paise.zero,
  Paise compositionTurnover = Paise.zero,
  Map<DocType, int> docCounts = const {DocType.invoice: 4},
}) =>
    SalesReport(
      from: const BusinessDate(2026, 10, 1),
      to: const BusinessDate(2026, 10, 31),
      total: total,
      billCount: billCount,
      taxable: taxable,
      cgst: cgst,
      sgst: sgst,
      roundOff: roundOff,
      discount: discount,
      cancelledCount: cancelledCount,
      cancelledTotal: cancelledTotal,
      byDay: const [],
      byMode: byMode,
      byItem: byItem,
      byRate: byRate ??
          [
            RateTotal(
              rateBp: 500,
              taxable: taxable,
              cgst: cgst,
              sgst: sgst,
            ),
          ],
      aggregatorTotal: aggregatorTotal,
      aggregatorTax: aggregatorTax,
      compositionTurnover: compositionTurnover,
      docCounts: docCounts,
    );

/// The sheet with that name, or a failure naming what was there instead.
ExportSheet sheetNamed(List<ExportSheet> sheets, String name) {
  final hit = sheets.where((s) => s.name == name);
  expect(hit, hasLength(1),
      reason: 'sheets present: ${sheets.map((s) => s.name).join(', ')}');
  return hit.single;
}

/// Every cell of a sheet as the CSV encoder would write it, for searching.
List<List<String>> cells(ExportSheet sheet) => [
      for (final row in sheet.rows) [for (final c in row) csvCell(c)],
    ];

String csvCell(ExportCell cell) => switch (cell) {
      ExportText(:final value) => value,
      ExportNumber(:final value) => value.toString(),
      ExportMoney(:final amount) => amount.plain,
      ExportDate(:final value) => value.toIso8601String(),
      ExportBlank() => '',
    };

/// The row whose first cell is [label].
List<String> rowLabelled(ExportSheet sheet, String label) {
  final hit = cells(sheet).where((r) => r.isNotEmpty && r.first == label);
  expect(hit, hasLength(1), reason: 'no single row labelled "$label"');
  return hit.single;
}

void main() {
  group('the sheets that are produced', () {
    test('are the ones the brief asks for, and in a sensible order', () {
      final sheets = buildSheets(
        header: header(),
        report: report(),
        bills: const [],
      );

      expect(
        sheets.map((s) => s.name),
        [
          'Summary',
          'Sales by tax rate',
          'SAC summary',
          'Document counts',
          'Bills',
          'Items',
        ],
      );
    });

    test('every sheet name is one Excel will accept', () {
      // Excel refuses a name over 31 characters or containing []:*?/\ and
      // reports it as a damaged workbook rather than as an error.
      for (final sheet in buildSheets(
        header: header(),
        report: report(),
        bills: const [],
      )) {
        expect(sheet.name.length, lessThanOrEqualTo(31), reason: sheet.name);
        expect(sheet.name, isNot(matches(r'[\[\]:*?/\\]')), reason: sheet.name);
      }
    });

    test('no sheet is empty, even with no sales at all', () {
      // An empty sheet reads as a broken export. Each one has to say that
      // there were no sales rather than show nothing.
      final sheets = buildSheets(
        header: header(),
        report: report(
          total: Paise.zero,
          billCount: 0,
          taxable: Paise.zero,
          cgst: Paise.zero,
          sgst: Paise.zero,
          byRate: const [],
          docCounts: const {},
        ),
        bills: const [],
      );

      for (final sheet in sheets) {
        expect(sheet.rows, isNotEmpty, reason: sheet.name);
        expect(
          cells(sheet).expand((r) => r).any((c) => c.trim().isNotEmpty),
          isTrue,
          reason: '${sheet.name} has rows but nothing in them',
        );
      }
    });
  });

  group('the summary sheet', () {
    test('carries the identifiers a return needs', () {
      final s = sheetNamed(
        buildSheets(header: header(), report: report(), bills: const []),
        'Summary',
      );

      expect(rowLabelled(s, 'Outlet')[1], 'Annapurna Mess');
      expect(rowLabelled(s, 'FSSAI')[1], '12345678901234');
      expect(rowLabelled(s, 'GSTIN')[1], '37ABCDE1234F1Z5');
      expect(rowLabelled(s, 'SAC')[1], '9963');
      expect(rowLabelled(s, 'Tax mode')[1], contains('5%'));
    });

    test('says "Not registered" rather than leaving GSTIN blank', () {
      // A blank cell reads as a missing figure. "Not registered" is a fact.
      final s = sheetNamed(
        buildSheets(
          header: header(mode: TaxMode.unregistered, gstin: null),
          report: report(),
          bills: const [],
        ),
        'Summary',
      );
      expect(rowLabelled(s, 'GSTIN')[1], 'Not registered');
    });

    test('states the 4 AM day boundary', () {
      final s = sheetNamed(
        buildSheets(header: header(), report: report(), bills: const []),
        'Summary',
      );
      expect(rowLabelled(s, 'Day boundary')[1], contains('4 AM'));
    });

    test('keeps the cancelled value out of sales and labels it as such', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(cancelledCount: 2, cancelledTotal: Paise.fromRupees(504)),
          bills: const [],
        ),
        'Summary',
      );

      expect(rowLabelled(s, 'Cancelled bills')[1], '2');
      final cancelled = rowLabelled(s, 'Cancelled value (not in sales)');
      expect(cancelled[1], '504.00');
      expect(rowLabelled(s, 'Sales (total of bills)')[1], '1008.00');
    });

    test('reports the money in rupees, not paise', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(total: const Paise(123456)),
          bills: const [],
        ),
        'Summary',
      );
      expect(rowLabelled(s, 'Sales (total of bills)')[1], '1234.56');
    });

    test('a negative rounding is carried through with its sign', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(roundOff: const Paise(-40)),
          bills: const [],
        ),
        'Summary',
      );
      expect(rowLabelled(s, 'Rounding')[1], '-0.40');
    });

    group('aggregator orders', () {
      test('their GST is excluded from what is owed, and the reason is '
          'written down', () {
        final s = sheetNamed(
          buildSheets(
            header: header(),
            report: report(
              aggregatorTotal: Paise.fromRupees(1000),
              aggregatorTax: Paise.zero,
            ),
            bills: const [],
          ),
          'Summary',
        );

        expect(rowLabelled(s, 'Aggregator sales')[1], '1000.00');
        expect(
          rowLabelled(s, 'Note')[1],
          contains('9(5)'),
          reason: 'an accountant should not have to guess why',
        );
      });

      test('no note when there were none', () {
        final s = sheetNamed(
          buildSheets(header: header(), report: report(), bills: const []),
          'Summary',
        );
        expect(
          cells(s).where((r) => r.isNotEmpty && r.first == 'Note'),
          isEmpty,
        );
      });
    });

    group('the composition scheme', () {
      test('shows the levy and says it was never charged to a customer', () {
        final s = sheetNamed(
          buildSheets(
            header: header(mode: TaxMode.composition, gstin: '37ABCDE1234F1Z5'),
            report: report(compositionTurnover: Paise.fromRupees(50)),
            bills: const [],
          ),
          'Summary',
        );

        expect(
          rowLabelled(s, 'Composition levy at 5% of turnover')[1],
          '50.00',
        );
        expect(
          cells(s).expand((r) => r).join(' '),
          contains('never charged to a customer'),
        );
      });

      test('no levy row for a regular outlet', () {
        final s = sheetNamed(
          buildSheets(header: header(), report: report(), bills: const []),
          'Summary',
        );
        expect(
          cells(s).any((r) => r.isNotEmpty && r.first.contains('Composition')),
          isFalse,
        );
      });
    });
  });

  group('sales by tax rate', () {
    test('one row per rate, with the split and a total', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(
            taxable: const Paise(150000),
            cgst: const Paise(5250),
            sgst: const Paise(5250),
            byRate: const [
              RateTotal(
                rateBp: 500,
                taxable: Paise(100000),
                cgst: Paise(2500),
                sgst: Paise(2500),
              ),
              RateTotal(
                rateBp: 1800,
                taxable: Paise(50000),
                cgst: Paise(2750),
                sgst: Paise(2750),
              ),
            ],
          ),
          bills: const [],
        ),
        'Sales by tax rate',
      );

      expect(cells(s).first,
          ['Rate', 'Taxable value', 'CGST', 'SGST', 'Total tax']);
      expect(rowLabelled(s, '5%'), ['5%', '1000.00', '25.00', '25.00', '50.00']);
      expect(
          rowLabelled(s, '18%'), ['18%', '500.00', '27.50', '27.50', '55.00']);
      expect(rowLabelled(s, 'Total'),
          ['Total', '1500.00', '52.50', '52.50', '105.00']);
    });

    test('the total row adds up to the rate rows', () {
      // Guards against the total being taken from a different place in the
      // report than the rows above it, which is how a report comes out
      // internally inconsistent.
      final s = sheetNamed(
        buildSheets(
          header: header(
          ),
          report: report(
            taxable: const Paise(150000),
            cgst: const Paise(5250),
            sgst: const Paise(5250),
            byRate: const [
              RateTotal(
                rateBp: 500,
                taxable: Paise(100000),
                cgst: Paise(2500),
                sgst: Paise(2500),
              ),
              RateTotal(
                rateBp: 1800,
                taxable: Paise(50000),
                cgst: Paise(2750),
                sgst: Paise(2750),
              ),
            ],
          ),
          bills: const [],
        ),
        'Sales by tax rate',
      );

      final rateRows = cells(s)
          .skip(1)
          .where((r) => r.isNotEmpty && r.first.endsWith('%'))
          .toList();
      double sum(int column) =>
          rateRows.fold(0, (a, r) => a + double.parse(r[column]));

      final total = rowLabelled(s, 'Total');
      expect(double.parse(total[1]), sum(1));
      expect(double.parse(total[2]), sum(2));
      expect(double.parse(total[3]), sum(3));
    });

    test('no total row when there is nothing to total', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(byRate: const []),
          bills: const [],
        ),
        'Sales by tax rate',
      );
      expect(cells(s).any((r) => r.isNotEmpty && r.first == 'Total'), isFalse);
      expect(cells(s).expand((r) => r).join(' '), contains('No taxable sales'));
    });
  });

  group('the SAC summary', () {
    test('tags each rate with the outlet SAC', () {
      final s = sheetNamed(
        buildSheets(
          header: header(sac: '996331'),
          report: report(),
          bills: const [],
        ),
        'SAC summary',
      );

      final row = rowLabelled(s, '996331');
      expect(row[1], 'Restaurant service');
      expect(row[2], '5%');
      expect(row[3], '960.00');
      expect(row[4], '24.00');
      expect(row[5], '24.00');
    });

    test('says the code must be confirmed, and what the usual one is', () {
      // The SAC is the first thing CA_REVIEW.md asks about. The export should
      // not present a configured default as if it were settled.
      final s = sheetNamed(
        buildSheets(header: header(), report: report(), bills: const []),
        'SAC summary',
      );
      final text = cells(s).expand((r) => r).join(' ');
      expect(text, contains('Confirm the code with your CA'));
      expect(text, contains('996331'));
    });
  });

  group('document counts', () {
    test('lists every document type, including the ones at zero', () {
      // A missing row reads as "not recorded"; a zero reads as "there were
      // none". For a document count that difference matters.
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(docCounts: const {DocType.invoice: 7}),
          bills: const [],
        ),
        'Document counts',
      );

      expect(rowLabelled(s, 'Tax invoice')[1], '7');
      expect(rowLabelled(s, 'Bill of supply')[1], '0');
      expect(rowLabelled(s, 'Credit note')[1], '0');
    });

    test('cancelled bills are counted and the numbering rule is stated', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(cancelledCount: 3),
          bills: const [],
        ),
        'Document counts',
      );

      expect(rowLabelled(s, 'Of which cancelled')[1], '3');
      final text = cells(s).expand((r) => r).join(' ');
      expect(text, contains('keeps its number'));
      expect(text, contains('never'));
    });
  });

  group('the items sheet', () {
    test('quantity and value per item', () {
      final s = sheetNamed(
        buildSheets(
          header: header(),
          report: report(byItem: const [
            ItemTotal(name: 'Chicken Dum Biryani', qty: 12, total: Paise(288000)),
            ItemTotal(name: 'కోడి పులావ్', qty: 3, total: Paise(54000)),
          ]),
          bills: const [],
        ),
        'Items',
      );

      expect(rowLabelled(s, 'Chicken Dum Biryani'),
          ['Chicken Dum Biryani', '12', '2880.00']);
      expect(rowLabelled(s, 'కోడి పులావ్'), ['కోడి పులావ్', '3', '540.00']);
    });

    test('explains that names are the ones things sold under', () {
      final s = sheetNamed(
        buildSheets(header: header(), report: report(), bills: const []),
        'Items',
      );
      expect(cells(s).expand((r) => r).join(' '), contains('renamed'));
    });
  });

  group('CSV encoding', () {
    test('uses CRLF and commas', () {
      final csv = toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportText('a'), ExportText('b')],
          [ExportText('c'), ExportText('d')],
        ],
      ));
      expect(csv, 'a,b\r\nc,d');
    });

    test('quotes a field containing a comma', () {
      final csv = toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportText('Main Road, Guntur'), ExportText('x')],
        ],
      ));
      expect(csv, '"Main Road, Guntur",x');
    });

    test('quotes a field containing a quote, and escapes it', () {
      final csv = toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportText('He said "yes"')],
        ],
      ));
      expect(csv, '"He said ""yes"""');
    });

    test('money is a plain decimal with no currency symbol', () {
      // A ₹ in the cell makes the column text, and a text column sums to zero.
      final csv = toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportMoney(Paise(123456))],
        ],
      ));
      expect(csv, '1234.56');
      expect(csv, isNot(contains('₹')));
      expect(csv, isNot(contains(',')));
    });

    test('a blank cell is empty, not the word null', () {
      final csv = toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportText('a'), ExportBlank(), ExportText('b')],
        ],
      ));
      expect(csv, 'a,,b');
    });

    test('the bytes start with a UTF-8 byte-order mark', () {
      // Without it, Excel on Windows opens the file in the system code page
      // and the Telugu item names come out as mojibake.
      final bytes = csvBytes(toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportText('కోడి పులావ్')],
        ],
      )));
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    });

    test('Telugu survives the round trip', () {
      final bytes = csvBytes(toCsv(const ExportSheet(
        name: 'T',
        rows: [
          [ExportText('కోడి పులావ్')],
        ],
      )));
      // Past the mark, the rest must decode back to what went in.
      expect(
        String.fromCharCodes(bytes.skip(3)).runes.length,
        greaterThan(0),
      );
      expect(
        utf8Decode(bytes.skip(3).toList()),
        'కోడి పులావ్',
      );
    });
  });

  group('the workbook', () {
    test('encodes, reopens, and holds every sheet', () {
      final sheets = buildSheets(
        header: header(),
        report: report(byItem: const [
          ItemTotal(name: 'Chicken Dum Biryani', qty: 12, total: Paise(288000)),
        ]),
        bills: const [],
      );

      final bytes = toXlsx(sheets);
      expect(bytes, isNotEmpty);

      final reopened = xl.Excel.decodeBytes(bytes);
      for (final sheet in sheets) {
        expect(
          reopened.tables.keys,
          contains(sheet.name),
          reason: 'sheets found: ${reopened.tables.keys.join(', ')}',
        );
      }
    });

    test('has no leftover default sheet', () {
      // Excel.createExcel() starts with Sheet1. Leaving it gives the
      // accountant an empty tab to wonder about.
      final bytes = toXlsx(buildSheets(
        header: header(),
        report: report(),
        bills: const [],
      ));
      final reopened = xl.Excel.decodeBytes(bytes);
      expect(reopened.tables.keys, isNot(contains('Sheet1')));
      expect(reopened.tables, hasLength(6));
    });

    test('money is a number a spreadsheet can sum, not text', () {
      final bytes = toXlsx([
        const ExportSheet(
          name: 'Money',
          rows: [
            [ExportText('Total'), ExportMoney(Paise(123456))],
          ],
        ),
      ]);

      final cell = xl.Excel.decodeBytes(bytes)['Money']
          .row(0)[1]!
          .value;
      expect(cell, isA<xl.DoubleCellValue>());
      expect((cell as xl.DoubleCellValue).value, closeTo(1234.56, 0.0001));
    });

    test('a count is an integer, not a decimal', () {
      final bytes = toXlsx([
        const ExportSheet(
          name: 'Counts',
          rows: [
            [ExportText('Bills'), ExportNumber(7)],
          ],
        ),
      ]);
      final cell = xl.Excel.decodeBytes(bytes)['Counts'].row(0)[1]!.value;
      expect(cell, isA<xl.IntCellValue>());
      expect((cell as xl.IntCellValue).value, 7);
    });

    test('Telugu text survives the round trip', () {
      final bytes = toXlsx([
        const ExportSheet(
          name: 'Items',
          rows: [
            [ExportText('కోడి పులావ్'), ExportNumber(3)],
          ],
        ),
      ]);
      final cell = xl.Excel.decodeBytes(bytes)['Items'].row(0)[0]!.value;
      expect((cell as xl.TextCellValue).value.toString(), 'కోడి పులావ్');
    });

    test('a long sheet name is trimmed to something Excel accepts', () {
      final bytes = toXlsx([
        const ExportSheet(
          name: 'A sheet name far longer than Excel will ever accept',
          rows: [
            [ExportText('x')],
          ],
        ),
      ]);
      final names = xl.Excel.decodeBytes(bytes).tables.keys;
      expect(names, hasLength(1));
      expect(names.first.length, lessThanOrEqualTo(31));
    });
  });

  group('against a real database', () {
    late PosDatabase db;
    late String deviceId;
    late String ownerId;
    late String itemId;

    setUp(() async {
      db = PosDatabase.memory();
      final setup = SetupRepository(db);
      final r = await setup.completeSetup(const SetupDetails(
        outletName: 'Annapurna Mess',
        address: 'Main Road',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: TaxMode.regular5,
        gstin: '37ABCDE1234F1Z5',
        ownerName: 'Ravi',
        ownerPin: '1357',
        devicePrefix: 'A',
      ));
      deviceId = r.deviceId;
      ownerId = r.ownerId;

      final menu = MenuRepository(db, deviceId: deviceId);
      final cat =
          await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
      itemId = await menu.createItem(
        categoryId: cat,
        nameEn: 'Chicken Dum Biryani',
        price: Paise.fromRupees(240),
        taxClass: TaxClass.gst5,
        byUserId: ownerId,
      );
    });

    tearDown(() => db.close());

    Future<SavedBill> sell({int qty = 1}) async {
      final computed = computeBill(
        cart: [
          CartLine(
            itemId: itemId,
            nameSnapshot: 'Chicken Dum Biryani',
            unitPrice: Paise.fromRupees(240),
            qty: qty,
            taxClass: TaxClass.gst5,
          ),
        ],
        config: const TaxConfig(mode: TaxMode.regular5, pricesIncludeTax: false),
        orderType: OrderType.dine,
      );
      return BillRepository(db).commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: deviceId,
        userId: ownerId,
      );
    }

    test('refuses to export before setup', () async {
      final empty = PosDatabase.memory();
      addTearDown(empty.close);
      await expectLater(
        ExportService(empty).build(
          const BusinessDate(2026, 10, 1),
          const BusinessDate(2026, 10, 31),
        ),
        throwsStateError,
      );
    });

    test('a real sale reaches the sheets with the right figures', () async {
      final bill = await sell(qty: 2);
      final today = bill.businessDate;

      final sheets = await ExportService(db).build(today, today);

      final summary = sheetNamed(sheets, 'Summary');
      expect(rowLabelled(summary, 'Bills')[1], '1');
      // 2 x 240 = 480 taxable, 5% = 24, split 12 and 12, total 504.
      expect(rowLabelled(summary, 'Taxable value')[1], '480.00');
      expect(rowLabelled(summary, 'CGST')[1], '12.00');
      expect(rowLabelled(summary, 'SGST')[1], '12.00');
      expect(rowLabelled(summary, 'Sales (total of bills)')[1], '504.00');
      expect(rowLabelled(summary, 'FSSAI')[1], '12345678901234');

      final rates = sheetNamed(sheets, 'Sales by tax rate');
      expect(rowLabelled(rates, '5%'), ['5%', '480.00', '12.00', '12.00', '24.00']);

      final bills = sheetNamed(sheets, 'Bills');
      final row = rowLabelled(bills, bill.invoiceNo.formatted);
      expect(row, contains('Tax invoice'));
      expect(row, contains('Paid'));
      expect(row, contains('Cash'));
      expect(row.last, '', reason: 'a live bill has no cancellation reason');
    });

    test('a cancelled bill appears with its reason and is out of the total',
        () async {
      final keep = await sell();
      final gone = await sell();
      await BillRepository(db).cancelBill(
        billId: gone.id,
        reason: 'Wrong item entered',
        userId: ownerId,
        deviceId: deviceId,
      );

      final day = keep.businessDate;
      final sheets = await ExportService(db).build(day, day);

      final summary = sheetNamed(sheets, 'Summary');
      expect(rowLabelled(summary, 'Bills')[1], '1');
      expect(rowLabelled(summary, 'Cancelled bills')[1], '1');
      expect(rowLabelled(summary, 'Sales (total of bills)')[1], '252.00');

      final bills = sheetNamed(sheets, 'Bills');
      final row = rowLabelled(bills, gone.invoiceNo.formatted);
      expect(row, contains('Cancelled'));
      expect(row.last, 'Wrong item entered');

      // The cancelled bill keeps its number: both are still listed.
      expect(
        cells(bills).where((r) => r.first.startsWith('A/')),
        hasLength(2),
      );
    });

    test('the whole thing encodes to a workbook that reopens', () async {
      final bill = await sell();
      final day = bill.businessDate;
      final sheets = await ExportService(db).build(day, day);

      final reopened = xl.Excel.decodeBytes(toXlsx(sheets));
      expect(reopened.tables, hasLength(6));
      expect(
        reopened['Bills'].rows.length,
        greaterThanOrEqualTo(2),
        reason: 'a header row and one bill',
      );
    });

    test('and every sheet encodes to CSV', () async {
      final bill = await sell();
      final day = bill.businessDate;
      final sheets = await ExportService(db).build(day, day);

      for (final sheet in sheets) {
        final csv = toCsv(sheet);
        expect(csv, isNotEmpty, reason: sheet.name);
        expect(csvBytes(csv).length, greaterThan(3), reason: sheet.name);
      }
    });
  });
}

/// Decodes UTF-8 bytes, for the CSV mark test.
String utf8Decode(List<int> bytes) =>
    const Utf8Decoder().convert(bytes);
