import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'dart:convert';
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
      version: 3,
      onCreate: (d, v) async {
        await d.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT, account_no TEXT UNIQUE, full_name TEXT NOT NULL, phone TEXT, identity_no TEXT, address TEXT, created_at TEXT NOT NULL)');
        await d.execute('CREATE TABLE remittances(id INTEGER PRIMARY KEY AUTOINCREMENT, reference_no TEXT UNIQUE, sender_name TEXT NOT NULL, receiver_name TEXT NOT NULL, receiver_phone TEXT, customer_id INTEGER, amount REAL NOT NULL, currency TEXT NOT NULL, status TEXT NOT NULL, transfer_date TEXT NOT NULL, notes TEXT)');
        await d.execute('CREATE TABLE staff(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, full_name TEXT NOT NULL, pin_hash TEXT NOT NULL, role TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)');
        await d.execute('CREATE TABLE audit_logs(id INTEGER PRIMARY KEY AUTOINCREMENT, staff_name TEXT NOT NULL, action TEXT NOT NULL, details TEXT, created_at TEXT NOT NULL)');
        await d.execute('CREATE TABLE ledger_entries(id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL, transfer_id INTEGER, entry_type TEXT NOT NULL, amount REAL NOT NULL, currency TEXT NOT NULL, description TEXT, created_at TEXT NOT NULL)');
      },
      onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await d.execute('CREATE TABLE staff(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, full_name TEXT NOT NULL, pin_hash TEXT NOT NULL, role TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)');
          await d.execute('CREATE TABLE audit_logs(id INTEGER PRIMARY KEY AUTOINCREMENT, staff_name TEXT NOT NULL, action TEXT NOT NULL, details TEXT, created_at TEXT NOT NULL)');
        }
        if (oldVersion < 3) {
          await d.execute('CREATE TABLE ledger_entries(id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL, transfer_id INTEGER, entry_type TEXT NOT NULL, amount REAL NOT NULL, currency TEXT NOT NULL, description TEXT, created_at TEXT NOT NULL)');
        }
          await d.execute("INSERT INTO ledger_entries(customer_id, transfer_id, entry_type, amount, currency, description, created_at) SELECT customer_id, id, 'عليه', amount, currency, 'قيمة حوالة رقم ' || reference_no, transfer_date FROM remittances WHERE customer_id IS NOT NULL AND status != 'ملغاة'");
      },
    );
    return _database!;
  }

  static Future<List<Map<String, Object?>>> customers() async => (await db).query('customers', orderBy: 'full_name');
  static Future<List<Map<String, Object?>>> transfers() async => (await db).query('remittances', orderBy: 'id DESC');
  static String pinHash(String pin) => sha256.convert(utf8.encode(pin)).toString();
  static Future<int> staffCount() async => Sqflite.firstIntValue(await (await db).rawQuery('SELECT COUNT(*) FROM staff')) ?? 0;
  static Future<int> activeAdminCount() async => Sqflite.firstIntValue(await (await db).rawQuery("SELECT COUNT(*) FROM staff WHERE role='مدير' AND active=1")) ?? 0;
  static Future<int> addStaff(String username, String name, String pin, String role) async => (await db).insert('staff', {'username': username.trim(), 'full_name': name.trim(), 'pin_hash': pinHash(pin), 'role': role, 'active': 1, 'created_at': DateTime.now().toIso8601String()});
  static Future<Map<String,Object?>?> login(String username, String pin) async {
    final rows = await (await db).query('staff', where: 'username=? AND pin_hash=? AND active=1', whereArgs: [username.trim(), pinHash(pin)], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }
  static Future<List<Map<String,Object?>>> staff() async => (await db).query('staff', orderBy: 'id');
  static Future<void> setStaffActive(int id, bool active) async => (await db).update('staff', {'active':active?1:0}, where:'id=?', whereArgs:[id]);
  static Future<List<Map<String,Object?>>> logs() async => (await db).query('audit_logs', orderBy: 'id DESC', limit: 300);
  static Future<void> audit(String actor, String action, String details) async => (await db).insert('audit_logs', {'staff_name': actor, 'action': action, 'details': details, 'created_at': DateTime.now().toIso8601String()});
  static Future<int> addCustomer(Map<String, Object?> row) async => (await db).insert('customers', row);
  static Future<int> addTransfer(Map<String, Object?> row) async {
    final d = await db;
    return d.transaction((txn) async {
      final id = await txn.insert('remittances', row);
      if (row['customer_id'] != null && row['status'] != 'ملغاة') {
        await txn.insert('ledger_entries', {
          'customer_id': row['customer_id'], 'transfer_id': id, 'entry_type': 'عليه',
          'amount': row['amount'], 'currency': row['currency'],
          'description': 'قيمة حوالة رقم ${row['reference_no']}',
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      return id;
    });
  }
  static Future<int> updateTransferStatus(int id, String status) async {
    final d = await db;
    return d.transaction((txn) async {
      final rows = await txn.query('remittances', where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return 0;
      final old = rows.first;
      final previous = old['status'].toString();
      if (previous == status) return 0;
      if (old['customer_id'] != null && previous != 'ملغاة' && status == 'ملغاة') {
        await txn.insert('ledger_entries', {
          'customer_id': old['customer_id'], 'transfer_id': id, 'entry_type': 'له',
          'amount': old['amount'], 'currency': old['currency'],
          'description': 'عكس خصم حوالة ملغاة رقم ${old['reference_no']}',
          'created_at': DateTime.now().toIso8601String(),
        });
      } else if (old['customer_id'] != null && previous == 'ملغاة' && status != 'ملغاة') {
        await txn.insert('ledger_entries', {
          'customer_id': old['customer_id'], 'transfer_id': id, 'entry_type': 'عليه',
          'amount': old['amount'], 'currency': old['currency'],
          'description': 'إعادة تسجيل حوالة رقم ${old['reference_no']}',
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      return txn.update('remittances', {'status': status}, where: 'id=?', whereArgs: [id]);
    });
  }
  static Future<List<Map<String, Object?>>> statement(int id) async => (await db).query('remittances', where: 'customer_id=?', whereArgs: [id], orderBy: 'id DESC');
  static Future<List<Map<String, Object?>>> ledger(int id) async => (await db).query('ledger_entries', where: 'customer_id=?', whereArgs: [id], orderBy: 'id DESC');
  static Future<Map<String, double>> customerBalances(int id) async {
    final rows = await (await db).rawQuery("SELECT currency, SUM(CASE WHEN entry_type='له' THEN amount ELSE -amount END) AS balance FROM ledger_entries WHERE customer_id=? GROUP BY currency", [id]);
    return {for (final r in rows) r['currency'].toString(): (r['balance'] as num).toDouble()};
  }
  static Future<int> addCustomerCredit(int customerId, double amount, String currency, String description) async =>
    (await db).insert('ledger_entries', {'customer_id': customerId, 'entry_type': 'له', 'amount': amount, 'currency': currency, 'description': description, 'created_at': DateTime.now().toIso8601String()});
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
    return '\uFEFF' + out.join('\n');
  }
}

class RemitApp extends StatelessWidget {
  const RemitApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'ALQUOOD REMIT',
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF145A48)), scaffoldBackgroundColor: const Color(0xFFF4F7F5), appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF145A48), foregroundColor: Colors.white)),
    home: const AuthGate(),
  );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override State<AuthGate> createState() => _AuthGateState();
}
class _AuthGateState extends State<AuthGate> {
  Map<String,Object?>? user;
  bool loading = true;
  @override void initState(){ super.initState(); Store.staffCount().then((n){ if(mounted)setState(()=>loading=false); }); }
  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child:CircularProgressIndicator()));
    if (user != null) return MainPage(user:user!, onLogout:()=>setState(()=>user=null));
    return LoginPage(onLogin:(u)=>setState(()=>user=u));
  }
}

class LoginPage extends StatefulWidget {
  final ValueChanged<Map<String,Object?>> onLogin;
  const LoginPage({super.key,required this.onLogin});
  @override State<LoginPage> createState()=>_LoginPageState();
}
class _LoginPageState extends State<LoginPage>{
  final username=TextEditingController(), name=TextEditingController(), pin=TextEditingController();
  bool setup=false, busy=false;
  @override void initState(){super.initState();Store.staffCount().then((n){if(mounted)setState(()=>setup=n==0);});}
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.account_balance_wallet, size: 52, color: Color(0xFF145A48)),
                      const SizedBox(height: 12),
                      Text(setup ? 'إعداد حساب المدير' : 'تسجيل الدخول', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 18),
                      if (setup) TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم المدير الكامل')),
                      TextField(controller: username, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
                      TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'رمز PIN (4 أرقام على الأقل)')),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: busy ? null : () async {
                            if (username.text.trim().isEmpty || pin.text.length < 4 || (setup && name.text.trim().isEmpty)) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أكمل البيانات، والرمز لا يقل عن 4 أرقام.')));
                              return;
                            }
                            setState(() => busy = true);
                            try {
                              if (setup) {
                                await Store.addStaff(username.text, name.text, pin.text, 'مدير');
                                await Store.audit(name.text, 'إنشاء حساب المدير', 'إعداد أول تشغيل');
                              }
                              final u = await Store.login(username.text, pin.text);
                              if (u != null) {
                                await Store.audit(u['full_name'].toString(), 'تسجيل دخول', 'دخول ناجح');
                                if (mounted) widget.onLogin(u);
                              } else if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('بيانات الدخول غير صحيحة.')));
                              }
                            } catch (_) {
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اسم المستخدم مستخدم أو حدث خطأ.')));
                            }
                            if (mounted) setState(() => busy = false);
                          },
                          child: Text(setup ? 'إنشاء المدير والدخول' : 'دخول'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('الحسابات محفوظة على هذا الجهاز فقط. احتفظ برمزك ولا تشاركه.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainPage extends StatefulWidget {
  final Map<String,Object?> user; final VoidCallback onLogout;
  const MainPage({super.key,required this.user,required this.onLogout});
  @override
  State<MainPage> createState() => _MainPageState();
}
class _MainPageState extends State<MainPage> {
  int page = 0, version = 0;
  bool get isAdmin => widget.user['role']=='مدير';
  void reload() => setState(() => version++);
  Future<void> copyBackup() async {
    final csv = await Store.exportCsv();
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ نسخة CSV الاحتياطية. الصقها في ملف واحفظها بأمان.')));
  }
  @override
  Widget build(BuildContext context) {
    final names = ['الرئيسية', 'العملاء', 'الحوالات', if(isAdmin) 'سجل النشاط', if(isAdmin) 'الموظفون'];
    return Directionality(textDirection: ui.TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('ALQUOOD REMIT', style: TextStyle(fontWeight: FontWeight.bold)), Text(names[page], style: const TextStyle(fontSize: 12, color: Colors.white70))]), actions: [if(isAdmin) IconButton(tooltip: 'نسخ نسخة احتياطية', onPressed: copyBackup, icon: const Icon(Icons.backup_outlined)), IconButton(tooltip: 'تحديث', onPressed: reload, icon: const Icon(Icons.refresh)), IconButton(tooltip:'خروج',onPressed:widget.onLogout,icon:const Icon(Icons.logout))]),
      body: IndexedStack(index: page, children: [
        Dashboard(key: ValueKey('home' + version.toString()), go: (v) => setState(() => page = v)),
        CustomerList(key: ValueKey('customers' + version.toString())),
        TransferList(key: ValueKey('transfers' + version.toString()), actor: widget.user['full_name'].toString(), isAdmin: isAdmin),
        if(isAdmin) ActivityLog(key: ValueKey('logs'+version.toString())),
        if(isAdmin) StaffPage(key: ValueKey('staff'+version.toString())),
      ]),
      floatingActionButton: (page == 1 || page == 2) ? FloatingActionButton.extended(
        onPressed: () async {
          if (page == 1) {
            await customerForm(context, widget.user['full_name'].toString());
          } else {
            final cs = await Store.customers();
            if (!context.mounted) return;
            await transferForm(context, cs, widget.user['full_name'].toString(), isAdmin);
          }
          reload();
        },
        icon: const Icon(Icons.add),
        label: Text(page == 1 ? 'إضافة عميل' : 'إضافة حوالة'),
      ) : null,
      bottomNavigationBar: NavigationBar(selectedIndex: page, onDestinationSelected: (v) => setState(() => page = v), destinations: [
        const NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'الرئيسية'),
        const NavigationDestination(icon: Icon(Icons.people_outline), label: 'العملاء'),
        const NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'الحوالات'),
        if(isAdmin) const NavigationDestination(icon: Icon(Icons.history), label: 'السجل'),
        if(isAdmin) const NavigationDestination(icon: Icon(Icons.admin_panel_settings), label: 'الموظفون'),
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
  final String actor;
  final bool isAdmin;
  const TransferList({super.key,required this.actor, required this.isAdmin});
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
          return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ListTile(leading: const CircleAvatar(child: Icon(Icons.swap_horiz)), title: Text(r['receiver_name'].toString()), subtitle: Text('رقم: ' + r['reference_no'].toString() + '\nمن: ' + r['sender_name'].toString() + ' • ' + NumberFormat('#,##0.##').format(r['amount']) + ' ' + r['currency'].toString() + ' • ' + r['status'].toString()), isThreeLine: true, onTap: () => transferDetails(context, r, widget.actor, widget.isAdmin)));
        })),
      ]);
    },
  );
}

Widget textField(TextEditingController c, String label, {bool numeric = false}) => Padding(padding: const EdgeInsets.only(bottom: 9), child: TextField(controller: c, keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text, decoration: InputDecoration(labelText: label)));

Future<void> customerForm(BuildContext context, String actor) async {
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
          await Store.audit(actor,'إضافة عميل',name.text.trim());
          if (x.mounted) Navigator.pop(x);
        } catch (_) {
          if (x.mounted) ScaffoldMessenger.of(x).showSnackBar(const SnackBar(content: Text('رقم الحساب مستخدم أو حدث خطأ في الحفظ.')));
        }
      }, child: const Text('حفظ')),
    ],
  )));
}

Future<void> transferForm(BuildContext context, List<Map<String, Object?>> customers, String actor, bool isAdmin) async {
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
      const Padding(padding: EdgeInsets.only(top: 4), child: Text('عند ربط الحوالة بعميل، يُسجّل مبلغها عليه تلقائيًا في كشف حسابه. إذا لم يكفِ رصيده يظهر المتبقي كدين.', style: TextStyle(fontSize: 12, color: Colors.black54))),
      const SizedBox(height: 9),
      if(isAdmin) DropdownButtonFormField<String>(value: status, decoration: const InputDecoration(labelText: 'الحالة'), items: const [DropdownMenuItem(value: 'قيد الانتظار', child: Text('قيد الانتظار')), DropdownMenuItem(value: 'مكتملة', child: Text('مكتملة')), DropdownMenuItem(value: 'ملغاة', child: Text('ملغاة'))], onChanged: (v) => setLocal(() => status = v ?? 'قيد الانتظار')) else const ListTile(contentPadding:EdgeInsets.zero,leading:Icon(Icons.lock_outline),title:Text('الحالة الافتراضية: قيد الانتظار'),subtitle:Text('اعتماد أو إلغاء الحوالة من صلاحية المدير فقط.')),
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
          await Store.audit(actor,'إضافة حوالة',ref.text.trim()+' • '+receiver.text.trim());
          if (x.mounted) Navigator.pop(x);
        } catch (_) {
          if (x.mounted) ScaffoldMessenger.of(x).showSnackBar(const SnackBar(content: Text('رقم الحوالة مكرر أو حدث خطأ في الحفظ.')));
        }
      }, child: const Text('حفظ الحوالة')),
    ],
  ))));
}

Future<void> customerDetails(BuildContext context, Map<String, Object?> c) async {
  final customerId = c['id'] as int;
  final ledgerRows = await Store.ledger(customerId);
  final balances = await Store.customerBalances(customerId);
  if (!context.mounted) return;
  await showDialog(context: context, builder: (x) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(
    title: Row(children: [const CircleAvatar(child: Icon(Icons.person)), const SizedBox(width: 10), Expanded(child: Text(c['full_name'].toString()))]),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      detail('رقم الحساب', c['account_no']), detail('الهاتف', c['phone']), detail('الهوية', c['identity_no']), detail('العنوان', c['address']),
      const Divider(height: 24),
      const Text('الرصيد الحالي حسب العملة', style: TextStyle(fontWeight: FontWeight.bold)),
      if (balances.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('لا توجد حركات مالية لهذا العميل بعد.')),
      ...balances.entries.map((e) => Card(color: e.value < 0 ? Colors.red.shade50 : Colors.green.shade50, child: ListTile(
        dense: true, leading: Icon(e.value < 0 ? Icons.trending_down : Icons.account_balance_wallet, color: e.value < 0 ? Colors.red : Colors.green),
        title: Text(e.value < 0 ? 'المطلوب من العميل' : 'رصيد العميل له'),
        subtitle: Text(e.key), trailing: Text(NumberFormat('#,##0.##').format(e.value.abs()), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ))),
      const Divider(height: 24),
      Text('كشف الحساب • ${ledgerRows.length} حركة', style: const TextStyle(fontWeight: FontWeight.bold)),
      if (ledgerRows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('لا توجد حركات مسجلة.')),
      ...ledgerRows.map((r) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(backgroundColor: r['entry_type'] == 'له' ? Colors.green.shade50 : Colors.red.shade50, child: Icon(r['entry_type'] == 'له' ? Icons.add : Icons.remove, color: r['entry_type'] == 'له' ? Colors.green : Colors.red)),
        title: Text((r['entry_type'] == 'له' ? 'له ' : 'عليه ') + NumberFormat('#,##0.##').format(r['amount']) + ' ' + r['currency'].toString()),
        subtitle: Text('${r['description'] ?? 'حركة حساب'}\n${r['created_at']}'),
        isThreeLine: true,
      )),
    ]))),
    actions: [
      TextButton.icon(onPressed: () async {
        Navigator.pop(x);
        await customerCreditForm(context, c);
        if (context.mounted) await customerDetails(context, c);
      }, icon: const Icon(Icons.add_card), label: const Text('إضافة دفعة / رصيد')),
      TextButton(onPressed: () => Navigator.pop(x), child: const Text('إغلاق')),
    ],
  )));
}

Future<void> customerCreditForm(BuildContext context, Map<String,Object?> customer) async {
  final amount = TextEditingController();
  final description = TextEditingController(text: 'دفعة من العميل');
  String currency = 'YER';
  await showDialog(context: context, builder: (x) => StatefulBuilder(builder: (x, setLocal) => Directionality(
    textDirection: ui.TextDirection.rtl,
    child: AlertDialog(
      title: Text('تسجيل دفعة • ${customer['full_name']}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        textField(amount, 'مبلغ الدفعة *', numeric: true),
        DropdownButtonFormField<String>(value: currency, decoration: const InputDecoration(labelText: 'العملة'), items: const [
          DropdownMenuItem(value: 'YER', child: Text('ريال يمني YER')),
          DropdownMenuItem(value: 'SAR', child: Text('ريال سعودي SAR')),
          DropdownMenuItem(value: 'USD', child: Text('دولار أمريكي USD')),
        ], onChanged: (v) => setLocal(() => currency = v ?? 'YER')),
        textField(description, 'البيان / السبب'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(x), child: const Text('إلغاء')),
        FilledButton(onPressed: () async {
          final value = double.tryParse(amount.text.trim());
          if (value == null || value <= 0) {
            ScaffoldMessenger.of(x).showSnackBar(const SnackBar(content: Text('أدخل مبلغًا صحيحًا أكبر من صفر.')));
            return;
          }
          await Store.addCustomerCredit(customer['id'] as int, value, currency, description.text.trim());
          if (x.mounted) Navigator.pop(x);
        }, child: const Text('حفظ الدفعة')),
      ],
    ),
  )));
}

Future<void> transferDetails(BuildContext context, Map<String, Object?> r, String actor, bool isAdmin) async {
  await showDialog(context: context, builder: (x) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(
    title: Text('حوالة ' + r['reference_no'].toString()),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      detail('المرسل', r['sender_name']), detail('المستلم', r['receiver_name']), detail('هاتف المستلم', r['receiver_phone']),
      detail('المبلغ', NumberFormat('#,##0.##').format(r['amount']) + ' ' + r['currency'].toString()), detail('الحالة', r['status']), detail('التاريخ', r['transfer_date']), detail('ملاحظات', r['notes']),
    ]),
    actions: [
      if (isAdmin) TextButton.icon(onPressed: () async {
        String nextStatus = r['status'].toString();
        final chosen = await showDialog<String>(context: context, builder: (d) => StatefulBuilder(builder: (d, setChoice) => Directionality(textDirection: ui.TextDirection.rtl, child: AlertDialog(title: const Text('تحديث حالة الحوالة'), content: DropdownButtonFormField<String>(value: nextStatus, items: const [DropdownMenuItem(value: 'قيد الانتظار', child: Text('قيد الانتظار')), DropdownMenuItem(value: 'مكتملة', child: Text('مكتملة')), DropdownMenuItem(value: 'ملغاة', child: Text('ملغاة'))], onChanged: (v) => setChoice(() => nextStatus = v ?? nextStatus)), actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(d, nextStatus), child: const Text('حفظ'))]))));
        if (chosen != null && chosen != r['status']) {
          await Store.updateTransferStatus(r['id'] as int, chosen);
          await Store.audit(actor, 'تغيير حالة حوالة', '${r['reference_no']} • ${r['status']} ← $chosen');
          if (context.mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تحديث حالة الحوالة.'))); }
        }
      }, icon: const Icon(Icons.sync), label: const Text('تغيير الحالة')),
      TextButton(onPressed: () async {
        final receipt = 'ALQUOOD REMIT\\nإيصال حوالة\\n----------------------\\nرقم الحوالة: ${r['reference_no']}\\nالمرسل: ${r['sender_name']}\\nالمستلم: ${r['receiver_name']}\\nهاتف المستلم: ${r['receiver_phone'] ?? '—'}\\nالمبلغ: ${NumberFormat('#,##0.##').format(r['amount'])} ${r['currency']}\\nالحالة: ${r['status']}\\nالتاريخ: ${r['transfer_date']}\\nالموظف: $actor\\n----------------------\\nيرجى الاحتفاظ بهذا الإيصال';
        await Clipboard.setData(ClipboardData(text:receipt));
        await Store.audit(actor,'نسخ إيصال',r['reference_no'].toString());
        if(x.mounted){Navigator.pop(x);ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم نسخ الإيصال. يمكنك لصقه وطباعته.')));}
      }, child: const Text('نسخ الإيصال')),
      TextButton(onPressed: () => Navigator.pop(x), child: const Text('إغلاق')),
    ],
  )));
}

class ActivityLog extends StatelessWidget {
  const ActivityLog({super.key});
  @override Widget build(BuildContext context)=>FutureBuilder<List<Map<String,Object?>>>(future:Store.logs(),builder:(context,s){
    final rows=s.data??[];
    if(s.connectionState==ConnectionState.waiting)return const Center(child:CircularProgressIndicator());
    return rows.isEmpty?const Center(child:Text('لا توجد أنشطة مسجلة بعد')):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final r=rows[i];return Card(margin:const EdgeInsets.symmetric(horizontal:12,vertical:4),child:ListTile(leading:const Icon(Icons.history),title:Text(r['action'].toString()),subtitle:Text('${r['staff_name']} • ${r['details']??''}\\n${r['created_at']}')));});
  });
}

class StaffPage extends StatefulWidget {
  const StaffPage({super.key});
  @override State<StaffPage> createState() => _StaffPageState();
}
class _StaffPageState extends State<StaffPage> {
  int refresh = 0;

  Future<void> add() async {
    final username = TextEditingController();
    final name = TextEditingController();
    final pin = TextEditingController();
    String role = 'موظف';
    await showDialog(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setLocal) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إضافة موظف'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            textField(name, 'اسم الموظف'),
            textField(username, 'اسم المستخدم'),
            textField(pin, 'رمز PIN (4 أرقام على الأقل)'),
            DropdownButtonFormField<String>(
              value: role,
              decoration: const InputDecoration(labelText: 'الصلاحية'),
              items: const [
                DropdownMenuItem(value: 'موظف', child: Text('موظف')),
                DropdownMenuItem(value: 'مدير', child: Text('مدير')),
              ],
              onChanged: (value) => setLocal(() => role = value ?? 'موظف'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || username.text.trim().isEmpty || pin.text.length < 4) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('أكمل البيانات ورمز PIN من 4 أرقام على الأقل.')));
                  return;
                }
                try {
                  await Store.addStaff(username.text, name.text, pin.text, role);
                  await Store.audit('المدير', 'إضافة مستخدم', username.text + ' • ' + role);
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) setState(() => refresh++);
                } catch (_) {
                  if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('اسم المستخدم موجود مسبقًا.')));
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    Padding(
      padding: const EdgeInsets.all(12),
      child: FilledButton.icon(onPressed: add, icon: const Icon(Icons.person_add), label: const Text('إضافة موظف')),
    ),
    Expanded(
      child: FutureBuilder<List<Map<String, Object?>>>(
        key: ValueKey(refresh),
        future: Store.staff(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          final rows = snapshot.data ?? [];
          if (rows.isEmpty) return const Center(child: Text('لا يوجد موظفون.'));
          return ListView(
            children: rows.map<Widget>((row) {
              final active = (row['active'] as int) == 1;
              return Card(
                child: ListTile(
                  leading: Icon(row['role'] == 'مدير' ? Icons.admin_panel_settings : Icons.person),
                  title: Text(row['full_name'].toString()),
                  subtitle: Text('${row['username']} • ${row['role']} • ${active ? 'نشط' : 'موقوف'}'),
                  trailing: IconButton(
                    icon: Icon(active ? Icons.pause_circle_outline : Icons.play_circle_outline),
                    tooltip: active ? 'إيقاف الحساب' : 'تفعيل الحساب',
                    onPressed: () async {
                      if (active && row['role'] == 'مدير' && await Store.activeAdminCount() <= 1) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا يمكن إيقاف آخر حساب مدير نشط.')));
                        return;
                      }
                      await Store.setStaffActive(row['id'] as int, !active);
                      await Store.audit('المدير', active ? 'إيقاف مستخدم' : 'تفعيل مستخدم', row['username'].toString());
                      if (mounted) setState(() => refresh++);
                    },
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    ),
  ]);
}
Widget detail(String label, Object? value) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(label + ': ' + ((value == null || value.toString().isEmpty) ? '—' : value.toString())));
