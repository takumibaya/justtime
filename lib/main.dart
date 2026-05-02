import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'logic/app_start/app_start_service.dart';
import 'logic/state/state_judge_service.dart';
import 'logic/initial_setup/initial_setup_service.dart';
import 'logic/notification_service/notification_service.dart';
import 'logic/notification_time/notification_time_service.dart';
import 'logic/feedback/feedback_service.dart';
import 'logic/log_export/log_export_service.dart';
import 'logic/settings/settings_service.dart';

import 'data/repository/user_setting_repository_impl.dart';
import 'data/repository/user_setting_repository.dart';
import 'data/repository/daily_state_repository.dart';
import 'data/repository/notification_log_repository.dart';
import 'data/db/app_database.dart';
import 'data/model/app_state.dart';
import 'data/model/feedback.dart';

import 'ui/tutorial/tutorial_page.dart';
import 'ui/message/message_page.dart';
import 'ui/feedback/feedback_page.dart';
import 'ui/settings/settings_page.dart';
import 'ui/menu/app_menu.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));

  runApp(const JustTimeApp());
}

class JustTimeApp extends StatelessWidget {
  const JustTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      title: 'justtime',
      home: AppRoot(),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

// [TODO] app_start_service.dart内に移植
class EntryService {
  final UserSettingRepository userSettingRepository;
  final AppStartService appStartService;
  final StateJudgeService stateJudgeService;

  EntryService({
    required this.userSettingRepository,
    required this.appStartService,
    required this.stateJudgeService,
  });

  Future<AppState> onAppStart() async {
    debugPrint('[EntryService] onAppStart');

    final isFirstLaunch = await userSettingRepository.isFirstLaunch();

    if (isFirstLaunch) {
      return AppState.tutorial;
    }

    await appStartService.handleDateChange();
    return await stateJudgeService.judgeState();
  }

  Future<AppState> completeTutorial() async {
    return await stateJudgeService.judgeState();
  }
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  late EntryService entryService;
  late FeedbackService feedbackService;
  late UserSettingRepository userSettingRepository;
  late DailyStateRepository dailyStateRepository;
  late NotificationLogRepository notificationLogRepository;
  late InitialSetupService initialSetupService;
  late LogExportService logExportService;
  late SettingsService settingsService;
  late NotificationService notificationService;

  AppState? _appState;
  bool _isProcessingLifecycle = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initializeServices();
    _startApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.onFeedbackRequested = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _handleResume();
    }
  }

  Future<void> _handleResume() async {
    if (_isProcessingLifecycle) return;

    _isProcessingLifecycle = true;
    debugPrint('[Lifecycle] App Resumed');

    try {
      final state = await entryService.onAppStart();

      if (mounted) {
        setState(() {
          _appState = NotificationService.pendingFeedback
              ? AppState.waitingFeedback
              : state;
          NotificationService.pendingFeedback = false;
        });
      }
    } finally {
      _isProcessingLifecycle = false;
    }
  }

  void _initializeServices() {
    userSettingRepository = UserSettingRepositoryImpl();
    dailyStateRepository = DailyStateRepository(AppDatabase.database);
    notificationLogRepository = NotificationLogRepository(
      AppDatabase.database,
    );

    notificationService = NotificationService(notificationLogRepository);
    NotificationService.onFeedbackRequested = _showFeedbackFromNotification;
    final notificationTimeService = NotificationTimeService(
      notificationService,
      userSettingRepository: userSettingRepository,
    );

    initialSetupService = InitialSetupService(
      userSettingRepository,
      notificationService,
    );

    final appStartService = AppStartService(
      userSettingRepository,
      notificationTimeService,
    );

    final stateJudgeService = StateJudgeService(dailyStateRepository);

    feedbackService = FeedbackService(
      dailyStateRepository,
      stateJudgeService,
      notificationTimeService,
      notificationLogRepository,
    );

    entryService = EntryService(
      userSettingRepository: userSettingRepository,
      appStartService: appStartService,
      stateJudgeService: stateJudgeService,
    );

    logExportService = LogExportService(notificationLogRepository);
    settingsService = SettingsService(userSettingRepository);
  }

  Future<void> _startApp() async {
    try {
      await notificationService.init();
    } catch (e, st) {
      debugPrint('[NotificationService.init][ERROR] $e\n$st');
    }

    final state = await entryService.onAppStart();

    if (mounted) {
      setState(() {
        _appState = NotificationService.pendingFeedback
            ? AppState.waitingFeedback
            : state;
        NotificationService.pendingFeedback = false;
      });
    }

    await userSettingRepository.debugPrintUserSetting();
    await dailyStateRepository.debugPrintAll();
    await notificationLogRepository.debugPrintAll();
  }

  void _showFeedbackFromNotification() {
    if (!mounted) return;
    setState(() {
      _appState = AppState.waitingFeedback;
      NotificationService.pendingFeedback = false;
    });
  }

  Future<TimeOfDay?> _loadTodayNotifyTime() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final state = await dailyStateRepository.getByDate(today);
    return state?.notifyTime;
  }

  Future<void> _handleOpenMenu() async {
    await showAppMenu(
      context,
      loadTodayNotifyTime: _loadTodayNotifyTime,
      onOpenSettings: _handleOpenSettings,
      onExportLog: _handleExportLog,
      onTestNotification: _handleTestNotification,
    );
  }

  Future<void> _handleTestNotification() async {
    try {
      // 念のため通知許可を確認
      await notificationService.requestPermission();
      final fireAt =
          await notificationService.scheduler.scheduleTestInOneMinute();
      if (!mounted) return;
      final hh = fireAt.hour.toString().padLeft(2, '0');
      final mm = fireAt.minute.toString().padLeft(2, '0');
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('テスト通知を予約しました'),
          content: Text(
            '$hh:$mm（約1分後）に通知されます。\nホームボタン等でアプリを閉じて待ってみてください。',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e, st) {
      debugPrint('[TestNotification][ERROR] $e\n$st');
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('テスト通知の予約に失敗しました'),
          content: Text('$e'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _handleOpenSettings() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => SettingsPage(settingsService: settingsService),
      ),
    );
  }

  Future<void> _handleExportLog() async {
    try {
      final savedPath = await logExportService.exportToDownloads();
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('CSVをダウンロードしました'),
          content: Text('保存先: $savedPath\n\n「ファイル」アプリのダウンロードフォルダから確認できます。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e, st) {
      debugPrint('[LogExport][ERROR] $e\n$st');
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('書き出しに失敗しました'),
          content: Text('$e'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_appState == null) {
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }

    switch (_appState!) {
      case AppState.tutorial:
        return TutorialPage(
          onCompleted: () {
            entryService.completeTutorial().then((state) {
              if (mounted) {
                setState(() {
                  _appState = state;
                });
              }
            });
          },
          initialSetupService: initialSetupService,
        );

      case AppState.beforeNotification:
        return MessagePage(
          message: 'まだまだ\n頑張りましょう！',
          onOpenMenu: _handleOpenMenu,
        );

      case AppState.waitingFeedback:
        return FeedbackPage(
          onOpenMenu: _handleOpenMenu,
          onFeedbackSubmitted: (FeedbackType type, int? adjustMinutes) async {
            await feedbackService.submitFeedback(
              type,
              adjustMinutes: adjustMinutes,
            );
            final state = await feedbackService.completeFeedback();
            if (mounted) {
              setState(() {
                _appState = state;
              });
            }
          },
        );

      case AppState.completed:
        return MessagePage(
          message: '今日もお疲れさまでした',
          onOpenMenu: _handleOpenMenu,
        );
    }
  }
}
