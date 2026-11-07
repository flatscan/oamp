import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/server_route.dart';
import '../../state/session.dart';
import '../server_address_field.dart';
import '../theme.dart';

/// The away address in settings: which address is in use, a warning until
/// the away address has worked once, and a tap to add, change or remove it.
class AwayAddressTile extends ConsumerWidget {
  const AwayAddressTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final away = ref.watch(awayAddressProvider);
    final route = ref.watch(serverRouteProvider);
    final notYet = away != null && !away.connected;
    return ListTile(
      leading: Icon(
        notYet ? Icons.warning_amber_rounded : Icons.public_rounded,
        color: notYet ? oampAccent : null,
      ),
      title: const Text('Away address'),
      subtitle: Text(switch (away) {
        null =>
          'Add a second address for when the server can\'t be reached, '
              'such as away from home.',
        _ when notYet =>
          '${away.url}\nNot connected yet. OAmp hasn\'t reached your '
              'server at this address, so it may not work.',
        _ when route == ServerRoute.away => '${away.url}\nConnected via away',
        _ => '${away.url}\nConnected via home',
      }),
      isThreeLine: away != null,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => AwayAddressDialog(initial: away?.url.toString()),
      ),
    );
  }
}

/// Adds, changes or removes the away address. Saving checks the address
/// first and offers to save anyway when it doesn't answer.
class AwayAddressDialog extends ConsumerStatefulWidget {
  final String? initial;
  const AwayAddressDialog({super.key, this.initial});

  @override
  ConsumerState<AwayAddressDialog> createState() => _AwayAddressDialogState();
}

class _AwayAddressDialogState extends ConsumerState<AwayAddressDialog> {
  late final _address = ServerAddressController(widget.initial);
  bool _busy = false;

  /// Why the last check failed; while set, Save becomes Save anyway.
  String? _failed;
  String? _checked;

  @override
  void initState() {
    super.initState();
    _address.text.addListener(_edited);
    _address.addListener(_edited);
  }

  void _edited() {
    if (_failed != null && _address.url != _checked) {
      setState(() => _failed = null);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _address.url;
    if (url.isEmpty) return _remove();
    final session = ref.read(awayAddressProvider.notifier);
    final nav = Navigator.of(context);
    if (_failed != null && url == _checked) {
      await session.save(url);
      nav.pop();
      return;
    }
    setState(() => _busy = true);
    final error = await session.test(url);
    if (!mounted) return;
    if (error == null) {
      await session.save(url, connected: true);
      nav.pop();
      return;
    }
    setState(() {
      _busy = false;
      _failed = error;
      _checked = url;
    });
  }

  Future<void> _remove() async {
    final nav = Navigator.of(context);
    await ref.read(awayAddressProvider.notifier).save(null);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Away address'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'OAmp uses your server address whenever it answers, and this '
              'one only when it doesn\'t, such as on mobile data or away '
              'from home.',
            ),
            const SizedBox(height: 16),
            ServerAddressField(
              controller: _address,
              label: 'Away address',
              hint: 'music.example.com',
              warnUnencrypted: true,
              autofocus: widget.initial == null,
              onSubmitted: (_) => _busy ? null : _save(),
            ),
            if (_failed case final reason?) ...[
              const SizedBox(height: 12),
              Text(
                'Couldn\'t reach your server there right now: $reason\n\n'
                'Many home networks can\'t reach their own public address, '
                'so it may still work when you\'re away.',
                style: theme.textTheme.bodySmall?.copyWith(color: oampAccent),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: _busy ? null : _remove,
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_failed != null ? 'Save anyway' : 'Save'),
        ),
      ],
    );
  }
}
