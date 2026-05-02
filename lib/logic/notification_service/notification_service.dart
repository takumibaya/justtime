import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../data/model/feedback.dart';
import '../../data/model/notification_log.dart';
import '../../data/repository/notification_log_repository.dart';

/// 通知アクションボタンのID。バックグラウンドでも使うため定数。
const String kActionGood = 'action_good';
const String kActionEarlier = 'action_earlier';
const String kActionLater = 'action_later';

const String kPayloadDaily = 'daily';
const String kPayloadTest = 'test';

List<AndroidNotificationAction> feedbackActions() {
  return const [
    AndroidNotificationAction(
      kActionGood,
      'ありがとう',
      showsUserInterface: false,
      cancelNotification: true,
    ),
    AndroidNotificationAction(
      kActionEarlier,
      'なんで今頃',
      showsUserInterface: true,
      cancelNotification: false,
    ),
    AndroidNotificationAction(
      kActionLater,
      'まだまだ頑張れるよ',
      showsUserInterface: true,
      cancelNotification: false,
    ),
  ];
}

/// actionId → FeedbackType.index の対応。
int? _actionIdToFeedbackIndex(String? actionId) {
  switch (actionId) {
    case kActionGood:
      return FeedbackType.goodTiming.index;
    case kActionEarlier:
      // 「もう少し早く」= 今回は遅かった
      return FeedbackType.tooLate.index;
    case kActionLater:
      // 「もう少し後」= 今回は早かった
      return FeedbackType.tooEarly.index;
    default:
      return null;
  }
}

/// フィードバック種別に応じて、翌日の通知時刻を ±30分 調整。workStart/sleepStart で範囲内に丸める。
({int hour, int minute}) _adjustNextNotifyTime({
  required int currentHour,
  required int currentMinute,
  required int feedbackIndex,
  int? workStartHour,
  int? workStartMinute,
  int? sleepStartHour,
  int? sleepStartMinute,
}) {
  int totalMinutes = currentHour * 60 + currentMinute;
  if (feedbackIndex == FeedbackType.tooEarly.index) {
    totalMinutes += 30;
  } else if (feedbackIndex == FeedbackType.tooLate.index) {
    totalMinutes -= 30;
  }
  totalMinutes = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60);

  if (workStartHour != null && workStartMinute != null) {
    final workStartTotal = workStartHour * 60 + workStartMinute;
    if (totalMinutes < workStartTotal) {
      totalMinutes = workStartTotal;
    }
  }
  if (sleepStartHour != null && sleepStartMinute != null) {
    final sleepStartTotal = sleepStartHour * 60 + sleepStartMinute;
    if (totalMinutes >= sleepStartTotal) {
      totalMinutes = sleepStartTotal;
    }
  }

  return (hour: totalMinutes ~/ 60, minute: totalMinutes % 60);
}

Future<void> _bgDebugLog(String msg) async {
  try {
    final dir = Directory.systemTemp;
    final f = File('${dir.path}/justtime_bg.log');
    await f.writeAsString(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// バックグラウンドisolateから呼ばれるため top-level かつ vm:entry-point 指定必須。
@pragma('vm:entry-point')
Future<void> notificationActionHandler(NotificationResponse response) async {
  await _bgDebugLog('ENTER actionId=${response.actionId}');
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await _bgDebugLog('Flutter binding OK');

    final feedbackIndex = _actionIdToFeedbackIndex(response.actionId);
    if (feedbackIndex == null) {
      await _bgDebugLog('Unknown actionId, skip');
      return;
    }

    if (response.actionId != kActionGood) {
      await _bgDebugLog('Non-good action, defer to app foreground');
      return;
    }

    final path = p.join(await getDatabasesPath(), 'justtime.db');
    await _bgDebugLog('db path=$path');
    final db = await openDatabase(path);
    await _bgDebugLog('db opened');

    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));
      final todayKey = today.toIso8601String().split('T').first;
      final tomorrowKey = tomorrow.toIso8601String().split('T').first;

      final existing = await db.query(
        'daily_state',
        where: 'date = ?',
        whereArgs: [todayKey],
      );

      int currentHour = 20;
      int currentMinute = 0;
      if (existing.isEmpty) {
        await db.insert('daily_state', {
          'date': todayKey,
          'notify_hour': currentHour,
          'notify_minute': currentMinute,
          'feedback_completed': 1,
          'feedback_type': feedbackIndex,
        });
      } else {
        final current = Map<String, dynamic>.from(existing.first);
        currentHour = (current['notify_hour'] as int?) ?? 20;
        currentMinute = (current['notify_minute'] as int?) ?? 0;
        current['feedback_completed'] = 1;
        current['feedback_type'] = feedbackIndex;
        await db.update(
          'daily_state',
          current,
          where: 'date = ?',
          whereArgs: [todayKey],
        );
      }

      int? workStartHour;
      int? workStartMinute;
      int? sleepStartHour;
      int? sleepStartMinute;
      try {
        final settingRows = await db.query('user_setting', limit: 1);
        if (settingRows.isNotEmpty) {
          final row = settingRows.first;
          workStartHour = row['work_start_hour'] as int?;
          workStartMinute = row['work_start_minute'] as int?;
          sleepStartHour = row['sleep_start_hour'] as int?;
          sleepStartMinute = row['sleep_start_minute'] as int?;
        }
      } catch (e) {
        await _bgDebugLog('user_setting read failed: $e');
      }

      // 明日の通知時刻を算出して保存
      final next = _adjustNextNotifyTime(
        currentHour: currentHour,
        currentMinute: currentMinute,
        feedbackIndex: feedbackIndex,
        workStartHour: workStartHour,
        workStartMinute: workStartMinute,
        sleepStartHour: sleepStartHour,
        sleepStartMinute: sleepStartMinute,
      );
      await db.insert('daily_state', {
        'date': tomorrowKey,
        'notify_hour': next.hour,
        'notify_minute': next.minute,
        'feedback_completed': 0,
        'feedback_type': null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _bgDebugLog('tomorrow notify=${next.hour}:${next.minute}');

      await db.insert('notification_log', {
        'event_type': NotificationEventType.feedbackSubmitted.name,
        'timestamp': DateTime.now().toIso8601String(),
        'notify_hour': currentHour,
        'notify_minute': currentMinute,
        'feedback_type': feedbackIndex,
        'note':
            'via action=${response.actionId} next=${next.hour}:${next.minute}',
      });
      await _bgDebugLog('DB updated OK');

      // 明日の通知時刻でスケジュール更新（id=0の日次通知を置き換え）
      try {
        tzdata.initializeTimeZones();
        tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
        final plugin = FlutterLocalNotificationsPlugin();
        const androidInit = AndroidInitializationSettings(
          '@mipmap/ic_launcher',
        );
        await plugin.initialize(
          const InitializationSettings(android: androidInit),
        );
        final tzNow = tz.TZDateTime.now(tz.local);
        var fire = tz.TZDateTime(
          tz.local,
          tzNow.year,
          tzNow.month,
          tzNow.day,
          next.hour,
          next.minute,
        );
        if (fire.isBefore(tzNow)) {
          fire = fire.add(const Duration(days: 1));
        }
        await plugin.zonedSchedule(
          0,
          '今日もお疲れさまでした',
          '今日の声かけ、いかがでしたか？',
          fire,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'daily_channel',
              'Daily Notification',
              importance: Importance.max,
              priority: Priority.high,
              actions: feedbackActions(),
            ),
          ),
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time,
        );
        await _bgDebugLog('rescheduled daily at $fire');
      } catch (e) {
        await _bgDebugLog('reschedule failed: $e');
      }
    } finally {
      await db.close();
      await _bgDebugLog('db closed');
    }
  } catch (e, st) {
    await _bgDebugLog('ERROR $e\n$st');
    debugPrint('[notificationActionHandler][ERROR] $e\n$st');
  }
}

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final NotificationLogRepository logRepository;

  bool _initialized = false;

  static VoidCallback? onFeedbackRequested;
  static bool pendingFeedback = false;

  NotificationService(this.logRepository);

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    final iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          'daily_feedback',
          actions: [
            DarwinNotificationAction.plain(kActionGood, 'ありがとう'),
            DarwinNotificationAction.plain(
              kActionEarlier,
              'なんで今頃',
              options: {DarwinNotificationActionOption.foreground},
            ),
            DarwinNotificationAction.plain(
              kActionLater,
              'まだまだ頑張れるよ',
              options: {DarwinNotificationActionOption.foreground},
            ),
          ],
        ),
      ],
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleNotificationTapped,
      onDidReceiveBackgroundNotificationResponse: notificationActionHandler,
    );

    _initialized = true;
  }

  Future<void> requestPermission() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();

    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);
  }

  void _handleNotificationTapped(NotificationResponse response) {
    // アクションボタン経由の場合はフィードバックも保存
    if (response.actionId != null) {
      notificationActionHandler(response);
    }
    logRepository.insert(
      NotificationLog(
        eventType: NotificationEventType.fired,
        timestamp: DateTime.now(),
        note:
            'payload=${response.payload ?? ''} '
            'actionId=${response.actionId ?? ''}',
      ),
    );

    final isGoodAction = response.actionId == kActionGood;
    if (!isGoodAction) {
      pendingFeedback = true;
      onFeedbackRequested?.call();
    }
  }

  NotificationScheduler get scheduler =>
      NotificationScheduler(_plugin, logRepository);
}

class NotificationScheduler {
  final FlutterLocalNotificationsPlugin _plugin;
  final NotificationLogRepository _logRepository;

  NotificationScheduler(this._plugin, this._logRepository);

  NotificationDetails _detailsWithActions() {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_channel',
        'Daily Notification',
        importance: Importance.max,
        priority: Priority.high,
        actions: feedbackActions(),
      ),
      iOS: const DarwinNotificationDetails(
        categoryIdentifier: 'daily_feedback',
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: true,
      ),
    );
  }

  Future<void> scheduleDaily(TimeOfDay time) async {
    final now = tz.TZDateTime.now(tz.local);

    final scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );

    final tzDate = scheduled.isBefore(now)
        ? scheduled.add(const Duration(days: 1))
        : scheduled;

    await _plugin.zonedSchedule(
      0,
      '今日もお疲れさまでした',
      '今日の声かけ、いかがでしたか？',
      tzDate,
      _detailsWithActions(),
      payload: kPayloadDaily,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
    debugPrint('[NotificationScheduler] Scheduled at $tzDate');

    await _logRepository.insert(
      NotificationLog(
        eventType: NotificationEventType.scheduled,
        timestamp: DateTime.now(),
        notifyTime: time,
        note: 'scheduled=$tzDate',
      ),
    );
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await _logRepository.insert(
      NotificationLog(
        eventType: NotificationEventType.cancelled,
        timestamp: DateTime.now(),
        note: 'cancelAll',
      ),
    );
  }

  /// 1分後に一度だけテスト通知を送る（日次スケジュールとは別のID）
  Future<DateTime> scheduleTestInOneMinute() async {
    final now = tz.TZDateTime.now(tz.local);
    final fireAt = now.add(const Duration(minutes: 1));

    await _plugin.zonedSchedule(
      99,
      '[テスト] 今日もお疲れさまでした',
      '今日の声かけ、いかがでしたか？',
      fireAt,
      _detailsWithActions(),
      payload: kPayloadTest,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );

    await _logRepository.insert(
      NotificationLog(
        eventType: NotificationEventType.scheduled,
        timestamp: DateTime.now(),
        note: 'test fireAt=$fireAt',
      ),
    );

    debugPrint('[NotificationScheduler] Test scheduled at $fireAt');
    return fireAt;
  }
}
