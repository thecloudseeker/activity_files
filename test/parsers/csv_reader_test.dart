// SPDX-License-Identifier: BSD-3-Clause
/// The CSV reader: quoting, line endings and empty lines as the `csv`
/// package read them before it was replaced, and the delimiter from the
/// header line only.
library;

import 'package:activity_files/src/parse/csv_reader.dart';
import 'package:test/test.dart';

void main() {
  for (final (label, input, rows) in <(String, String, List<List<String>>)>[
    (
      'plain',
      'a,b,c\n1,2,3\n',
      [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ],
    ),
    (
      'no final line break',
      'a,b\n1,2',
      [
        ['a', 'b'],
        ['1', '2'],
      ],
    ),
    (
      'CRLF',
      'a,b\r\n1,2\r\n3,4\r\n',
      [
        ['a', 'b'],
        ['1', '2'],
        ['3', '4'],
      ],
    ),
    (
      'CR only',
      'a,b\r1,2\r',
      [
        ['a', 'b'],
        ['1', '2'],
      ],
    ),
    (
      'byte-order mark',
      '\ufeffa,b\n1,2\n',
      [
        ['a', 'b'],
        ['1', '2'],
      ],
    ),
    (
      'empty lines',
      'a,b\n\n1,2\n\n\n3,4\n',
      [
        ['a', 'b'],
        [''],
        ['1', '2'],
        [''],
        [''],
        ['3', '4'],
      ],
    ),
    (
      'quoted delimiter',
      'a,b\n"x,y",2\n',
      [
        ['a', 'b'],
        ['x,y', '2'],
      ],
    ),
    (
      'quoted line break',
      'a,b\n"x\ny",2\n',
      [
        ['a', 'b'],
        ['x\ny', '2'],
      ],
    ),
    (
      'quoted CRLF',
      'a,b\r\n"x\r\ny",2\r\n',
      [
        ['a', 'b'],
        ['x\r\ny', '2'],
      ],
    ),
    (
      'escaped quotes',
      'a,b\n"say ""hi""",2\n',
      [
        ['a', 'b'],
        ['say "hi"', '2'],
      ],
    ),
    (
      'empty quoted field',
      'a,b\n"",2\n',
      [
        ['a', 'b'],
        ['', '2'],
      ],
    ),
    (
      'quote inside an unquoted field',
      'a,b\nx"y,2\n',
      [
        ['a', 'b'],
        ['x"y', '2'],
      ],
    ),
    (
      'quote not followed by a delimiter',
      'a,b\n"x"y,2\n',
      [
        ['a', 'b'],
        ['x"y,2\n'],
      ],
    ),
    (
      'unterminated quote',
      'a,b\n"x,2\n',
      [
        ['a', 'b'],
        ['x,2\n'],
      ],
    ),
    (
      'semicolons',
      'a;b;c\n1;2;3\n',
      [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ],
    ),
    (
      'tabs',
      'a\tb\tc\n1\t2\t3\n',
      [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ],
    ),
    (
      'pipes',
      'a|b|c\n1|2|3\n',
      [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ],
    ),
    (
      'sep hint',
      'sep=;\na;b\n1;2\n',
      [
        ['a', 'b'],
        ['1', '2'],
      ],
    ),
    (
      'trailing delimiter',
      'a,b,\n1,2,\n',
      [
        ['a', 'b', ''],
        ['1', '2', ''],
      ],
    ),
    (
      'only a header',
      'a,b,c',
      [
        ['a', 'b', 'c'],
      ],
    ),
    ('empty', '', []),
    (
      'whitespace around fields',
      'a , b\n 1 , 2 \n',
      [
        ['a ', ' b'],
        [' 1 ', ' 2 '],
      ],
    ),
  ]) {
    test(label, () => expect(readCsv(input).rows, rows));
  }

  for (final (input, delimiter) in [
    ('a,b\n1,2\n', ','),
    ('a;b\n1;2\n', ';'),
    ('a\tb\n1\t2\n', '\t'),
    ('a|b\n1|2\n', '|'),
    ('sep=|\na|b\n', '|'),
    ('single\n1\n', ','),
    ('a,b;c;d\n', ';'),
    ('a,b,c;d\n', ','),
    ('a;b,c\n', ','),
  ]) {
    test('the header of ${input.split('\n').first} chooses $delimiter', () {
      expect(readCsv(input).delimiter, delimiter);
    });
  }

  test('delimiters inside quoted header text do not count', () {
    const input = 'timestamp,"a;b;c;d",note\n1,2,3\n';
    expect(readCsv(input).delimiter, ',');
    expect(readCsv(input).rows.first, ['timestamp', 'a;b;c;d', 'note']);
  });

  test('semicolons in quoted values of a comma file stay in their field', () {
    const input =
        'timestamp,note\n'
        '2024-01-01T10:00:00Z,"a;b;c;d"\n'
        '2024-01-01T10:00:10Z,"e;f;g;h"\n';
    expect(readCsv(input).rows[1], ['2024-01-01T10:00:00Z', 'a;b;c;d']);
  });
}
