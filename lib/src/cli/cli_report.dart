// SPDX-License-Identifier: BSD-3-Clause
part of 'cli.dart';

/// A diagnostic with where it came from: `parser`, `validation`, `repair`
/// (what an edit step or auto-fix repaired) or `export` (what the output
/// format cannot hold).
class _Reported {
  _Reported({
    required this.source,
    required this.severity,
    required this.code,
    required this.message,
    this.suggestedFix,
    this.priority,
    this.node,
  });

  factory _Reported.parse(ParseDiagnostic d) => _Reported(
    source: _sourceOf(d.code),
    severity: d.severity.name,
    code: d.code,
    message: d.message,
    suggestedFix: d.suggestedFix,
    priority: d.priority,
    node: d.node?.format(),
  );

  factory _Reported.validation(
    ValidationDiagnostic d, {
    String source = 'validation',
  }) => _Reported(
    source: source,
    severity: d.severity.name,
    code: d.code,
    message: d.message,
    suggestedFix: d.suggestedFix,
    priority: d.priority,
  );

  final String source;
  final String severity;
  final String code;
  final String message;
  final String? suggestedFix;
  final int? priority;
  final String? node;

  bool get isError => severity == 'error';
  bool get isInfo => severity == 'info';

  Map<String, Object?> toJson() => {
    'source': source,
    'severity': severity,
    'code': code,
    'message': message,
    'suggestedFix': ?suggestedFix,
    'priority': ?priority,
    'node': ?node,
  };
}

String _sourceOf(String code) {
  if (code.startsWith('lossy.')) return 'export';
  if (code.startsWith('validation.')) return 'validation';
  if (code.startsWith('repaired.') || code.startsWith('autofix.')) {
    return 'repair';
  }
  return 'parser';
}

List<_Reported> _fromParse(Iterable<ParseDiagnostic> diagnostics) => [
  for (final d in diagnostics) _Reported.parse(d),
];

/// Writes warnings and errors as readable text; info diagnostics stay in the
/// JSON output only.
void _printDiagnostics(IOSink sink, String title, List<_Reported> reported) {
  final shown = reported.where((d) => !d.isInfo).toList();
  if (shown.isEmpty) return;
  sink.writeln(title);
  for (final d in shown) {
    final where = d.node == null ? '' : ' ${d.node} •';
    sink.writeln('  - ${d.severity.toUpperCase()}$where ${d.code}');
    sink.writeln('      ${d.message}');
    if (d.suggestedFix != null) {
      sink.writeln('      Fix: ${d.suggestedFix}');
    }
  }
}

void _printJson(IOSink sink, Map<String, Object?> object) {
  sink.writeln(jsonEncode(object));
}

/// Counts the files of a batch and reports progress and a summary on stderr.
class _BatchReport {
  _BatchReport(this.total, {required this.verb, required this.json});

  final int total;
  final String verb;
  final bool json;
  final failed = <String>[];
  var done = 0;
  var worstExit = _exitOk;

  void succeeded(String message) {
    done++;
    if (!json) _error(total > 1 ? '[$done/$total] $message' : message);
  }

  void failure(_Input input, String message, int exitCode) {
    done++;
    failed.add(input.display);
    if (exitCode > worstExit) worstExit = exitCode;
    if (!json) {
      _error(
        total > 1
            ? '[$done/$total] ${input.display}: $message'
            : '${input.display}: $message',
      );
    }
  }

  void summarize() {
    if (json || total < 2) return;
    final ok = done - failed.length;
    final skipped = total - done;
    _error(
      '$ok $verb, ${failed.length} failed'
      '${skipped > 0 ? ', $skipped not attempted' : ''}'
      '${failed.isEmpty ? '' : ': ${failed.join(', ')}'}',
    );
  }
}
