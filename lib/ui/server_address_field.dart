import 'package:flutter/material.dart';

import 'theme.dart';

/// The text of a server address field, with its scheme kept apart: the
/// field starts as `https://` and a tap on the prefix switches to
/// `http://`. Pasting or typing a full address sets the scheme from it.
class ServerAddressController extends ChangeNotifier {
  ServerAddressController([String? initial]) {
    set(initial);
    text.addListener(_takeScheme);
  }

  final text = TextEditingController();
  bool _secure = true;

  /// Whether the address starts `https://`.
  bool get secure => _secure;
  set secure(bool v) {
    if (v == _secure) return;
    _secure = v;
    notifyListeners();
  }

  /// Fills the field from a full address such as `http://nas:4533`.
  void set(String? url) {
    final (secure, rest) = split(url ?? '');
    _secure = secure;
    text.text = rest;
    notifyListeners();
  }

  /// The full address, or empty when nothing was typed.
  String get url {
    final rest = text.text.trim();
    return rest.isEmpty ? '' : '${_secure ? 'https' : 'http'}://$rest';
  }

  /// The scheme (true for https, the default) and the rest of [url].
  static (bool, String) split(String url) {
    final s = url.trim();
    final m = RegExp(r'^(https?)://', caseSensitive: false).firstMatch(s);
    if (m == null) return (true, s);
    return (m[1]!.toLowerCase() == 'https', s.substring(m.end));
  }

  void _takeScheme() {
    final (secure, rest) = split(text.text);
    if (rest == text.text.trim() || rest == text.text) return;
    _secure = secure;
    text.value = TextEditingValue(
      text: rest,
      selection: TextSelection.collapsed(offset: rest.length),
    );
    notifyListeners();
  }

  /// Whether [host] is on a private network (home, VPN or Tailscale), where
  /// plain http is not sent across the internet.
  static bool isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty || h == 'localhost') return true;
    if (h.endsWith('.local') ||
        h.endsWith('.lan') ||
        h.endsWith('.home.arpa') ||
        h.endsWith('.ts.net') ||
        h.endsWith('.internal')) {
      return true;
    }
    final ip = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
    if (ip != null) {
      final a = int.parse(ip[1]!), b = int.parse(ip[2]!);
      return a == 10 ||
          a == 127 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254) ||
          // Carrier-grade NAT range, which Tailscale uses.
          (a == 100 && b >= 64 && b <= 127);
    }
    if (h.contains(':')) {
      final v6 = h.replaceAll('[', '').replaceAll(']', '');
      return v6 == '::1' ||
          v6.startsWith('fc') ||
          v6.startsWith('fd') ||
          v6.startsWith('fe80');
    }
    // A bare name such as `nas` only resolves on the local network.
    return !h.contains('.');
  }

  /// Whether this is a plain http address on the open internet.
  bool get unencryptedOverInternet {
    if (_secure || text.text.trim().isEmpty) return false;
    final host = Uri.tryParse(url)?.host ?? '';
    return !isPrivateHost(host);
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
}

/// A server address field with an `https://` prefix that switches to
/// `http://` when tapped.
class ServerAddressField extends StatelessWidget {
  final ServerAddressController controller;
  final String label;
  final String? hint;
  final String? helper;

  /// Show a note when the address would send the login unencrypted over
  /// the internet (an away address).
  final bool warnUnencrypted;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  const ServerAddressField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.warnUnencrypted = false,
    this.validator,
    this.textInputAction,
    this.onSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.text]),
    builder: (context, _) {
      final secure = controller.secure;
      final warn = warnUnencrypted && controller.unencryptedOverInternet;
      final theme = Theme.of(context);
      return TextFormField(
        controller: controller.text,
        autofocus: autofocus,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: warn
              ? 'This connection isn\'t encrypted, so your login crosses the '
                    'internet in the clear.'
              : helper,
          helperMaxLines: 3,
          helperStyle: warn ? TextStyle(color: oampAccent) : null,
          prefixIconConstraints: const BoxConstraints(minHeight: 48),
          prefixIcon: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.dns_outlined),
                const SizedBox(width: 8),
                Tooltip(
                  message: secure
                      ? 'Switch to http:// (no encryption)'
                      : 'Switch to https://',
                  child: InkWell(
                    key: const ValueKey('scheme-toggle'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => controller.secure = !secure,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: OAmpColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            secure
                                ? Icons.lock_outline
                                : Icons.lock_open_rounded,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            secure ? 'https://' : 'http://',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: const [AutofillHints.url],
        validator: validator,
        textInputAction: textInputAction,
        onFieldSubmitted: onSubmitted,
      );
    },
  );
}
