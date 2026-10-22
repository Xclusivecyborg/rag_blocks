/// Minimal RFC 4180 parser: handles quoted fields, embedded commas,
/// embedded newlines, and "" escapes.
List<List<String>> parseCsvGrid(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    switch (ch) {
      case '"':
        inQuotes = true;
      case ',':
        row.add(field.toString());
        field.clear();
      case '\r':
        break;
      case '\n':
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
      default:
        field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
