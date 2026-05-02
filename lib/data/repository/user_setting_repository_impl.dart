import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../db/app_database.dart';
import '../model/user_setting.dart';
import 'user_setting_repository.dart';

// SQLiteを使った実装
class UserSettingRepositoryImpl implements UserSettingRepository {
  @override
  Future<bool> isFirstLaunch() async {
    final db = await AppDatabase.database;

    final result = await db.query('user_setting');

    // 🔵 1件も無い場合は「初回起動」
    if (result.isEmpty) {
      return true;
    }

    return result.first['is_first_launch'] == 1;
  }

  @override
  Future<void> markFirstLaunchCompleted() async {
    final db = await AppDatabase.database;

    await db.update(
      'user_setting',
      {'is_first_launch': 0},
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  @override
  Future<void> saveUserSetting(UserSetting setting) async {
    final db = await AppDatabase.database;

    await db.delete('user_setting', where: 'id != ?', whereArgs: [1]);

    final values = setting.toMap();
    values['id'] = 1;
    await db.insert(
      'user_setting',
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<UserSetting?> loadUserSetting() async {
    final db = await AppDatabase.database;

    final result = await db.query('user_setting', limit: 1);

    if (result.isEmpty) return null;

    return UserSetting.fromMap(result.first);
  }

  @override
  Future<DateTime?> getLastUsedDate() async {
    final db = await AppDatabase.database;

    final result = await db.query(
      'user_setting',
      where: 'id = ?',
      whereArgs: [1],
    );

    if (result.isEmpty) return null;

    final value = result.first['last_used_date'];
    if (value == null) return null;

    return DateTime.parse(value as String);
  }

  @override
  Future<void> setLastUsedDate(DateTime date) async {
    final db = await AppDatabase.database;

    await db.update(
      'user_setting',
      {'last_used_date': date.toIso8601String().split('T').first},
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  // デバッグ用: user_settingテーブルの内容を表示
  @override
  Future<void> debugPrintUserSetting() async {
    debugPrint('====[user_setting]====');
    final db = await AppDatabase.database;

    final result = await db.query('user_setting');

    if (result.isEmpty) {
      debugPrint('user_setting: データなし');
      return;
    }

    final row = result.first;

    final isFirstLaunch = row['is_first_launch'] == 1;
    final lastUsedDate = row['last_used_date'] as String?;

    String fmtTime(String hourKey, String minuteKey) {
      final hour = row[hourKey];
      final minute = row[minuteKey];
      if (hour == null || minute == null) return 'null';
      return 'TimeOfDay(hour: $hour, minute: $minute)';
    }

    debugPrint('-isFirstLaunch: $isFirstLaunch,');
    debugPrint('-lastUsedDate: ${lastUsedDate ?? 'null'},');
    debugPrint(
      '-workStart: ${fmtTime('work_start_hour', 'work_start_minute')},',
    );
    debugPrint('-workEnd: ${fmtTime('work_end_hour', 'work_end_minute')},');
    debugPrint(
      '-sleepStart: ${fmtTime('sleep_start_hour', 'sleep_start_minute')},',
    );
    debugPrint('-sleepEnd: ${fmtTime('sleep_end_hour', 'sleep_end_minute')},');
    debugPrint('=====================');
  }
}

// 簡易的なInMemory実装（動作確認用）
class InMemoryUserSettingRepository implements UserSettingInMemory {
  bool _firstLaunch = true;

  @override
  bool isFirstLaunch() {
    return _firstLaunch;
  }

  @override
  void markFirstLaunchCompleted() {
    _firstLaunch = false;
  }
}
