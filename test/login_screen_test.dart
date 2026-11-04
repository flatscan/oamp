import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/ui/login_screen.dart';

void main() {
  testWidgets('the form switches between password and API key', (t) async {
    await t.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'API key'), findsNothing);

    await t.tap(find.text('Use an API key instead'));
    await t.pump();
    expect(find.widgetWithText(TextFormField, 'API key'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsNothing);

    await t.tap(find.text('Use a username and password instead'));
    await t.pump();
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
  });

  testWidgets('signing in again fills in the saved server', (t) async {
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: LoginScreen(
            initialServerUrl: 'https://nd.home.lan',
            initialUsername: 'ed',
            onSignedIn: () {},
          ),
        ),
      ),
    );
    expect(find.text('https://nd.home.lan'), findsOneWidget);
    expect(find.text('ed'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
  });
}
