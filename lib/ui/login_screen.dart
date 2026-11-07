import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import 'server_address_field.dart';

class LoginScreen extends ConsumerStatefulWidget {
  /// Filled in when the saved server asks to sign in again.
  final String? initialServerUrl;
  final String? initialUsername;

  /// Start on the API key form rather than username and password.
  final bool initialApiKey;

  /// The saved away address, when signing in again.
  final String? initialAwayUrl;

  /// Called after a successful sign-in when the screen was pushed on top of
  /// the app (signing in again) rather than shown in its place.
  final VoidCallback? onSignedIn;

  const LoginScreen({
    super.key,
    this.initialServerUrl,
    this.initialUsername,
    this.initialApiKey = false,
    this.initialAwayUrl,
    this.onSignedIn,
  });

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  late final _url = ServerAddressController(widget.initialServerUrl);
  late final _away = ServerAddressController(widget.initialAwayUrl);
  late bool _showAway = (widget.initialAwayUrl ?? '').isNotEmpty;
  late final _user = TextEditingController(text: widget.initialUsername);
  final _pass = TextEditingController();
  final _key = TextEditingController();
  late bool _useKey = widget.initialApiKey;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _away.dispose();
    _user.dispose();
    _pass.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit({bool keepUnreachableAway = false}) async {
    if (!_form.currentState!.validate()) return;
    // Put the keyboard away so a sign-in error shows above it.
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionProvider.notifier);
      final away = _showAway ? _away.url : '';
      // Signing in again with the address already saved: don't ask again
      // if it can't be reached from here.
      final keep =
          keepUnreachableAway ||
          (away.isNotEmpty && away == widget.initialAwayUrl);
      if (_useKey) {
        await session.loginSubsonicWithApiKey(
          serverUrl: _url.url,
          apiKey: _key.text,
          awayUrl: away,
          keepUnreachableAway: keep,
        );
      } else {
        await session.loginSubsonic(
          serverUrl: _url.url,
          username: _user.text,
          password: _pass.text,
          awayUrl: away,
          keepUnreachableAway: keep,
        );
      }
      widget.onSignedIn?.call();
    } on AwayAddressUnreachable catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final keep = await _askKeepAway(e.reason);
      if (!mounted || keep == null) return;
      if (!keep) setState(() => _showAway = false);
      await _submit(keepUnreachableAway: true);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks whether to keep an away address that didn't answer. True keeps
  /// it, false signs in without it, null goes back to the form.
  Future<bool?> _askKeepAway(String reason) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Away address not reached'),
      content: Text(
        'Your server answered, but not at the away address:\n\n$reason\n\n'
        'Many home networks can\'t reach their own public address, so it may '
        'still work when you\'re away. Settings will show a warning until '
        'OAmp has connected through it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Leave it out'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save anyway'),
        ),
      ],
    ),
  );

  Widget _showHide() => IconButton(
    tooltip: _obscure ? 'Show' : 'Hide',
    icon: Icon(
      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
    ),
    onPressed: () => setState(() => _obscure = !_obscure),
  );

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: widget.onSignedIn == null
          ? null
          : AppBar(title: const Text('Sign in again')),
      // Clear of the status and navigation bars; the Scaffold already
      // shrinks the body for the keyboard, and scrolling puts it away.
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.graphic_eq,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'OAmp',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium,
                      ),
                      Text(
                        'Connect to your Navidrome server',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                      ServerAddressField(
                        controller: _url,
                        label: 'Server address',
                        hint: 'music.example.com',
                        validator: _required,
                        textInputAction: TextInputAction.next,
                      ),
                      if (_showAway) ...[
                        const SizedBox(height: 12),
                        ServerAddressField(
                          key: const ValueKey('away-address'),
                          controller: _away,
                          label: 'Away address (optional)',
                          helper:
                              'Used when the server address can\'t be '
                              'reached, such as away from home.',
                          warnUnencrypted: true,
                          textInputAction: TextInputAction.next,
                        ),
                      ] else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _showAway = true),
                            child: const Text('Add an away address'),
                          ),
                        ),
                      const SizedBox(height: 12),
                      if (_useKey)
                        TextFormField(
                          controller: _key,
                          obscureText: _obscure,
                          decoration: InputDecoration(
                            labelText: 'API key',
                            helperText: 'For servers that support API keys.',
                            prefixIcon: const Icon(Icons.key_rounded),
                            suffixIcon: _showHide(),
                          ),
                          validator: _required,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.go,
                          onFieldSubmitted: (_) => _busy ? null : _submit(),
                        )
                      else ...[
                        TextFormField(
                          controller: _user,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.username],
                          validator: _required,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _pass,
                          obscureText: _obscure,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: _obscure
                                  ? 'Show password'
                                  : 'Hide password',
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.go,
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Required' : null,
                          onFieldSubmitted: (_) => _busy ? null : _submit(),
                        ),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _useKey = !_useKey;
                                  _error = null;
                                }),
                          child: Text(
                            _useKey
                                ? 'Use a username and password instead'
                                : 'Use an API key instead',
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
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
