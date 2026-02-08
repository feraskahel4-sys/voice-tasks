import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  runApp(const MyApp());
}

class TaskItem {
  final String id;
  String title;
  DateTime due;
  int remindHours;
  bool done;

  TaskItem({
    required this.id,
    required this.title,
    required this.due,
    required this.remindHours,
    required this.done,
  });

  Map<String, dynamic> toJson() => {
        "id": id,
        "title": title,
        "due": due.toIso8601String(),
        "remindHours": remindHours,
        "done": done,
      };

  static TaskItem fromJson(Map<String, dynamic> j) => TaskItem(
        id: j["id"],
        title: j["title"],
        due: DateTime.parse(j["due"]),
        remindHours: (j["remindHours"] as num).toInt(),
        done: j["done"] as bool,
      );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'قائمة مهام صوتية',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _titleCtrl = TextEditingController();
  DateTime? _due;
  int _remindHours = 24;

  final _fmt = DateFormat('yyyy/MM/dd  HH:mm', 'ar');
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;

  final FlutterLocalNotificationsPlugin _notifs =
      FlutterLocalNotificationsPlugin();

  List<TaskItem> _tasks = [];
  static const _storeKey = "voice_tasks_v1";

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _load();
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const init = InitializationSettings(android: androidInit);
    await _notifs.initialize(init);

    const channel = AndroidNotificationChannel(
      'tasks_channel',
      'Task Reminders',
      description: 'Reminders for tasks',
      importance: Importance.high,
    );

    final androidPlugin =
        _notifs.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(channel);

    // Android 13+ permission
    await androidPlugin?.requestNotificationsPermission();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(_tasks.map((t) => t.toJson()).toList());
    await prefs.setString(_storeKey, data);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_storeKey);
    if (s == null) return;
    try {
      final list = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
      setState(() {
        _tasks = list.map(TaskItem.fromJson).toList()
          ..sort((a, b) => a.due.compareTo(b.due));
      });
    } catch (_) {}
  }

  int _notifIdFromTask(String id) => id.hashCode & 0x7fffffff;

  Future<void> _scheduleReminder(TaskItem t) async {
    if (t.done) return;

    final remindAt = t.due.subtract(Duration(hours: t.remindHours));
    if (remindAt.isBefore(DateTime.now())) return;

    final androidDetails = AndroidNotificationDetails(
      'tasks_channel',
      'Task Reminders',
      channelDescription: 'Reminders for tasks',
      importance: Importance.high,
      priority: Priority.high,
    );

    final details = NotificationDetails(android: androidDetails);

    await _notifs.zonedSchedule(
      _notifIdFromTask(t.id),
      'تذكير بمهمة',
      '${t.title}\nموعدها: ${_fmt.format(t.due)}',
      tz.TZDateTime.from(remindAt, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> _cancelReminder(TaskItem t) async {
    await _notifs.cancel(_notifIdFromTask(t.id));
  }

  Future<void> _addTask() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _toast("اكتب عنوان المهمة أو استخدم الصوت.");
      return;
    }
    if (_due == null) {
      _toast("اختر تاريخ ووقت المهمة.");
      return;
    }

    final task = TaskItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      due: _due!,
      remindHours: _remindHours,
      done: false,
    );

    setState(() {
      _tasks.add(task);
      _tasks.sort((a, b) => a.due.compareTo(b.due));
      _titleCtrl.clear();
      _due = null;
      _remindHours = 24;
    });

    await _scheduleReminder(task);
    await _save();
  }

  Future<void> _toggleDone(TaskItem t, bool v) async {
    setState(() => t.done = v);
    if (v) {
      await _cancelReminder(t);
    } else {
      await _scheduleReminder(t);
    }
    await _save();
  }

  Future<void> _delete(TaskItem t) async {
    await _cancelReminder(t);
    setState(() => _tasks.removeWhere((x) => x.id == t.id));
    await _save();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: DateTime(now.year + 5),
      initialDate: now,
    );
    if (d == null) return;

    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (t == null) return;

    setState(() {
      _due = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    });
  }

  Future<void> _startStopListening() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }

    final ok = await _speech.initialize(
      onStatus: (s) {
        if (s == 'notListening' && mounted) {
          setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
        _toast("تأكد من السماح بالمايك.");
      },
    );

    if (!ok) {
      _toast("التعرف الصوتي غير متاح على هذا الجهاز.");
      return;
    }

    setState(() => _listening = true);
    await _speech.listen(
      localeId: 'ar-SA',
      listenMode: stt.ListenMode.dictation,
      onResult: (r) {
        if (r.finalResult) {
          final text = r.recognizedWords.trim();
          if (text.isNotEmpty) {
            _titleCtrl.text =
                (_titleCtrl.text.trim().isEmpty) ? text : '${_titleCtrl.text} $text';
          }
        }
      },
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('قائمة مهام صوتية'),
          actions: [
            IconButton(
              onPressed: () async {
                for (final t in _tasks) {
                  await _cancelReminder(t);
                  await _scheduleReminder(t);
                }
                _toast("تم تحديث التذكيرات.");
              },
              icon: const Icon(Icons.notifications_active_outlined),
              tooltip: 'تحديث التذكيرات',
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'عنوان المهمة',
                        hintText: 'مثال: إرسال التقرير للمدير',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickDue,
                            icon: const Icon(Icons.event),
                            label: Text(
                              _due == null
                                  ? 'اختيار التاريخ/الوقت'
                                  : _fmt.format(_due!),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: _startStopListening,
                          icon: Icon(_listening ? Icons.stop : Icons.mic),
                          label: Text(_listening ? 'إيقاف' : 'صوت'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text('التذكير قبل (ساعة):'),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Slider(
                            min: 0,
                            max: 168,
                            divisions: 168,
                            value: _remindHours.toDouble(),
                            label: '$_remindHours',
                            onChanged: (v) =>
                                setState(() => _remindHours = v.round()),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '$_remindHours',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _addTask,
                      icon: const Icon(Icons.add),
                      label: const Text('إضافة مهمة'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('المهام', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 6),
            if (_tasks.isEmpty)
              const Text('لا توجد مهام بعد.')
            else
              ..._tasks.map((t) => Card(
                    child: ListTile(
                      title: Text(
                        t.title,
                        style: TextStyle(
                          decoration: t.done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      subtitle: Text(
                        'الموعد: ${_fmt.format(t.due)}\nتذكير قبل: ${t.remindHours} ساعة',
                      ),
                      isThreeLine: true,
                      leading: Checkbox(
                        value: t.done,
                        onChanged: (v) => _toggleDone(t, v ?? false),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(t),
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}
