import 'dart:async';
import 'dart:collection';

/// Takes anything personal out of a log line before it is kept: server
/// addresses, user names, credentials, IP and email addresses, and the user
/// folder in file paths. Track titles never reach it, because the app logs
/// track ids instead.
class Redactor {
  /// Exact strings to hide, such as the signed-in server's host name and
  /// user name, with what to show instead.
  final Map<String, String> _known = {};

  /// Hides [value] wherever it appears, shown as [placeholder]. Values
  /// shorter than three characters are left alone, so a user called "ed"
  /// doesn't blank out every "ed" in the log.
  void hide(String value, String placeholder) {
    final v = value.trim();
    if (v.length < 3) return;
    _known[v] = placeholder;
  }

  static final _url = RegExp(
    r'''\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s'"<>()\[\]{}]+''',
  );
  static final _credential = RegExp(
    r'\b(u|p|t|s|apiKey|api_key|token|password|salt|username|user)=[^&\s,;]+',
    caseSensitive: false,
  );
  static final _email = RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+');
  static final _ipv4 = RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b');
  static final _ipv6 = RegExp(
    r'(?<![\w:])(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?![\w:])',
  );
  static final _hostField = RegExp(
    r'''(host lookup: |address = |host: |hostname: )'?[^\s',)]+'?''',
    caseSensitive: false,
  );
  static final _userFolder = RegExp(
    r'([A-Za-z]:\\Users\\|/home/|/Users/)[^\\/\s]+',
  );

  String call(String text) {
    // Whole addresses and credentials first, then the known values that
    // turn up elsewhere, such as a host name in an error message.
    var out = text
        .replaceAll(_url, '<url>')
        .replaceAllMapped(_credential, (m) => '${m[1]}=<hidden>')
        .replaceAll(_email, '<email>');
    // Longest first, so a host isn't half replaced by a shorter user name.
    final known = _known.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final v in known) {
      out = out.replaceAll(
        RegExp(RegExp.escape(v), caseSensitive: false),
        _known[v]!,
      );
    }
    return out
        .replaceAllMapped(_hostField, (m) => '${m[1]}<host>')
        .replaceAll(_ipv4, '<ip>')
        .replaceAllMapped(_ipv6, (m) {
          final s = m[0]!;
          // Times and durations such as 0:03:12 also have colons; only
          // hide what has hex letters or a "::".
          return s.contains('::') || RegExp('[a-fA-F]').hasMatch(s)
              ? '<ip>'
              : s;
        })
        .replaceAllMapped(_userFolder, (m) => '${m[1]}<user>');
  }
}

/// Where log lines are kept between runs. The app writes them to a small
/// rolling file; tests and web keep them in memory.
abstract class LogStore {
  /// Adds lines to the end of the log.
  Future<void> append(List<String> lines);

  /// The whole log, oldest first.
  Future<String> readAll();

  /// The folder the log is in, or null when it isn't on disk.
  String? get folder;

  /// Writes [text] to a file next to the log and returns its path, or null
  /// when there is nowhere to write it.
  Future<String?> writeReport(String text);
}

class MemoryLogStore implements LogStore {
  final int maxLines;
  MemoryLogStore({this.maxLines = 2000});

  final _lines = ListQueue<String>();

  @override
  Future<void> append(List<String> lines) async {
    _lines.addAll(lines);
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
  }

  @override
  Future<String> readAll() async =>
      _lines.isEmpty ? '' : '${_lines.join('\n')}\n';

  @override
  String? get folder => null;

  @override
  Future<String?> writeReport(String text) async => null;
}

/// The app's log for bug reports: errors and key events, always on, with
/// anything personal taken out as each line is written (see [Redactor]).
/// Nothing in it leaves the device unless the user copies or shares it.
class DiagnosticsLog {
  final LogStore store;
  final Redactor redact = Redactor();
  final DateTime Function() _now;

  DiagnosticsLog(this.store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final List<String> _pending = [];
  Future<void> _writing = Future.value();
  bool _flushQueued = false;

  /// Adds [message] to the log, stamped with the time.
  void add(String message) {
    final stamp = _now().toIso8601String();
    final clean = redact(message.trimRight());
    if (clean.isEmpty) return;
    final lines = clean.split('\n');
    _pending.add('$stamp ${lines.first}');
    for (final l in lines.skip(1)) {
      _pending.add('    $l');
    }
    if (_flushQueued) return;
    _flushQueued = true;
    // Batch lines that arrive together into one write.
    scheduleMicrotask(flush);
  }

  /// Writes out lines still waiting, and completes when they are stored.
  Future<void> flush() {
    _flushQueued = false;
    if (_pending.isNotEmpty) {
      final batch = List<String>.of(_pending);
      _pending.clear();
      _writing = _writing.then((_) => store.append(batch)).catchError((_) {});
    }
    return _writing;
  }

  /// The last [maxLines] lines of the log, redacted again with everything
  /// now known to hide (a server added after a line was written, say).
  Future<String> recent({int maxLines = 300}) async {
    await flush();
    final all = (await store.readAll()).trimRight();
    if (all.isEmpty) return '';
    final lines = all.split('\n');
    final tail = lines.length > maxLines
        ? lines.sublist(lines.length - maxLines)
        : lines;
    return redact(tail.join('\n'));
  }
}
