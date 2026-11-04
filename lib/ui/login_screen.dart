import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';

class LoginScreen extends ConsumerStatefulWidget {
  /// Filled in when the saved server asks to sign in again.
  final String? initialServerUrl;
  final String? initialUsername;

  /// Start on the API key form rather than username and password.
  final bool initialApiKey;

  /// Called after a successful sign-in when the screen was pushed on top of
  /// the app (signing in again) rather than shown in its place.
  final VoidCallback? onSignedIn;

  const LoginScreen({
    super.key,
    this.initialServerUrl,
    this.initialUsername,
    this.initialApiKey = false,
    this.onSignedIn,
  });

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  late final _url = TextEditingController(text: widget.initialServerUrl);
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
    _user.dispose();
    _pass.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionProvider.notifier);
      if (_useKey) {
        await session.loginSubsonicWithApiKey(
          serverUrl: _url.text,
          apiKey: _key.text,
        );
      } else {
        await session.loginSubsonic(
          serverUrl: _url.text,
          username: _user.text,
          password: _pass.text,
        );
      }
      widget.onSignedIn?.call();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
      body: Center(
        child: SingleChildScrollView(
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
                    TextFormField(
                      controller: _url,
                      decoration: const InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'https://music.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      keyboardType: TextInputType.url,
                      autofillHints: const [AutofillHints.url],
                      validator: _required,
                      textInputAction: TextInputAction.next,
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
                        onFieldSubmitted: (_) => _busy ? null : _submit(),
                      )
                    else ...[
                      TextFormField(
                        controller: _user,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }
}
