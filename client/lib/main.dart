import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models/models.dart';
import 'screens/inbox_screen.dart';
import 'screens/schedules_screen.dart';
import 'screens/settings_screen.dart';
import 'state/app_store.dart';
import 'theme/apple_tokens.dart';
import 'widgets/alarm_ringing_overlay.dart';
import 'widgets/app_shell.dart';
import 'widgets/notification_inspector.dart';
import 'widgets/schedule_editor_modal.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DinglinApp());
}

class DinglinApp extends StatefulWidget {
  const DinglinApp({super.key, this.store});

  final AppStore? store;

  @override
  State<DinglinApp> createState() => _DinglinAppState();
}

class _DinglinAppState extends State<DinglinApp> with WidgetsBindingObserver {
  late final AppStore _store;
  late final bool _ownsStore;
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsStore = widget.store == null;
    _store = widget.store ?? AppStore();
    if (_ownsStore) {
      final defaultOrigin = kIsWeb ? Uri.base.origin : '';
      _store.init(defaultWebOrigin: defaultOrigin);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store.onAppResumed();
    } else if (state == AppLifecycleState.paused &&
        _store.platform.supportsKeepAlive) {
      _store.onAppPaused();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocus.dispose();
    if (_ownsStore) _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final mode = switch (_store.themePreference) {
          ThemePreference.light => ThemeMode.light,
          ThemePreference.dark => ThemeMode.dark,
          ThemePreference.system => ThemeMode.system,
        };
        return MaterialApp(
          title: 'Dinglin',
          debugShowCheckedModeBanner: false,
          theme: AppleTokens.buildTheme(Brightness.light),
          darkTheme: AppleTokens.buildTheme(Brightness.dark),
          themeMode: mode,
          home: _WorkspaceHome(store: _store, searchFocus: _searchFocus),
        );
      },
    );
  }
}

class _WorkspaceHome extends StatelessWidget {
  const _WorkspaceHome({
    required this.store,
    required this.searchFocus,
  });

  final AppStore store;
  final FocusNode searchFocus;

  @override
  Widget build(BuildContext context) {
    final body = switch (store.activeTab) {
      AppTab.inbox => InboxScreen(store: store, searchFocusNode: searchFocus),
      AppTab.schedules => SchedulesScreen(store: store),
      AppTab.settings => SettingsScreen(store: store),
    };

    final selectedNotif = store.selectedNotification;
    final inspector =
        store.activeTab == AppTab.inbox && selectedNotif != null
            ? NotificationInspector(store: store, notification: selectedNotif)
            : null;
    final ringing = store.ringingAlarm;

    return Stack(
      children: [
        AppShell(
          store: store,
          body: body,
          inspector: inspector,
          onFocusSearch: () {
            if (store.activeTab != AppTab.inbox) {
              store.setTab(AppTab.inbox);
            }
            searchFocus.requestFocus();
          },
          onCreateSchedule: () {
            showScheduleEditorModal(context, store: store);
          },
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: ringing == null,
            child: AnimatedSwitcher(
              duration: AppleTokens.motion,
              switchInCurve: AppleTokens.motionCurve,
              switchOutCurve: AppleTokens.motionCurve,
              child: ringing == null
                  ? const SizedBox.shrink()
                  : AlarmRingingOverlay(
                      key: ValueKey(ringing.id),
                      store: store,
                      schedule: ringing,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
