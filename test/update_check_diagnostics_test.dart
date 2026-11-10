import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/app_updates.dart';
import 'package:oamp/core/app_version.dart';
import 'package:oamp/core/build_info.dart';
import 'package:oamp/core/diagnostics.dart';
import 'package:oamp/platform/external_actions.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/app_updates.dart';
import 'package:oamp/state/diagnostics.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/browse/about_section.dart';
import 'package:oamp/ui/theme.dart';
import 'package:oamp/ui/update_banner.dart';

class FakeFeed implements ReleaseFeed {
  List<String> tags;
  bool fail = false;
  int calls = 0;
  FakeFeed(this.tags);

  @override
  Future<List<ReleaseInfo>> releases() async {
    calls++;
    if (fail) throw const ReleaseFeedException('offline');
    return [
      for (final t in tags)
        ReleaseInfo(
          tag: t,
          version: AppVersion.tryParse(t)!,
          page: Uri.parse('https://github.com/flatscan/oamp/releases/tag/$t'),
        ),
    ];
  }
}

class RecordingActions implements ExternalActions {
  final List<Uri> opened = [];

  @override
  Future<bool> openUrl(Uri url) async {
    opened.add(url);
    return true;
  }

  @override
  Future<bool> openFolder(String path) async => true;

  @override
  Future<bool> shareFile(String path, {required String subject}) async => true;
}

void main() {
  group('AppVersion', () {
    AppVersion v(String s) => AppVersion.tryParse(s)!;

    test('reads release tags', () {
      expect(
        v('v1.0.0-Alpha1'),
        const AppVersion(1, 0, 0, stage: 'alpha', stageNumber: 1),
      );
      expect(v('1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('nightly'), isNull);
      expect(AppVersion.tryParse('v1.0.0-Banana2'), isNull);
    });

    test('orders alphas, betas, release candidates and releases', () {
      final order = [
        'v1.0.0-Alpha1',
        'v1.0.0-Alpha2',
        'v1.0.0-Alpha10',
        'v1.0.0-Beta1',
        'v1.0.0-RC1',
        'v1.0.0',
        'v1.0.1-Alpha1',
        'v1.1.0',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(v(order[i]) > v(order[i - 1]), isTrue, reason: order[i]);
      }
    });
  });

  test('GitHub list skips drafts and odd tags, and only links to GitHub', () {
    final releases = GitHubReleaseFeed.parse('''[
      {"tag_name": "v1.0.0-Alpha2", "draft": true, "html_url": "https://github.com/x"},
      {"tag_name": "v1.0.0-Alpha1", "draft": false, "html_url": "https://evil.example/x"},
      {"tag_name": "test", "draft": false, "html_url": "https://github.com/y"}
    ]''');
    expect(releases.map((r) => r.tag), ['v1.0.0-Alpha1']);
    expect(releases.single.page, GitHubReleaseFeed.releasesPage);
  });

  group('Redactor', () {
    test('hides addresses, credentials, users and known values', () {
      final r = Redactor()
        ..hide('music.tail1234.ts.net', '<server>')
        ..hide('edjackson', '<user>');
      final out = r(
        'ClientException: Connection refused, '
        'uri=https://music.tail1234.ts.net:4533/rest/ping?u=edjackson&t=abc&s=def '
        'SocketException: Failed host lookup: \'other.host.lan\' '
        'address = 192.168.101.89, port = 4533 '
        'fe80::1ff:fe23:4567:890a '
        'mail ed@example.com '
        r'C:\Users\EdJackson\AppData\oamp.log /home/ed/x '
        'music.tail1234.ts.net said no to EDJACKSON',
      );
      for (final leak in [
        'tail1234',
        'edjackson',
        'EdJackson',
        'EDJACKSON',
        'other.host',
        '192.168',
        'fe80',
        'example.com',
        't=abc',
        '/home/ed',
      ]) {
        expect(out, isNot(contains(leak)), reason: leak);
      }
      expect(out, contains('<url>'));
      expect(out, contains('<server> said no to <user>'));
    });

    test('leaves times, durations and versions alone', () {
      final r = Redactor();
      const line = 'Seek to 0:03:12 at 12:30:45 on Navidrome 0.64.2 (track t1)';
      expect(r(line), line);
    });

    test('ignores very short values', () {
      final r = Redactor()..hide('ed', '<user>');
      expect(r('loaded the queue'), 'loaded the queue');
    });

    test('matches known values as whole tokens, not inside words or tags', () {
      for (final user in ['art', 'url', 'play']) {
        final r = Redactor()..hide(user, '<user>');
        expect(
          r(
            'https://nas.local/x user $user u=$user '
            'start artwork playing <url> (${user.toUpperCase()})',
          ),
          '<url> user <user> u=<hidden> '
          'start artwork playing <url> (<user>)',
        );
      }
    });
  });

  test('log keeps redacted, stamped lines and returns the newest', () async {
    final log = DiagnosticsLog(
      MemoryLogStore(),
      now: () => DateTime(2026, 11, 7, 20),
    );
    for (var i = 0; i < 5; i++) {
      log.add('line $i');
    }
    log.add('failed https://my.server/rest?t=1\n  at frame');
    final recent = await log.recent(maxLines: 3);
    expect(recent.split('\n'), [
      '2026-11-07T20:00:00.000 line 4',
      '2026-11-07T20:00:00.000 failed <url>',
      '      at frame',
    ]);
  });

  test('log redacts again with values learnt later', () async {
    final log = DiagnosticsLog(MemoryLogStore());
    log.add('could not reach nas.local');
    log.redact.hide('nas.local', '<server>');
    expect(await log.recent(), contains('could not reach <server>'));
  });

  group('update check', () {
    late ProviderContainer container;
    late FakeFeed feed;
    late MemoryPreferences prefs;

    ProviderContainer make({String tag = 'v1.0.0-Alpha1'}) {
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          releaseFeedProvider.overrideWithValue(feed),
          buildInfoProvider.overrideWithValue(BuildInfo(releaseTag: tag)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      feed = FakeFeed(['v1.0.0-Alpha1', 'v1.0.0-Alpha2']);
      prefs = MemoryPreferences();
      container = make();
    });

    AppUpdates notifier() => container.read(appUpdatesProvider.notifier);
    AppUpdatesState state() => container.read(appUpdatesProvider);

    test('does nothing until the user says yes', () async {
      expect(state().choice, UpdateCheckChoice.unasked);
      await notifier().checkIfDue();
      expect(feed.calls, 0);
    });

    test('announces a newer release once per version', () async {
      await notifier().setEnabled(true);
      await pumpEventQueue();
      expect(feed.calls, 1);
      expect(state().available?.tag, 'v1.0.0-Alpha2');
      expect(state().announce?.tag, 'v1.0.0-Alpha2');

      // Next launch, a day later: still available, but not announced again.
      prefs.setInt(
        'oamp.update.lastCheckMs',
        DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      );
      container = make();
      await notifier().checkIfDue();
      expect(feed.calls, 2);
      expect(state().available?.tag, 'v1.0.0-Alpha2');
      expect(state().announce, isNull);
    });

    test('checks at most once a day', () async {
      await notifier().setEnabled(true);
      await pumpEventQueue();
      await notifier().checkIfDue();
      expect(feed.calls, 1);
    });

    test('up to date when this is the newest release', () async {
      container = make(tag: 'v1.0.0-Alpha2');
      await notifier().check(manual: true);
      expect(state().latest?.tag, 'v1.0.0-Alpha2');
      expect(state().available, isNull);
    });

    test('test builds never check on their own or offer updates', () async {
      container = make(tag: '');
      await notifier().setEnabled(true);
      await pumpEventQueue();
      expect(feed.calls, 0);
      await notifier().check(manual: true);
      expect(state().latest?.tag, 'v1.0.0-Alpha2');
      expect(state().available, isNull);
    });

    test('a failed check says so in words', () async {
      feed.fail = true;
      await notifier().check(manual: true);
      expect(state().error, isNotNull);
      expect(state().checking, isFalse);
    });
  });

  group('screens', () {
    Widget app(ProviderContainer c, Widget child) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    testWidgets('banner opens the release page and goes away', (tester) async {
      final actions = RecordingActions();
      final c = ProviderContainer(
        overrides: [
          releaseFeedProvider.overrideWithValue(FakeFeed(['v1.0.0-Alpha2'])),
          buildInfoProvider.overrideWithValue(
            const BuildInfo(releaseTag: 'v1.0.0-Alpha1'),
          ),
          externalActionsProvider.overrideWithValue(actions),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c, const UpdateBanner()));
      expect(find.textContaining('is available'), findsNothing);
      await c.read(appUpdatesProvider.notifier).check();
      await tester.pumpAndSettle();
      expect(find.text('OAmp v1.0.0-Alpha2 is available.'), findsOneWidget);
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(actions.opened.single.path, endsWith('/tag/v1.0.0-Alpha2'));
      expect(find.textContaining('is available'), findsNothing);
      c.read(appUpdatesProvider.notifier).setEnabled(false);
    });

    testWidgets('first launch asks, and the answer is kept', (tester) async {
      final prefs = MemoryPreferences();
      final c = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        app(
          c,
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => askAboutUpdateChecks(context, ref),
              child: const Text('launch'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('launch'));
      await tester.pumpAndSettle();
      expect(find.text('Check for updates?'), findsOneWidget);
      await tester.tap(find.text('No thanks'));
      await tester.pumpAndSettle();
      expect(prefs.getBool('oamp.update.check'), isFalse);
      expect(c.read(appUpdatesProvider).choice, UpdateCheckChoice.off);
    });

    testWidgets('copied diagnostics hold no personal details', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      final log = DiagnosticsLog(MemoryLogStore());
      log.redact.hide('nas.example.org', '<server>');
      log.add(
        'Playback failed: http://nas.example.org/rest/stream?id=t1&u=ed&t=x',
      );
      final c = ProviderContainer(
        overrides: [
          diagnosticsLogProvider.overrideWithValue(log),
          buildInfoProvider.overrideWithValue(const BuildInfo(ciRun: '123')),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c, const AboutSection()));
      expect(find.text('Test build #123'), findsOneWidget);
      await tester.tap(find.text('Copy diagnostics'));
      await tester.pumpAndSettle();
      expect(copied, contains('App: OAmp Test build #123'));
      expect(copied, contains('Server: not signed in'));
      expect(copied, contains('Playback failed: <url>'));
      expect(copied, isNot(contains('nas.example')));
      expect(copied, isNot(contains('u=ed')));
    });
  });
}
