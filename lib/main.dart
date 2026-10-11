import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:call_log/call_log.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

const ac = Color(0xFFFF6B8A), cardC = Color(0xFFF8EEF3), bg = Color(0xFFF1E6EE), line = Color(0xFFE6D5DE);
const shade = Color(0xFFD2BCC9), ink = Color(0xFF3B2F3A), softPink = Color(0xFFFFD6E0);
const clayBorder = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none);

/// Claymorphism: soft, puffy shapes with a light top-left glow and a soft bottom-right shadow.
BoxDecoration clay({double r = 24, Color? c}) {
  final base = c ?? cardC;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(r),
    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(base, Colors.white, 0.4)!, base]),
    boxShadow: [
      BoxShadow(color: Color.lerp(base, shade, 0.7)!.withOpacity(0.8), offset: const Offset(8, 10), blurRadius: 20),
      const BoxShadow(color: Colors.white, offset: Offset(-6, -6), blurRadius: 14),
    ],
  );
}

class Clay extends StatelessWidget {
  final Widget child;
  final double r;
  final Color? c;
  final EdgeInsets pad;
  final VoidCallback? onTap, onLongPress;
  const Clay({super.key, required this.child, this.r = 24, this.c, this.pad = EdgeInsets.zero, this.onTap, this.onLongPress});
  @override
  Widget build(BuildContext ctx) => Container(
        decoration: clay(r: r, c: c),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(r),
          child: InkWell(
            borderRadius: BorderRadius.circular(r),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(padding: pad, child: child),
          ),
        ),
      );
}

ThemeData clayTheme() {
  final base = ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    scaffoldBackgroundColor: bg,
    colorScheme: ColorScheme.fromSeed(seedColor: ac, brightness: Brightness.light).copyWith(primary: ac, onPrimary: Colors.white, surface: cardC),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(backgroundColor: ac, foregroundColor: Colors.white, elevation: 6, shadowColor: shade, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)))),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: ink, backgroundColor: cardC, elevation: 4, shadowColor: shade, side: BorderSide.none, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)))),
    inputDecorationTheme: const InputDecorationTheme(filled: true, fillColor: cardC),
  );
}

/// All app state and Firebase logic lives here.
class A {
  static late SharedPreferences p;
  static bool online = true, _started = false, _warned = false, _lnReady = false;
  static String? uid, pid;
  static String _wp = '';
  static Map<String, dynamic> me = {}, pn = {'name': 'Partner'};
  static Map<String, dynamic>? lo;
  static Position? my;
  static List<Map<String, dynamic>> calls = [], msgs = [];
  static final bump = ValueNotifier<int>(0);
  static final msg = GlobalKey<ScaffoldMessengerState>();
  static final _subs = <StreamSubscription>[];
  static final _seen = <String>{};
  static StreamSubscription<Position>? _w;
  static StreamSubscription? _pu, _pl;
  static Timer? _t1, _t2, _t3;
  static DateTime _t = DateTime(2000);
  static final ln = FlutterLocalNotificationsPlugin();
  static FirebaseFirestore get db => FirebaseFirestore.instance;
  static void refresh() => bump.value++;
  static void toast(String t, {int s = 3}) => msg.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t), duration: Duration(seconds: s)));

  static Future<bool> initFb() async {
    final k = p.getString('fb_key') ?? '', a = p.getString('fb_app') ?? '';
    final s = p.getString('fb_sender') ?? '', j = p.getString('fb_project') ?? '';
    if ([k, a, s, j].any((e) => e.isEmpty)) return false;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: FirebaseOptions(apiKey: k, appId: a, messagingSenderId: s, projectId: j));
    }
    return true;
  }

  static Future<void> load() async {
    final user = FirebaseAuth.instance.currentUser!;
    uid = user.uid;
    try {
      final r = db.collection('users').doc(uid);
      if (!(await r.get()).exists) {
        await r.set({
          'name': (user.email ?? 'Me').split('@').first, 'partner': '',
          'share_location': true, 'share_calls': true, 'share_messages': true, 'share_battery': true,
        });
      }
    } catch (_) {}
    if (!_started) {
      _started = true;
      _subs.add(db.collection('users').doc(uid).snapshots(includeMetadataChanges: true).listen((d) {
        online = !d.metadata.isFromCache;
        me = d.data() ?? me;
        _watchPartner();
        refresh();
      }, onError: (_) {}));
      _subs.add(db.collection('events').where('to', isEqualTo: uid).snapshots().listen(_onEvents, onError: (_) {}));
      _t1 = Timer.periodic(const Duration(minutes: 5), (_) {
        if (my != null) push(my!, force: true);
      });
      _t2 = Timer.periodic(const Duration(minutes: 5), (_) => syncPhone());
      _t3 = Timer.periodic(const Duration(seconds: 30), (_) {
        if (pid != null && (pn['pending'] == true || lo == null)) {
          _wp = '';
          _watchPartner();
        }
      });
      _initNotif();
    }
    _track();
    syncPhone();
  }

  static void _watchPartner() {
    final n = '${me['partner'] ?? ''}';
    if (n == _wp) return;
    _wp = n;
    _pu?.cancel();
    _pl?.cancel();
    pid = n.isEmpty ? null : n;
    lo = null;
    pn = {'name': 'Partner'};
    if (pid == null) return;
    _pu = db.collection('users').doc(pid).snapshots().listen((d) {
      pn = d.data() ?? pn;
      refresh();
    }, onError: (_) {
      pn = {'name': 'Partner', 'pending': true};
      refresh();
    });
    _pl = db.collection('locations').doc(pid).snapshots().listen((d) {
      lo = d.data();
      refresh();
    }, onError: (_) {
      lo = null;
      refresh();
    });
  }

  static void _onEvents(QuerySnapshot<Map<String, dynamic>> s) {
    for (final c in s.docChanges) {
      if (c.type != DocumentChangeType.added || _seen.contains(c.doc.id)) continue;
      _seen.add(c.doc.id);
      final d = c.doc.data();
      if (d == null) continue;
      final at = d['at'];
      if (at is Timestamp && DateTime.now().difference(at.toDate()).inMinutes > 5) continue;
      _alert('${d['kind']}');
    }
  }

  static Future<void> _initNotif() async {
    try {
      await ln.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      await ln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      _lnReady = true;
    } catch (_) {}
  }

  static void _alert(String kind) {
    final s = kind == 'sos', n = '${pn['name']}';
    final text = s ? '$n needs help!' : '$n misses you 💗';
    Vibration.vibrate(pattern: s ? [0, 800, 200, 800, 200, 800, 200, 800] : [0, 200, 100, 200, 100, 400]);
    if (_lnReady) {
      ln
          .show(s ? 2 : 1, s ? '🚨 Emergency' : '💗 Miss you', text,
              NotificationDetails(android: AndroidNotificationDetails(s ? 'sos' : 'miss', s ? 'Emergency' : 'Miss you', importance: Importance.max, priority: Priority.high)))
          .catchError((_) {});
    }
    msg.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        backgroundColor: s ? ac : Colors.white,
        duration: Duration(seconds: s ? 60 : 6),
        showCloseIcon: s,
        content: Text(text, style: TextStyle(color: s ? Colors.white : Colors.black, fontWeight: FontWeight.bold)),
      ));
  }

  static void ev(String k) {
    if (pid == null) return toast('Add your partner ID in the Privacy tab first', s: 4);
    db.collection('events').add({'from': uid, 'to': pid, 'kind': k, 'at': FieldValue.serverTimestamp()}).then((_) {}, onError: (_) => toast('Could not send. Has your partner added your ID too?', s: 4));
    toast(online ? (k == 'sos' ? 'Emergency sent to ${pn['name']}' : "Sent. ${pn['name']}'s phone is buzzing") : 'Offline. It will send when you are online');
  }

  static Future<void> push(Position x, {bool force = false}) async {
    if (uid == null || me['share_location'] == false) return;
    if (!force && DateTime.now().difference(_t).inSeconds < 60) return;
    _t = DateTime.now();
    int? b;
    try {
      if (me['share_battery'] != false) b = await Battery().batteryLevel;
    } catch (_) {}
    db.collection('locations').doc(uid).set({
      'lat': x.latitude, 'lng': x.longitude, 'accuracy': x.accuracy, 'battery': b,
      'activity': x.speed > 0.8 ? 'Moving' : 'Still', 'updated_at': FieldValue.serverTimestamp(),
    }).catchError((_) {});
  }

  static Future<void> _track() async {
    if (_w != null) return;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return toast('Location is blocked. Allow it in phone settings', s: 5);
    }
    _w = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
        intervalDuration: const Duration(seconds: 30),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'ALU Tracker',
          notificationText: 'Sharing your location with ${pn['name']}',
          enableWakeLock: true,
        ),
      ),
    ).listen((x) {
      my = x;
      push(x);
      refresh();
    });
  }

  static Future<List<Map<String, dynamic>>> _fetch(String c) async {
    final out = <Map<String, dynamic>>[];
    for (final o in [pid, uid]) {
      if (o == null || o.isEmpty) continue;
      try {
        final s = await db.collection(c).where('owner', isEqualTo: o).get();
        out.addAll(s.docs.map((d) => d.data()));
      } catch (_) {}
    }
    int ms(Map<String, dynamic> m) => (m['at'] is Timestamp) ? (m['at'] as Timestamp).millisecondsSinceEpoch : 0;
    out.sort((a, b) => ms(b).compareTo(ms(a)));
    return out.take(150).toList();
  }

  static Future<void> pull() async {
    if (uid == null) return;
    calls = await _fetch('calls');
    msgs = await _fetch('messages');
    refresh();
  }

  static String _dir(CallType? t) => t == CallType.outgoing
      ? 'outgoing'
      : (t == CallType.missed || t == CallType.rejected || t == CallType.blocked)
          ? 'missed'
          : 'incoming';

  static String _digits(String? s) => (s ?? '').replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');

  /// Copy this phone's call log and SMS to Firestore (only what you switched on).
  static Future<void> syncPhone() async {
    if (uid == null) return;
    final day14 = DateTime.now().subtract(const Duration(days: 14)).millisecondsSinceEpoch;
    try {
      if (me['share_calls'] != false) {
        if ((await Permission.phone.request()).isGranted) {
          final since = p.getInt('calls_since') ?? day14, now = DateTime.now().millisecondsSinceEpoch;
          final es = (await CallLog.query(dateFrom: since)).toList();
          for (var i = 0; i < es.length; i += 400) {
            final b = db.batch();
            for (final e in es.skip(i).take(400)) {
              final ms = e.timestamp ?? 0;
              b.set(db.collection('calls').doc('${uid}_${ms}_${_digits(e.number)}'), {
                'owner': uid,
                'contact': (e.name?.isNotEmpty ?? false) ? e.name : (e.number ?? 'Unknown'),
                'direction': _dir(e.callType),
                'duration_sec': e.duration ?? 0,
                'at': Timestamp.fromMillisecondsSinceEpoch(ms),
              });
            }
            b.commit().catchError((_) {});
          }
          await p.setInt('calls_since', now - 60000);
        } else if (!_warned) {
          _warned = true;
          toast('Allow Phone permission in settings to share call history', s: 5);
        }
      }
      if (me['share_messages'] != false) {
        if ((await Permission.sms.request()).isGranted) {
          final since = p.getInt('sms_since') ?? day14, now = DateTime.now().millisecondsSinceEpoch;
          final all = await SmsQuery().querySms(kinds: [SmsQueryKind.inbox, SmsQueryKind.sent], count: 200);
          final ms = all.where((m) => (m.date?.millisecondsSinceEpoch ?? 0) >= since).toList();
          for (var i = 0; i < ms.length; i += 400) {
            final b = db.batch();
            for (final m in ms.skip(i).take(400)) {
              final t = m.date!.millisecondsSinceEpoch, sent = m.kind == SmsMessageKind.sent;
              b.set(db.collection('messages').doc('${uid}_${t}_${sent ? 'o' : 'i'}_${_digits(m.address)}'), {
                'owner': uid,
                'contact': m.address ?? 'Unknown',
                'direction': sent ? 'out' : 'in',
                'body': m.body ?? '',
                'at': Timestamp.fromMillisecondsSinceEpoch(t),
              });
            }
            b.commit().catchError((_) {});
          }
          await p.setInt('sms_since', now - 60000);
        } else if (!_warned) {
          _warned = true;
          toast('Allow SMS permission in settings to share messages', s: 5);
        }
      }
    } catch (_) {}
  }

  static Future<void> out() async {
    for (final x in _subs) {
      await x.cancel();
    }
    _subs.clear();
    await _pu?.cancel();
    await _pl?.cancel();
    await _w?.cancel();
    _w = null;
    _t1?.cancel();
    _t2?.cancel();
    _t3?.cancel();
    _started = false;
    uid = null;
    pid = null;
    _wp = '';
    lo = null;
    me = {};
    await FirebaseAuth.instance.signOut();
  }
}

DateTime? ts(dynamic t) => t is Timestamp ? t.toDate() : (t == null ? null : DateTime.tryParse('$t'));

Widget cardW(Widget c) => Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: clay(r: 26),
      child: c,
    );

String tm(dynamic t) {
  final d = (ts(t) ?? DateTime.now()).toLocal();
  return '${d.day}/${d.month} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  A.p = await SharedPreferences.getInstance();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'ALU Tracker',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: A.msg,
        theme: clayTheme(),
        home: const Gate(),
      );
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _G();
}

class _G extends State<Gate> {
  String s = A.p.getString('consent') == null ? 'consent' : 'lock';
  void go(String x) => setState(() => s = x);

  Future<void> boot() async {
    try {
      if (!await A.initFb()) return go('api');
      if (FirebaseAuth.instance.currentUser == null) return go('login');
      await A.load();
    } catch (_) {
      A.toast('Could not load everything. Check your internet', s: 4);
    }
    go('home');
  }

  @override
  Widget build(BuildContext c) => switch (s) {
        'consent' => ConsentScreen(onAgree: () => go('lock')),
        'lock' => LockScreen(onOk: boot),
        'api' => ApiScreen(onNext: boot),
        'login' => LoginScreen(onOk: boot),
        _ => Home(onLock: () => go('lock'), onApi: () => go('api'), onOut: () => go('login')),
      };
}

class LockScreen extends StatefulWidget {
  final VoidCallback onOk;
  const LockScreen({super.key, required this.onOk});
  @override
  State<LockScreen> createState() => _L();
}

class _L extends State<LockScreen> {
  String pin = '';
  final set = A.p.getString('pin') == null;

  @override
  void initState() {
    super.initState();
    if (!set) bio();
  }

  Future<void> bio() async {
    try {
      final la = LocalAuthentication();
      if (await la.canCheckBiometrics &&
          await la.authenticate(
              localizedReason: 'Unlock ALU Tracker', options: const AuthenticationOptions(biometricOnly: true))) {
        widget.onOk();
      }
    } catch (_) {}
  }

  void tap(String k) {
    setState(() {
      if (k == '<') {
        if (pin.isNotEmpty) pin = pin.substring(0, pin.length - 1);
      } else if (pin.length < 4) {
        pin += k;
      }
    });
    if (pin.length == 4) {
      final p = pin;
      setState(() => pin = '');
      if (set) {
        A.p.setString('pin', p);
        widget.onOk();
      } else if (p == A.p.getString('pin')) {
        widget.onOk();
      } else {
        A.toast('Wrong PIN');
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'bio', '0', '<'];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SizedBox(
            width: 280,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Clay(r: 40, c: ac, pad: const EdgeInsets.all(22), child: const Text('💗', style: TextStyle(fontSize: 34))),
              const SizedBox(height: 18),
              const Text('ALU Tracker', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(set ? 'Create a 4-digit PIN' : 'Enter your PIN', style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    margin: const EdgeInsets.all(7), width: 14, height: 14,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: i < pin.length ? ac : null, border: Border.all(color: ac, width: 2)),
                  ),
              ]),
              const SizedBox(height: 22),
              GridView.count(
                crossAxisCount: 3, shrinkWrap: true, mainAxisSpacing: 12, crossAxisSpacing: 12,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final k in keys)
                    k == 'bio'
                        ? (set ? const SizedBox() : IconButton(onPressed: bio, icon: const Icon(Icons.fingerprint, size: 32, color: ac)))
                        : Clay(r: 40, onTap: () => tap(k), child: Center(child: Text(k == '<' ? '⌫' : k, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)))),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class ApiScreen extends StatefulWidget {
  final VoidCallback onNext;
  const ApiScreen({super.key, required this.onNext});
  @override
  State<ApiScreen> createState() => _Ap();
}

class _Ap extends State<ApiScreen> {
  final fk = TextEditingController(text: A.p.getString('fb_key') ?? '');
  final fa = TextEditingController(text: A.p.getString('fb_app') ?? '');
  final fs = TextEditingController(text: A.p.getString('fb_sender') ?? '');
  final fj = TextEditingController(text: A.p.getString('fb_project') ?? '');

  Future<void> save() async {
    final v = {'fb_key': fk.text.trim(), 'fb_app': fa.text.trim(), 'fb_sender': fs.text.trim(), 'fb_project': fj.text.trim()};
    final changed = Firebase.apps.isNotEmpty && v.entries.any((e) => A.p.getString(e.key) != e.value);
    for (final e in v.entries) {
      await A.p.setString(e.key, e.value);
    }
    if (changed) return A.toast('Saved. Close and reopen the app to use the new values', s: 5);
    widget.onNext();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('API connection', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Paste the 4 values from your Firebase Android app (google-services.json). They stay on this phone.', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 18),
            TextField(controller: fk, obscureText: true, decoration: const InputDecoration(labelText: 'API key (current_key, starts with AIza)', border: clayBorder)),
            const SizedBox(height: 14),
            TextField(controller: fa, decoration: const InputDecoration(labelText: 'App ID (mobilesdk_app_id, 1:123:android:abc)', border: clayBorder)),
            const SizedBox(height: 14),
            TextField(controller: fs, decoration: const InputDecoration(labelText: 'Sender ID (project_number)', border: clayBorder)),
            const SizedBox(height: 14),
            TextField(controller: fj, decoration: const InputDecoration(labelText: 'Project ID (project_id)', border: clayBorder)),
            const SizedBox(height: 18),
            FilledButton(onPressed: save, child: const Padding(padding: EdgeInsets.all(12), child: Text('Save and continue'))),
          ]),
        ),
      );
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onOk;
  const LoginScreen({super.key, required this.onOk});
  @override
  State<LoginScreen> createState() => _Lo();
}

class _Lo extends State<LoginScreen> {
  final e = TextEditingController(), w = TextEditingController();
  bool busy = false;

  Future<void> login() async {
    setState(() => busy = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: e.text.trim(), password: w.text);
      widget.onOk();
    } on FirebaseAuthException catch (x) {
      A.toast(x.message ?? 'Could not sign in', s: 4);
    } catch (_) {
      A.toast('Could not sign in. Check your internet');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('Sign in', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Use the login you created in Firebase.', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 18),
            TextField(controller: e, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: clayBorder)),
            const SizedBox(height: 14),
            TextField(controller: w, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: clayBorder)),
            const SizedBox(height: 18),
            FilledButton(onPressed: busy ? null : login, child: const Padding(padding: EdgeInsets.all(12), child: Text('Sign in'))),
          ]),
        ),
      );
}

class Home extends StatefulWidget {
  final VoidCallback onLock, onApi, onOut;
  const Home({super.key, required this.onLock, required this.onApi, required this.onOut});
  @override
  State<Home> createState() => _H();
}

class _H extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext c) => Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: A.bump,
          builder: (_, __, ___) => IndexedStack(index: tab, children: [
            const MapTab(),
            const ListTab(calls: true),
            const ListTab(calls: false),
            SettingsTab(onLock: widget.onLock, onApi: widget.onApi, onOut: widget.onOut),
          ]),
        ),
        bottomNavigationBar: Container(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          decoration: clay(r: 30),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: NavigationBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          indicatorColor: softPink,
          selectedIndex: tab,
          onDestinationSelected: (i) {
            setState(() => tab = i);
            A.pull();
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
            NavigationDestination(icon: Icon(Icons.call_outlined), label: 'Calls'),
            NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Messages'),
            NavigationDestination(icon: Icon(Icons.shield_outlined), label: 'Privacy'),
          ],
        ),
          ),
        ),
      );
}

class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _M();
}

class _M extends State<MapTab> {
  final mc = MapController();
  bool fitted = false;

  void fit(List<LatLng> p) {
    if (p.isEmpty) return;
    if (p.length == 1) {
      mc.move(p.first, 15);
    } else {
      mc.fitCamera(CameraFit.coordinates(coordinates: p, padding: const EdgeInsets.all(80), maxZoom: 16));
    }
  }

  Widget dot(String t) => Container(
        decoration: BoxDecoration(color: softPink, shape: BoxShape.circle, border: Border.all(color: ac, width: 2)),
        alignment: Alignment.center,
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Future<void> sos() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Send emergency alert?'),
        content: Text('${A.pn['name']}\'s phone will be alerted right away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send SOS')),
        ],
      ),
    );
    if (ok == true) A.ev('sos');
  }

  @override
  Widget build(BuildContext c) {
    final l = A.lo, m = A.my, n = '${A.pn['name']}';
    LatLng? pl = l == null ? null : LatLng((l['lat'] as num).toDouble(), (l['lng'] as num).toDouble());
    LatLng? ml = m == null ? null : LatLng(m.latitude, m.longitude);
    final pts = [if (pl != null) pl, if (ml != null) ml];
    if (!fitted && pts.isNotEmpty) {
      fitted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => fit(pts));
    }
    String info = A.pid == null ? 'Add your partner ID in the Privacy tab' : (A.pn['pending'] == true ? 'Waiting for $n to add your ID too' : 'Waiting for $n to open the app and share');
    if (l != null) {
      final mins = DateTime.now().difference(ts(l['updated_at']) ?? DateTime.now()).inMinutes;
      final d = m == null ? null : Geolocator.distanceBetween(m.latitude, m.longitude, pl!.latitude, pl.longitude);
      info = [
        l['activity'] ?? 'Sharing',
        if (d != null) (d < 1000 ? '${d.round()} m away' : '${(d / 1000).toStringAsFixed(1)} km away'),
        if (l['battery'] != null) '${l['battery']}% battery',
        mins < 1 ? 'just now' : '$mins min ago',
      ].join(' · ');
    }
    return Stack(children: [
      FlutterMap(
        mapController: mc,
        options: MapOptions(initialCenter: pts.isEmpty ? const LatLng(20.59, 78.96) : pts.first, initialZoom: pts.isEmpty ? 4 : 15),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.alu.alu_tracker'),
          MarkerLayer(markers: [
            if (pl != null) Marker(point: pl, width: 52, height: 52, child: dot(n.isEmpty ? '?' : n[0])),
            if (ml != null)
              Marker(
                point: ml, width: 20, height: 20,
                child: Container(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: ac, width: 3))),
              ),
          ]),
        ],
      ),
      SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: clay(r: 20),
            child: Text(A.online ? '● Synced · Online' : '● Offline · changes sync later',
                style: TextStyle(color: A.online ? const Color(0xFF37D67A) : const Color(0xFFF0B34A), fontSize: 12)),
          ),
        ),
      ),
      Positioned(
        right: 12, top: 60,
        child: SafeArea(child: FloatingActionButton.small(onPressed: () => fit(pts), child: const Icon(Icons.my_location))),
      ),
      Positioned(
        left: 12, right: 12, bottom: 12,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          cardW(Row(children: [
            CircleAvatar(backgroundColor: softPink, child: Text(n.isEmpty ? '?' : n[0])),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(info, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ])),
          ])),
          Row(children: [
            Expanded(
              child: Clay(
                r: 28, c: ac, pad: const EdgeInsets.symmetric(vertical: 18), onTap: () => A.ev('miss_you'),
                child: const Center(child: Text('💗 Miss you', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Clay(
                r: 28, c: const Color(0xFFE5484D), pad: const EdgeInsets.symmetric(vertical: 18),
                onTap: () => A.toast('Press and hold to send SOS'), onLongPress: sos,
                child: const Center(child: Text('🚨 Hold for SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

class ListTab extends StatefulWidget {
  final bool calls;
  const ListTab({super.key, required this.calls});
  @override
  State<ListTab> createState() => _Li();
}

class _Li extends State<ListTab> {
  int tab = 0;
  @override
  Widget build(BuildContext c) {
    final owner = tab == 1 ? A.uid : A.pid;
    final rows = (widget.calls ? A.calls : A.msgs).where((r) => r['owner'] == owner).toList();
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(18), children: [
        Text(widget.calls ? 'Call history' : 'Messages', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 0, label: Text("${A.pn['name']}'s")),
            ButtonSegment(value: 1, label: Text("${A.me['name'] ?? 'My'}'s")),
          ],
          selected: {tab},
          onSelectionChanged: (s) => setState(() => tab = s.first),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty) cardW(const Text('Nothing here yet. It appears after the first sync, a few minutes after each phone allows the permission.', style: TextStyle(color: Colors.grey))),
        for (final r in rows)
          cardW(Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['contact']}', style: TextStyle(color: r['direction'] == 'missed' ? const Color(0xFFD64560) : null)),
              Text(widget.calls ? '${r['direction']}${(r['duration_sec'] ?? 0) > 0 ? ' · ${((r['duration_sec'] as int) / 60).round()} min' : ''}' : '${r['body']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ])),
            Text(tm(r['at']), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ])),
      ]),
    );
  }
}

class SettingsTab extends StatefulWidget {
  final VoidCallback onLock, onApi, onOut;
  const SettingsTab({super.key, required this.onLock, required this.onApi, required this.onOut});
  @override
  State<SettingsTab> createState() => _S();
}

class _S extends State<SettingsTab> {
  final nc = TextEditingController(), pc = TextEditingController();

  void tog(String k, bool v) {
    A.me[k] = v;
    A.refresh();
    A.db.collection('users').doc(A.uid).update({k: v}).catchError((_) => A.toast('Could not save'));
    if (k == 'share_location' && v && A.my != null) A.push(A.my!, force: true);
    if ((k == 'share_calls' || k == 'share_messages') && v) A.syncPhone();
  }

  void save() {
    final u = <String, dynamic>{};
    if (nc.text.trim().isNotEmpty) u['name'] = nc.text.trim();
    final x = pc.text.trim();
    if (x.isNotEmpty) {
      if (x == A.uid) return A.toast("That is your own ID. Paste your partner's ID");
      u['partner'] = x;
    }
    if (u.isEmpty) return;
    A.db.collection('users').doc(A.uid).update(u).catchError((_) => A.toast('Could not save'));
    A.toast('Saved');
  }

  Widget sw(String t, String sub, String k) => SwitchListTile(
      title: Text(t), subtitle: Text(sub), value: A.me[k] != false, activeColor: ac, onChanged: (v) => tog(k, v));

  @override
  Widget build(BuildContext c) {
    final st = A.pid == null ? 'Not paired yet' : (A.pn['pending'] == true ? 'Waiting for your partner to add your ID' : 'Paired with ${A.pn['name']}');
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(18), children: [
        const Text('Privacy and pairing', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        cardW(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('My ID (send this to your partner)', style: TextStyle(color: Colors.grey, fontSize: 12)),
          Row(children: [
            Expanded(child: SelectableText(A.uid ?? '', style: const TextStyle(fontSize: 13))),
            IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: A.uid ?? ''));
                  A.toast('ID copied');
                }),
          ]),
          const SizedBox(height: 8),
          TextField(controller: nc, decoration: InputDecoration(labelText: 'My name (now: ${A.me['name'] ?? ''})', border: clayBorder)),
          const SizedBox(height: 10),
          TextField(controller: pc, decoration: const InputDecoration(labelText: "Partner's ID (paste here)", border: clayBorder)),
          const SizedBox(height: 8),
          Text(st, style: const TextStyle(color: ac)),
          const SizedBox(height: 8),
          FilledButton(onPressed: save, child: const Text('Save')),
        ])),
        Text("${A.pn['name']} sees only what is switched on here.", style: const TextStyle(color: Colors.grey)),
        sw('Share my location', 'Live location and activity', 'share_location'),
        sw('Share call history', 'Synced from this phone every few minutes', 'share_calls'),
        sw('Share messages', 'Synced from this phone every few minutes', 'share_messages'),
        sw('Battery level', 'Shown next to your location', 'share_battery'),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const ConsentScreen())), child: const Padding(padding: EdgeInsets.all(12), child: Text('Privacy policy'))),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: widget.onLock, child: const Padding(padding: EdgeInsets.all(12), child: Text('Lock app now'))),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: widget.onApi, child: const Padding(padding: EdgeInsets.all(12), child: Text('API keys'))),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () async {
            await A.out();
            widget.onOut();
          },
          child: const Padding(padding: EdgeInsets.all(12), child: Text('Sign out')),
        ),
      ]),
    );
  }
}

class ConsentScreen extends StatelessWidget {
  final VoidCallback? onAgree;
  const ConsentScreen({super.key, this.onAgree});

  Widget sec(String t, String b) => cardW(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 6),
        Text(b, style: const TextStyle(color: Color(0xFF6B5C68), height: 1.4)),
      ]));

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: onAgree == null ? AppBar(backgroundColor: bg, title: const Text('Privacy policy')) : null,
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            if (onAgree != null) ...[
              const Text('Before we start', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('ALU Tracker is for two people who both agree to share. Each of you taps "I agree" on your own phone.', style: TextStyle(color: Color(0xFF6B5C68))),
              const SizedBox(height: 18),
            ],
            sec('What is shared', 'Only with the one person you pair with: your live location and battery level, your call history, and your text messages (SMS). Each item is optional and can be switched off in the Privacy tab at any time.'),
            sec('Who can see it', 'Only your paired partner, and only after you both add each other\'s ID. Nobody else can see it.'),
            sec('Why', 'To show where you are, to send Miss you and Emergency alerts, and to show the shared call and message lists. It is not used for ads and is never sold.'),
            sec('Where it is stored', 'On your phone, and in a private Firebase (Google) database that you two set up, in the Mumbai region. The copy on your phone lets the app work offline.'),
            sec('Always visible', 'While your location is shared, Android shows a notification. The app has no hidden mode.'),
            sec('Permissions asked', 'Location (including in the background), Phone (call history), SMS (messages), Notifications, and fingerprint or face unlock for the app lock.'),
            sec('Your control', 'Pause sharing or turn off calls and messages in the Privacy tab, sign out, or uninstall the app at any time. You can also delete your data in the Firebase console.'),
            if (onAgree != null) ...[
              const SizedBox(height: 6),
              Clay(
                r: 28, c: ac, pad: const EdgeInsets.symmetric(vertical: 18),
                onTap: () {
                  A.p.setString('consent', DateTime.now().toIso8601String());
                  onAgree!();
                },
                child: const Center(child: Text('I agree', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: () => SystemNavigator.pop(), child: const Text('No thanks, close the app')),
            ],
          ]),
        ),
      );
}
