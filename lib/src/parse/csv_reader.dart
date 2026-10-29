// SPDX-License-Identifier: BSD-3-Clause

/// The delimiters a CSV file may use, in the order that wins a tie.
const List<String> csvDelimiters = [',', ';', '\t', '|'];

/// Splits CSV [input] into rows of fields.
///
/// The delimiter comes from the header line only, counting the candidates in
/// [csvDelimiters] outside quoted text; an Excel `sep=` first line names it
/// instead. A field that starts with `"` is quoted: it may hold delimiters
/// and line breaks, `""` stands for one quote, and the quote that ends it is
/// the one followed by a delimiter, a line break or the end. `\r\n`, `\n`
/// and `\r` end a row, a leading byte-order mark is skipped, and an empty
/// line is a row with one empty field, so row numbers follow the file.
({List<List<String>> rows, String delimiter}) readCsv(String input) {
  var start = input.startsWith('﻿') ? 1 : 0;
  String? delimiter;
  if (input.startsWith('sep=', start)) {
    final lineEnd = _lineEnd(input, start);
    if (lineEnd != null) {
      final hint = input.substring(start + 4, lineEnd).trim();
      if (hint.isNotEmpty) {
        delimiter = hint;
        start = _skipLineBreak(input, lineEnd);
      }
    }
  }
  delimiter ??= _headerDelimiter(input, start);
  return (rows: _split(input, start, delimiter), delimiter: delimiter);
}

/// The delimiter that occurs most often outside quotes in the first row.
String _headerDelimiter(String input, int start) {
  final counts = {for (final d in csvDelimiters) d: 0};
  var inQuotes = false;
  var fieldStart = true;
  for (var i = start; i < input.length; i++) {
    final char = input[i];
    if (inQuotes) {
      if (char == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          i++;
        } else if (_closesQuote(input, i, null)) {
          inQuotes = false;
        }
      }
      continue;
    }
    if (char == '\r' || char == '\n') break;
    if (char == '"' && fieldStart) {
      inQuotes = true;
      fieldStart = false;
      continue;
    }
    if (counts.containsKey(char)) {
      counts[char] = counts[char]! + 1;
      fieldStart = true;
    } else {
      fieldStart = false;
    }
  }
  var best = csvDelimiters.first;
  for (final d in csvDelimiters) {
    if (counts[d]! > counts[best]!) best = d;
  }
  return best;
}

List<List<String>> _split(String input, int start, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldStart = true;
  var i = start;
  void endField() {
    row.add(field.toString());
    field.clear();
    fieldStart = true;
  }

  while (i < input.length) {
    final char = input[i];
    if (inQuotes) {
      if (char == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        if (_closesQuote(input, i, delimiter)) {
          inQuotes = false;
          i++;
          continue;
        }
      }
      field.write(char);
      i++;
      continue;
    }
    if (char == '"' && fieldStart && field.isEmpty) {
      inQuotes = true;
      fieldStart = false;
      i++;
    } else if (input.startsWith(delimiter, i)) {
      endField();
      i += delimiter.length;
    } else if (char == '\r' || char == '\n') {
      endField();
      rows.add(row);
      row = <String>[];
      i = _skipLineBreak(input, i);
    } else {
      field.write(char);
      fieldStart = false;
      i++;
    }
  }
  // The last row, unless the input ended with a line break.
  if (field.isNotEmpty || row.isNotEmpty || inQuotes) {
    endField();
    rows.add(row);
  }
  return rows;
}

/// Whether the quote at [i] ends a quoted field: it is followed by the
/// delimiter (any of [csvDelimiters] while it is still unknown), a line
/// break or the end of the input.
bool _closesQuote(String input, int i, String? delimiter) {
  final next = i + 1;
  if (next >= input.length) return true;
  final char = input[next];
  if (char == '\r' || char == '\n') return true;
  return delimiter == null
      ? csvDelimiters.contains(char)
      : input.startsWith(delimiter, next);
}

/// The index of the line break that ends the line starting at [start], or
/// null when there is none.
int? _lineEnd(String input, int start) {
  for (var i = start; i < input.length; i++) {
    if (input[i] == '\r' || input[i] == '\n') return i;
  }
  return null;
}

/// The index after the line break at [i], taking `\r\n` as one.
int _skipLineBreak(String input, int i) =>
    input[i] == '\r' && i + 1 < input.length && input[i + 1] == '\n'
    ? i + 2
    : i + 1;
