import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.db;
  runApp(const RemitApp());
}

class Store {
  static Database? _database;
  static Future<Database> get db async {
    if (_database != null) return _database!;
    final dir = await getDatabasesPath();
    _database = await openDatabase(
      p.join(dir, 'alquood_remit.db'),
      version: 1,
      onCreate: (d, v) async {
        await d.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT, account_no TEXT UNIQUE, full_name TEXT NOT NULL, phone TEXT, identity_no TEXT, address TEXT, created_at TEXT NOT NULL)');
        await d.execute('CREATE TABLE remittances(id INTEGER PRIMARY KEY AUTOINCREMENT, reference_no TEXT UNIQUE, sender_name TEXT NOT NULL, receiver_name TEXT NOT NULL, receiver_phone TEXT, customer_id INTEGER, amount REAL NOT NULL, currency TEXT NOT NULL, status TEXT NOT NULL, transfer_date TEXT NOT NULL, notes TEXT)');
      },
    );
    return _database!;
  }

  static Future<List<Map<String, Object?>>> customers() async => (await db).query('customers', orderBy: 'full_name');
  static Future<List<Map<String, Object?>>> transfers() async => (await db).query('remittances', orderBy: 'id DESC');
  static Future<int> addCustomer(Map<String, Object?> row) async => (await db).insert('customers', row);
  static Future<int> addTransfer(Map<String, Object?> row) async => (await db).insert('remittances', row);
  static Future<List<Map<String, Object?>>> statement(int id) async => (await db).query('remittances', where: 'customer_id=?', whereArgs: [id], orderBy: 'id DESC');
  static Future<int> count(String table) async {
    final r = await (await db).rawQuery('SELECT COUNT(*) AS n FROM ' + table);
    return Sqflite.firstIntValue(r) ?? 0;
  }
  static Future<Map<String, double>> totalsByCurrency() async {
    final rows = await (await db).rawQuery("SELECT currency, SUM(amount) AS total FROM remittances WHERE status != 'ملغاة' GROUP BY currency");
    return {for (final r in rows) r['currency'].toString(): (r['total'] as num).toDouble()};
  }
  static Future<int> countByStatus(String status) async {
    final rows = await (await db).rawQuery('SELECT COUNT(*) AS n FROM remittances WHERE status=?', [status]);
    return Sqflite.firstIntValue(rows) ?? 0;
  }
  static Future<String> exportCsv() async {
    final d = await db;
    final customers = await d.query('customers', orderBy: 'id');
    final transfers = await d.query('remittances', orderBy: 'id');
    String cell(Object? value) => '"' + (value?.toString() ?? '').replaceAll('"', '""') + '"';
    final out = <String>['النوع,المعرف,رقم الحساب/الحوالة,الاسم/المرسل,المستلم,الهاتف,الهوية,العنوان,المبلغ,العملة,الحالة,التاريخ,ملاحظات'];
    for (final c in customers) {
      out.add([cell('عميل'),cell(c['id']),cell(c['account_no']),cell(c['full_name']),cell(''),cell(c['phone']),cell(c['identity_no']),cell(c['address']),cell(''),cell(''),cell(''),cell(c['created_at']),cell('')].join(','));
    }
    for (final t in transfers) {
      out.add([cell('حوالة'),cell(t['id']),cell(t['reference_no']),cell(t['sender_name']),cell(t['receiver_name']),cell(t['receiver_phone']),cell(''),cell(''),cell(t['amount']),cell(t['currency']),cell(t['status']),cell(t['transfer_date']),cell(t['notes'])].join(','));
    }
    return '\\uFEFF' + out.join('\\n');
  }
}

class RemitApp extends StatelessWidget {
  const RemitApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'ALQUOOD REMIT',
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF145A48)), scaffoldBackgroundColor: const Color(0xFFF4F7F5), appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF145A48), foregroundColor: Colors.white)),
    home: const MainPage(),
  );
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}
class _MainPageState extends State<MainPage> {
  int page = 0, version = 0;
  void reload() => setState(() => version++);
  Future<void> copyBackup() async {
    final csv = await Store.exportCsv();
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ نسخة CSV الاحتياطية. الصقها في ملف واحفظها بأمان.')));
  }
  @override
  Widget build(BuildContext context) {
    final names = ['الرئيسية', 'العملاء', 'الحوالات'];
    return Directionality(textDirection: ui.TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('ALQUOOD REMIT', style: TextStyle(fontWeight: FontWeight.bold)), Text(names[page], style: const TextStyle(fontSize: 12, color: Colors.white70))]), actions: [IconButton(tooltip: 'نسخ نسخة احتياطية', onPressed: copyBackup, icon: const Icon(Icons.backup_outlined)), IconButton(tooltip: 'تحديث', onPressed: reload, icon: const Icon(Icons.refresh))]),
      body: IndexedStack(index: page, children: [
        Dashboard(key: ValueKey('home' + version.toString()), go: (v) => setState(() => page = v)),
        CustomerList(key: ValueKey('customers' + version.toString())),
        TransferList(key: ValueKey('transfers' + version.toString())),
      ]),
      floatingActionButton: page == 1 || page == 2 ? FloatingActionButton.extended(
        onPressed: () async {
          if (page == 1) {
            await customerForm(context);
          } else {
            final cs = await Store.customers();
            if (!context.mounted) return;
            await transferForm(context, cs);
          }
          reload();
        },
        icon: const Icon(Icons.add),
        label: Text(page == 1 ? 'إضافة عميل' : 'إضافة حوالة'),
      ) : null,
      bottomNavigationBar: NavigationBar(selectedIndex: page, onDestinationSelected: (v) => setState(() => page = v), destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'الرئيسية'),
        NavigationDestination(icon: Icon(Icons.people_outline), label: 'العملاء'),
        NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'الحوالات'),
      ]),
    ));
  }
}

class Dashboard extends StatelessWidget {
  final ValueChanged<int> go;
  const Dashboard({super.key, required this.go});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Object>>(
    future: Future.wait<Object>([Store.count('customers'), Store.count('remittances'), Store.totalsByCurrency(), Store.countByStatus('مكتملة'), Store.countByStatus('قيد الانتظار')]),
    builder: (context, s) {
      final v = s.data ?? <Object>[0, 0, <String,double>{}, 0, 0];
      final totals = v[2] as Map<String, double>;
      return ListView(padding: const EdgeInsets.all(16), children: [
        Container(padding: const EdgeInsets.all(22), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF145A48), Color(0xFF23836A)]), borderRadius: BorderRadius.circular(20)), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('إدارة حوالاتك بكل وضوح', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.bold)),
          SizedBox(height: 8), Text('دفتر عملاء وحوالات يعمل دون إنترنت', style: TextStyle(color: Colors.white70)),
          SizedBox(height: 16), Text('البيانات محفوظة محليًا على هذا الجهاز', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ])),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 10, children: [
          metric(context, 'العملاء', v[0].toString(), Icons.people, () => go(1)),
          metric(context, 'الحوالات', v[1].toString(), Icons.receipt_long, () => go(2)),
          metric(context, 'الحوالات المكتملة', v[3].toString(), Icons.check_circle_outline, () => go(2)),
          metric(context, 'قيد الانتظار', v[4].toString(), Icons.hourglass_empty, () => go(2)),
        ]),
        const SizedBox(height: 10),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('إجمالي الحوالات حسب العملة', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (totals.isEmpty) const Text('لا توجد مبالغ مسجلة بعد', style: TextStyle(color: Colors.black54)),
          ...totals.entries.map((e) => ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.account_balance_wallet_outlined), title: Text(e.key), trailing: Text(NumberFormat('#,##0.##').format(e.value), style: const TextStyle(fontWeight: FontWeight.bold)))),
        ]))),
        ]),
        const SizedBox(height: 14),
        const Card(child: ListTile(leading: Icon(Icons.info_outline), title: Text('تنبيه'), subtitle: Text('الإشعارات والمزامنة السحابية غير مفعّلة في هذه النسخة. اختبر التطبيق قبل إدخال بيانات حقيقية.'))),
      ]);
    },
  );
}

Widget metric(BuildContext c, String title, String value, IconData icon, VoidCallback? tap, {bool wide = false}) => SizedBox(
  width: wide ? double.infinity : (MediaQuery.of(c).size.width - 42) / 2,
  child: Card(child: InkWell(onTap: tap, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, color: Theme.of(c).colorScheme.primary), const SizedBox(height: 10),
    Text(value, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)), Text(title, style: const TextStyle(color: Colors.black54, fontSize: 12)),
  ])))),
);

class CustomerList extends StatefulWidget {
  const CustomerList({super.key});
  @override
  State<CustomerList> createState() => _CustomerListState();
}
class _CustomerListState extends State<CustomerList> {
  String q = '';
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    future: Store.customers(),
    builder: (context, s) {
      final rows = (s.data ?? []).where((r) => (r['full_name'].toString() + ' ' + (r['phone'] ?? '').toString() + ' ' + (r['account_no'] ?? '').toString() + ' ' + (r['identity_no'] ?? '').toString()).toLowerCase().contains(q.toLowerCase())).toList();
      return Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: TextField(onChanged: (v) => setState(() => q = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث بالاسم أو الهاتف أو الحساب'))),
        Expanded(child: s.connectionState == ConnectionState.waiting ? const Center(child: CircularProgressIndicator()) : rows.isEmpty ? const Center(child: Text('لا يوجد عملاء. أضف أول عميل.')) : ListView.builder(itemCount: rows.length, itemBuilder: (c, i) {
          final r = rows[i];
          return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text(r['full_name'].toString()), subtitle: Text('الحساب: ' + (r['account_no'] ?? '—').toString() + '  |  الهاتف: ' + (r['phone'] ?? '—').toString()), onTap: () => customerDetails(context, r)));
        })),
      ]);
    },
  );
}

class TransferList extends StatefulWidget {
  const TransferList({super.key});
  @override
  State<TransferList> createState() => _TransferListState();
}
class _TransferListState extends State<TransferList> {
  String q = '';
  String statusFilter = 'الكل';
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    future: Store.transfers(),
    builder: (context, s) {
      final rows = (s.data ?? []).where((r) =>
        (statusFilter == 'الكل' || r['status'] == statusFilter) &&
        (r['reference_no'].toString() + ' ' + r['sender_name'].toString() + ' ' + r['receiver_name'].toString() + ' ' + (r['receiver_phone'] ?? '').toString()).toLowerCase().contains(q.toLowerCase())).toList();
      return Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: TextField(onChanged: (v) => setState(() => q = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث برقم الحوالة أو الاسم'))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 8), child: DropdownButtonFormField<String>(
          value: statusFilter,
          decoration: const InputDecoration(labelText: 'تصفية حسب الحالة', prefixIcon: Icon(Icons.filter_list)),
          items: const [DropdownMenuItem(value: 'الكل', child: Text('كل الحالات')), DropdownMenuItem(value: 'قيد الانتظار', child: Text('قيد الانتظار')), DropdownMenuItem(value: 'مكتملة', child: Text('مكتملة')), DropdownMenuItem(value: 'ملغاة', child: Text('ملغاة'))],
          onChanged: (v) => setState(() => statusFilter = v ?? 'الكل'),
        )),
        Expanded(child: s.connectionState == ConnectionState.waiting ? const Center(child: CircularProgressIndicator()) : rows.isEmpty ? const Center(child: Text('لا توجد حوالات مسجلة.')) : ListView.builder(itemCount: rows.length, itemBuilder: (c, i) {
          final r = rows[i];
          return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ListTile(leading: const CircleAvatar(child: Icon(Icons.swap_horiz)), title: Text(r['receiver_name'].toString()), subtitle: Text('رقم: ' + r['reference_no'].toString() + '\nمن: ' + r['sender_name'].toString() + ' • ' + NumberFormat('#,##0.##').format(r['amount']) + ' ' + r['currency'].toString() + ' • ' + r['status'].toString()), isThreeLine: true, onTap: () => transferDetails(context, r)));
        })),
      ]);
    },
  );
}

Widget textField(TextEditingController c, String label, {bool numeric = false}) => Padding(padding: const EdgeInsets.only(bottom: 9), child: TextField(controller: c, keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text, decoration: InputDecoration(labelText: label)));

Future<void> customerForm(BuildContext context) async {
  final name = TextEditingController(), phone = TextEditingController(), identity = TextEditingController(), address = TextEditingController(), account = TextEditingController();
  await showDialog(context: context, builder: (x) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(
    title: const Text('عميل جديد'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [textField(name, 'الاسم الكامل *'), textField(phone, 'رقم الهاتف'), textField(identity, 'رقم الهوية'), textField(address, 'العنوان'), textField(account, 'رقم حساب العميل')])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(x), child: const Text('إلغاء')),
      FilledButton(onPressed: () async {
        if (name.text.trim().isEmpty) return;
        try {
          await Store.addCustomer({'full_name': name.text.trim(), 'phone': phone.text.trim(), 'identity_no': identity.text.trim(), 'address': address.text.trim(), 'account_no': account.text.trim().isEmpty ? 'AC-' + DateTime.now().millisecondsSinceEpoch.toString() : account.text.trim(), 'created_at': DateTime.now().toIso8601String()});
          if (x.mounted) Navigator.pop(x);
        } catch (_) {
          if (x.mounted) ScaffoldMessenger.of(x).showSnackBar(const SnackBar(content: Text('رقم الحساب مستخدم أو حدث خطأ في الحفظ.')));
        }
      }, child: const Text('حفظ')),
    ],
  )));
}

Future<void> transferForm(BuildContext context, List<Map<String, Object?>> customers) async {
  final ref = TextEditingController(text: 'TR-' + DateTime.now().millisecondsSinceEpoch.toString()), sender = TextEditingController(), receiver = TextEditingController(), phone = TextEditingController(), amount = TextEditingController(), notes = TextEditingController();
  int? customerId;
  String currency = 'YER', status = 'قيد الانتظار';
  await showDialog(context: context, builder: (x) => StatefulBuilder(builder: (x, setLocal) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(
    title: const Text('حوالة جديدة'),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      textField(ref, 'رقم الحوالة *'), textField(sender, 'اسم المرسل *'), textField(receiver, 'اسم المستلم *'), textField(phone, 'هاتف المستلم'), textField(amount, 'المبلغ *', numeric: true),
      DropdownButtonFormField<String>(value: currency, decoration: const InputDecoration(labelText: 'العملة'), items: const [DropdownMenuItem(value: 'YER', child: Text('ريال يمني YER')), DropdownMenuItem(value: 'SAR', child: Text('ريال سعودي SAR')), DropdownMenuItem(value: 'USD', child: Text('دولار أمريكي USD'))], onChanged: (v) => setLocal(() => currency = v ?? 'YER')),
      const SizedBox(height: 9),
      DropdownButtonFormField<int?>(value: customerId, decoration: const InputDecoration(labelText: 'ربط بملف عميل (اختياري)'), items: [const DropdownMenuItem<int?>(value: null, child: Text('بدون ربط')), ...customers.map((c) => DropdownMenuItem<int?>(value: c['id'] as int, child: Text(c['full_name'].toString())))], onChanged: (v) => setLocal(() => customerId = v)),
      const SizedBox(height: 9),
      DropdownButtonFormField<String>(value: status, decoration: const InputDecoration(labelText: 'الحالة'), items: const [DropdownMenuItem(value: 'قيد الانتظار', child: Text('قيد الانتظار')), DropdownMenuItem(value: 'مكتملة', child: Text('مكتملة')), DropdownMenuItem(value: 'ملغاة', child: Text('ملغاة'))], onChanged: (v) => setLocal(() => status = v ?? 'قيد الانتظار')),
      const SizedBox(height: 9), textField(notes, 'ملاحظات'),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(x), child: const Text('إلغاء')),
      FilledButton(onPressed: () async {
        final n = double.tryParse(amount.text.trim());
        if (ref.text.trim().isEmpty || sender.text.trim().isEmpty || receiver.text.trim().isEmpty || n == null || n <= 0) {
          ScaffoldMessenger.of(x).showSnackBar(const SnackBar(content: Text('أدخل البيانات المطلوبة ومبلغًا صحيحًا.'))); return;
        }
        try {
          await Store.addTransfer({'reference_no': ref.text.trim(), 'sender_name': sender.text.trim(), 'receiver_name': receiver.text.trim(), 'receiver_phone': phone.text.trim(), 'customer_id': customerId, 'amount': n, 'currency': currency, 'status': status, 'transfer_date': DateTime.now().toIso8601String(), 'notes': notes.text.trim()});
          if (x.mounted) Navigator.pop(x);
        } catch (_) {
          if (x.mounted) ScaffoldMessenger.of(x).showSnackBar(const SnackBar(content: Text('رقم الحوالة مكرر أو حدث خطأ في الحفظ.')));
        }
      }, child: const Text('حفظ الحوالة')),
    ],
  ))));
}

Future<void> customerDetails(BuildContext context, Map<String, Object?> c) async {
  final list = await Store.statement(c['id'] as int);
  if (!context.mounted) return;
  await showDialog(context: context, builder: (x) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(
    title: Text(c['full_name'].toString()),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      detail('رقم الحساب', c['account_no']), detail('الهاتف', c['phone']), detail('الهوية', c['identity_no']), detail('العنوان', c['address']),
      const Divider(), Text('كشف الحوالات: ' + list.length.toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
      ...list.map((r) => ListTile(contentPadding: EdgeInsets.zero, title: Text(r['reference_no'].toString() + ' • ' + r['receiver_name'].toString()), subtitle: Text(NumberFormat('#,##0.##').format(r['amount']) + ' ' + r['currency'].toString() + ' • ' + r['status'].toString()))),
    ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(x), child: const Text('إغلاق'))],
  )));
}

Future<void> transferDetails(BuildContext context, Map<String, Object?> r) async {
  await showDialog(context: context, builder: (x) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(
    title: Text('حوالة ' + r['reference_no'].toString()),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      detail('المرسل', r['sender_name']), detail('المستلم', r['receiver_name']), detail('هاتف المستلم', r['receiver_phone']),
      detail('المبلغ', NumberFormat('#,##0.##').format(r['amount']) + ' ' + r['currency'].toString()), detail('الحالة', r['status']), detail('التاريخ', r['transfer_date']), detail('ملاحظات', r['notes']),
    ]),
    actions: [TextButton(onPressed: () => Navigator.pop(x), child: const Text('إغلاق'))],
  )));
}
Widget detail(String label, Object? value) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(label + ': ' + ((value == null || value.toString().isEmpty) ? '—' : value.toString())));
