/// Shared setup for the data-layer tests: an in-memory database with one
/// outlet, one device, an owner, a staff member and a small menu.
library;

// drift exports isNull/isNotNull as SQL expression helpers, which collide
// with flutter_test's matchers of the same name.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/db.dart';

const String kOutletId = 'outlet-1';
const String kDeviceId = 'device-1';
const String kOwnerId = 'user-owner';
const String kStaffId = 'user-staff';
const String kCategoryId = 'cat-biryani';
const String kItemBiryani = 'item-chicken-dum';
const String kItemColdDrink = 'item-cold-drink';
const String kItemWater = 'item-water';

/// A valid 14-digit FSSAI number, for the gate that blocks billing without one.
const String kValidFssai = '12345678901234';

class Fixture {
  Fixture(this.db);

  final PosDatabase db;

  static Future<Fixture> create({
    TaxMode taxMode = TaxMode.regular5,
    bool pricesIncludeTax = false,
    String fssai = kValidFssai,
    int cutoffMinutes = 240,
    int nextSeq = 1,
    int fyStart = 2026,
  }) async {
    final db = PosDatabase.memory();
    final f = Fixture(db);
    await f._seed(
      taxMode: taxMode,
      pricesIncludeTax: pricesIncludeTax,
      fssai: fssai,
      cutoffMinutes: cutoffMinutes,
      nextSeq: nextSeq,
      fyStart: fyStart,
    );
    return f;
  }

  Future<void> _seed({
    required TaxMode taxMode,
    required bool pricesIncludeTax,
    required String fssai,
    required int cutoffMinutes,
    required int nextSeq,
    required int fyStart,
  }) async {
    await db.into(db.outlets).insert(OutletsCompanion.insert(
          id: kOutletId,
          name: 'Test Restaurant',
          address: 'Main Road, Vijayawada',
          phone: '9000000000',
          fssaiNo: fssai,
          taxMode: taxMode,
          pricesIncludeTax: Value(pricesIncludeTax),
          businessDayCutoffMinutes: Value(cutoffMinutes),
        ));

    await db.into(db.devices).insert(DevicesCompanion.insert(
          id: kDeviceId,
          outletId: kOutletId,
          seriesPrefix: 'A',
          nextSeq: Value(nextSeq),
          seqFy: FinancialYear(fyStart),
        ));

    await db.into(db.users).insert(UsersCompanion.insert(
          id: kOwnerId,
          name: 'Owner',
          role: UserRole.owner,
          // Not a real hash; these tests never check a PIN.
          pinHash: 'test-not-a-real-hash',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: kStaffId,
          name: 'Staff',
          role: UserRole.staff,
          pinHash: 'test-not-a-real-hash',
        ));

    await db.into(db.categories).insert(CategoriesCompanion.insert(
          id: kCategoryId,
          nameEn: 'Biryani',
          nameTe: const Value('బిర్యానీ'),
        ));

    final now = DateTime(2026, 6, 1, 12);
    await db.into(db.items).insert(ItemsCompanion.insert(
          id: kItemBiryani,
          categoryId: kCategoryId,
          nameEn: 'Chicken Dum Biryani',
          nameTe: const Value('చికెన్ దమ్ బిర్యానీ'),
          pricePaise: Paise.fromRupees(240),
          taxClass: TaxClass.gst5,
          updatedAt: now,
        ));
    await db.into(db.items).insert(ItemsCompanion.insert(
          id: kItemColdDrink,
          categoryId: kCategoryId,
          nameEn: 'Bottled soft drink',
          nameTe: const Value('శీతల పానీయం'),
          pricePaise: Paise.fromRupees(100),
          taxClass: TaxClass.gst18,
          updatedAt: now,
        ));
    await db.into(db.items).insert(ItemsCompanion.insert(
          id: kItemWater,
          categoryId: kCategoryId,
          nameEn: 'Mineral water',
          pricePaise: Paise.fromRupees(20),
          taxClass: TaxClass.nonGst,
          updatedAt: now,
        ));
  }

  Future<void> close() => db.close();

  /// A cart holding one biryani, unless told otherwise.
  List<CartLine> cart({
    int biryaniQty = 1,
    bool withColdDrink = false,
    bool withWater = false,
  }) =>
      [
        CartLine(
          itemId: kItemBiryani,
          nameSnapshot: 'Chicken Dum Biryani',
          nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
          unitPrice: Paise.fromRupees(240),
          qty: biryaniQty,
          taxClass: TaxClass.gst5,
        ),
        if (withColdDrink)
          CartLine(
            itemId: kItemColdDrink,
            nameSnapshot: 'Bottled soft drink',
            unitPrice: Paise.fromRupees(100),
            qty: 1,
            taxClass: TaxClass.gst18,
          ),
        if (withWater)
          CartLine(
            itemId: kItemWater,
            nameSnapshot: 'Mineral water',
            unitPrice: Paise.fromRupees(20),
            qty: 1,
            taxClass: TaxClass.nonGst,
          ),
      ];

  /// The outlet's own tax configuration, read back from the row.
  Future<TaxConfig> taxConfig() async {
    final o = await db.select(db.outlets).getSingle();
    return TaxConfig(
      mode: o.taxMode,
      pricesIncludeTax: o.pricesIncludeTax,
      sacCode: o.sacCode,
    );
  }

  Future<ComputedBill> compute({
    List<CartLine>? lines,
    OrderType orderType = OrderType.dine,
    Paise billDiscount = Paise.zero,
  }) async =>
      computeBill(
        cart: lines ?? cart(),
        config: await taxConfig(),
        orderType: orderType,
        billDiscount: billDiscount,
      );

  // --- small read helpers the tests use repeatedly ---------------------

  Future<int> billCount() async =>
      (await db.select(db.bills).get()).length;

  Future<int> lineCount() async =>
      (await db.select(db.billLines).get()).length;

  Future<int> paymentCount() async =>
      (await db.select(db.payments).get()).length;

  Future<int> auditCount() async =>
      (await db.select(db.auditLog).get()).length;

  Future<int> outboxCount() async =>
      (await db.select(db.outbox).get()).length;

  Future<int> nextSeq() async =>
      (await db.select(db.devices).getSingle()).nextSeq;

  Future<FinancialYear> seqFy() async =>
      (await db.select(db.devices).getSingle()).seqFy;
}
