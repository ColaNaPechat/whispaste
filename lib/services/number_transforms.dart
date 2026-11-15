/// Pure number-word → digit-string transform for the **Zahlen-Modus** (numeric
/// only output). Engine-independent by construction — this is plain string
/// processing on the already-transcribed text, applied uniformly regardless
/// of which STT engine or provider produced it.
///
/// See PRD `itn-cad-zahlen/PRD.md` §3.1 for the design rationale.
library;

// ---------------------------------------------------------------------------
// Lexika (DE)
// ---------------------------------------------------------------------------

/// Einer (0–9), inkl. Varianten `ein`/`eine` für 1 und `zwo` für 2.
const _ones = {
  'null': 0,
  'eins': 1,
  'ein': 1,
  'eine': 1,
  'zwei': 2,
  'zwo': 2,
  'drei': 3,
  'vier': 4,
  'fünf': 5,
  'sechs': 6,
  'sieben': 7,
  'acht': 8,
  'neun': 9,
};

/// Teens 10–19, inkl. der Sonderformen `sechzehn`/`siebzehn`.
const _teens = {
  'zehn': 10,
  'elf': 11,
  'zwölf': 12,
  'dreizehn': 13,
  'vierzehn': 14,
  'fünfzehn': 15,
  'sechzehn': 16,
  'siebzehn': 17,
  'achtzehn': 18,
  'neunzehn': 19,
};

/// Zehner 20–90, inkl. `dreißig` und der alternativen Schreibweise `dreissig`.
const _tens = {
  'zwanzig': 20,
  'dreißig': 30,
  'dreissig': 30,
  'vierzig': 40,
  'fünfzig': 50,
  'sechzig': 60,
  'siebzig': 70,
  'achtzig': 80,
  'neunzig': 90,
};

/// Skalenwörter (V1: nur hundert und tausend).
const _scales = {'hundert': 100, 'tausend': 1000};

/// Dezimal-/Trennzeichen (DE).
const _separators = {'komma': ',', 'punkt': '.'};

/// Vorzeichen (DE/EN).
const _signs = {'minus': '-', 'negative': '-'};

/// Alle einfachen (nicht-kompositen) Zahlwörter — Menge für schnelle
/// Mitgliedschaftsprüfung.
final _simpleNumberWords = <String>{
  ..._ones.keys,
  ..._teens.keys,
  ..._tens.keys,
  ..._scales.keys,
};

// ---------------------------------------------------------------------------
// Lexika (EN)
// ---------------------------------------------------------------------------

/// Einer (0–9), inkl. `oh` als Ziffern-Platzhalter (wie bei Telefonnummern).
const _enOnes = {
  'zero': 0,
  'oh': 0,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
};

/// Teens 10–19.
const _enTeens = {
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
};

/// Zehner 20–90.
const _enTens = {
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

/// Skalenwörter EN (V1: nur hundred und thousand).
const _enScales = {'hundred': 100, 'thousand': 1000};

/// Dezimal-/Trennzeichen (EN).
const _enSeparators = {'point': '.', 'dot': '.', 'comma': ','};

/// Alle einfachen (nicht-kompositen) englischen Zahlwörter — Menge für
/// schnelle Mitgliedschaftsprüfung.
final _enSimpleNumberWords = <String>{
  ..._enOnes.keys,
  ..._enTeens.keys,
  ..._enTens.keys,
  ..._enScales.keys,
};

/// Englische `and`-Filler: wird zwischen Kardinalzahlen ignoriert
/// („one hundred and twenty five" → 125).
const _andFiller = 'and';

// ---------------------------------------------------------------------------
// Regexes (Top-Level `final`, nicht pro Aufruf kompilieren)
// ---------------------------------------------------------------------------

/// Passt auf bereits ziffernförmige Modellausgabe wie `5,2` oder `1.000`.
final _digitsRegex = RegExp(r'^[0-9]+([.,-][0-9]+)*$');

/// Nachbedingung: Ergebnis darf nur Zeichen aus dem Zielalphabet enthalten.
final _numericOnlyRegex = RegExp(r'^[0-9.,-]+$');

/// Tokenisierungs-Trenner (Stufe 1).
final _whitespaceSplitRegex = RegExp(r'\s+');

// ---------------------------------------------------------------------------
// Klassifikation
// ---------------------------------------------------------------------------

/// Was ein Token nach der Klassifikation ist.
enum _TokenKind {
  /// Bereits ziffernförmig (`5`, `3,14`, `1.000`).
  digits,

  /// Vorzeichen (`minus`, `negative`).
  sign,

  /// Dezimal-/Trennzeichen (`komma`, `punkt`).
  separator,

  /// Zahlwort, das in einen ganzzahligen Wert aufgelöst wird.
  cardinal,

  /// Skalenwort EN (`hundred`, `thousand`) — multipliziert den Akkumulator.
  scale,

  /// Einzelziffer-Wort (`oh`, `zero`) — wird als String emittiert, ohne
  /// Gruppierung mit nachfolgenden Kardinalen (für `oh five` → `05`).
  digitWord,
}

/// Ein klassifiziertes Token.
class _Token {
  final _TokenKind kind;

  /// Für CARDINAL: das Originalwort (wird bei der Emission zerlegt).
  final String word;

  /// Für DIGITS: der unveränderte String.
  /// Für SEPARATOR/SIGN: das auszugebende Zeichen.
  final String? output;

  _Token(this.kind, {required this.word, this.output});
}

// ---------------------------------------------------------------------------
// Zerlegungsalgorithmus (DE)
// ---------------------------------------------------------------------------

/// Zerlegt ein deutsches Kompositum wie `zweitausendfünfhundertdreiundzwanzig`
/// in seinen ganzzahligen Wert.
///
/// Die Reihenfolge der Split-Regeln ist **bindend** (PRD §5.1), sonst
/// zerbricht `hundert` an der eigenen Regel (`h`-`und`-`ert` würde an `und`
/// matchen).
///
/// 1. Erst an `tausend` spalten.
/// 2. Dann an `hundert`.
/// 3. Erst danach exaktes Nachschlagen in den einfachen Lexika.
/// 4. Erst zuletzt an `und` spalten (Einer-vor-Zehner, additiv).
///
/// Ein leerer linker Teil bedeutet Faktor 1 (z. B. `tausend` → `1 * 1000`).
int _decomposeGermanComposite(String word) {
  // 1. Erst an `tausend` spalten.
  final thousandIdx = word.indexOf('tausend');
  if (thousandIdx != -1) {
    final left = word.substring(0, thousandIdx);
    final right = word.substring(thousandIdx + 'tausend'.length);
    final leftValue = left.isEmpty ? 1 : _decomposeGermanComposite(left);
    final rightValue = right.isEmpty ? 0 : _decomposeGermanComposite(right);
    return leftValue * 1000 + rightValue;
  }

  // 2. Dann an `hundert` spalten.
  final hundredIdx = word.indexOf('hundert');
  if (hundredIdx != -1) {
    final left = word.substring(0, hundredIdx);
    final right = word.substring(hundredIdx + 'hundert'.length);
    final leftValue = left.isEmpty ? 1 : _decomposeGermanComposite(left);
    final rightValue = right.isEmpty ? 0 : _decomposeGermanComposite(right);
    return leftValue * 100 + rightValue;
  }

  // 3. Exaktes Nachschlagen.
  if (_ones.containsKey(word)) return _ones[word]!;
  if (_teens.containsKey(word)) return _teens[word]!;
  if (_tens.containsKey(word)) return _tens[word]!;

  // 4. Erst zuletzt an `und` spalten (Einer + Zehner, additiv).
  final undIdx = word.indexOf('und');
  if (undIdx != -1) {
    final left = word.substring(0, undIdx);
    final right = word.substring(undIdx + 'und'.length);
    // Leerer linker Teil bei `und` bedeutet 0 (kein Einer), nicht 1.
    final leftValue = left.isEmpty ? 0 : _decomposeGermanComposite(left);
    final rightValue = right.isEmpty ? 0 : _decomposeGermanComposite(right);
    return leftValue + rightValue;
  }

  // Sollte bei einem validen Kompositum nie erreicht werden.
  throw ArgumentError('Unknown German number word: $word');
}

// ---------------------------------------------------------------------------
// Tokenizer + Klassifikation
// ---------------------------------------------------------------------------

/// Setzt eine Token-Folge wie `["ein", "und", "zwanzig"]` zu einem
/// Kompositum zusammen (`["einundzwanzig"]`), wenn die Muster
/// &lt;Einer&gt; und &lt;Zehner&gt; oder &lt;Einer&gt; und &lt;Einer&gt;
/// vorliegen.
///
/// Wird **vor** der Klassifikation aufgerufen, damit der Zerlegungsalgorithmus
/// das zusammengefügte Wort korrekt verarbeiten kann.
List<String> _mergeSeparatedComposites(List<String> tokens) {
  final result = <String>[];
  var i = 0;
  while (i < tokens.length) {
    if (tokens[i] == 'und' && i > 0 && i + 1 < tokens.length) {
      final prev = tokens[i - 1];
      final next = tokens[i + 1];
      // Prüfen, ob prev und next Zahlwörter sind.
      final prevIsNumberWord = _simpleNumberWords.contains(prev);
      final nextIsNumberWord = _simpleNumberWords.contains(next);
      if (prevIsNumberWord && nextIsNumberWord) {
        // Zusammenführen: prev + und + next.
        final merged = '${prev}und$next';
        // Letztes Element war bereits hinzugefügt, also ersetzen.
        result.removeLast();
        result.add(merged);
        i += 2; // `und` und `next` überspringen.
        continue;
      }
    }
    result.add(tokens[i]);
    i++;
  }
  return result;
}

/// Splitzt englische Bindestrich-Komposita wie `twenty-one` in separate
/// Token (`["twenty", "one"]`). Ziffern-Token (`5,2-3`) behalten ihren
/// Bindestrich als Symbol.
///
/// Wird **vor** der Klassifikation aufgerufen, damit die Mehrwort-Komposition
/// im Emitter die Einzelteile addieren kann.
List<String> _splitHyphenatedComposites(List<String> tokens) {
  final result = <String>[];
  for (final token in tokens) {
    if (token.contains('-') && !_digitsRegex.hasMatch(token)) {
      // Bindestrich-Trennung nur bei Token, die Buchstaben enthalten.
      result.addAll(token.split('-').where((t) => t.isNotEmpty));
    } else {
      result.add(token);
    }
  }
  return result;
}

/// Filtert `and`-Filler heraus, die zwischen Kardinalzahlen stehen
/// (`one hundred and twenty five` → `one hundred twenty five`).
///
/// Wird **vor** der Klassifikation aufgerufen.
List<String> _filterAndFiller(List<String> tokens) {
  final result = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i] == _andFiller && i > 0 && i + 1 < tokens.length) {
      final prev = tokens[i - 1];
      final next = tokens[i + 1];
      final prevIsNumber =
          _simpleNumberWords.contains(prev) ||
          _enSimpleNumberWords.contains(prev);
      final nextIsNumber =
          _simpleNumberWords.contains(next) ||
          _enSimpleNumberWords.contains(next);
      if (prevIsNumber && nextIsNumber) {
        continue; // `and` zwischen Kardinalzahlen überspringen.
      }
    }
    result.add(tokens[i]);
  }
  return result;
}

/// Klassifiziert einen einzelnen, bereits bereinigten Token.
///
/// Alle Token, die weder DIGITS, SIGN noch SEPARATOR sind, werden als
/// CARDINAL, SCALE oder DIGIT_WORD klassifiziert. Die Zerlegung (einfacher
/// Wert vs. Kompositum) erfolgt erst bei der Emission über
/// [_resolveCardinalValue]. Falls die Zerlegung fehlschlägt, wird der Token
/// nachträglich als UNKNOWN gewertet und löst die Alles-oder-Nichts-Logik
/// aus.
_Token _classify(String token) {
  if (_digitsRegex.hasMatch(token)) {
    return _Token(_TokenKind.digits, word: token, output: token);
  }
  if (_signs.containsKey(token)) {
    return _Token(_TokenKind.sign, word: token, output: _signs[token]);
  }
  if (_separators.containsKey(token)) {
    return _Token(
      _TokenKind.separator,
      word: token,
      output: _separators[token],
    );
  }
  if (_enSeparators.containsKey(token)) {
    return _Token(
      _TokenKind.separator,
      word: token,
      output: _enSeparators[token],
    );
  }
  // EN-Skalenwörter: `hundred`, `thousand`.
  if (_enScales.containsKey(token)) {
    return _Token(
      _TokenKind.scale,
      word: token,
      output: _enScales[token].toString(),
    );
  }
  // EN-Einzeldigit-Wörter: `oh`, `zero` → als String emittiert, keine
  // Gruppierung mit nachfolgenden Kardinalen (`oh five` → `05`).
  if (token == 'oh' || token == 'zero') {
    return _Token(_TokenKind.digitWord, word: token, output: '0');
  }
  // Alles andere ist potenziell ein CARDINAL — Zerlegung erfolgt bei Emission.
  return _Token(_TokenKind.cardinal, word: token);
}

/// Klassifiziert eine Liste von Token-Strings.
List<_Token> _classifyAll(List<String> tokens) {
  return tokens.map(_classify).toList();
}

// ---------------------------------------------------------------------------
// Grouping + Emission
// ---------------------------------------------------------------------------

/// Auflöst einen CARDINAL-Token auf seinen ganzzahligen Wert.
///
/// Einfache Wörter (ones/teens/tens/scales) werden direkt nachgeschlagen;
/// Komposita werden über [_decomposeGermanComposite] zerlegt.
int _resolveCardinalValue(_Token token) {
  if (_ones.containsKey(token.word)) return _ones[token.word]!;
  if (_teens.containsKey(token.word)) return _teens[token.word]!;
  if (_tens.containsKey(token.word)) return _tens[token.word]!;
  if (_scales.containsKey(token.word)) return _scales[token.word]!;
  if (_enOnes.containsKey(token.word)) return _enOnes[token.word]!;
  if (_enTeens.containsKey(token.word)) return _enTeens[token.word]!;
  if (_enTens.containsKey(token.word)) return _enTens[token.word]!;
  // Kompositum (DE).
  return _decomposeGermanComposite(token.word);
}

/// Gruppiert aufeinanderfolgende CARDINAL- und SCALE-Token zu einer Zahl und
/// emittiert alle Token als Ausgabetoken in Sprech-Reihenfolge.
///
/// Englische Komposition (§5.1): Skalenwörter (`hundred`, `thousand`)
/// multiplizieren den laufenden Akkumulator und addieren zum Total.
/// Beispiel: `one hundred twenty five` → (1×100) + 25 = 125.
///
/// Einzelziffer-Wörter (`oh`, `zero`) werden als String emittiert, ohne
/// Gruppierung mit nachfolgenden Kardinalen (`oh five` → `05`).
///
/// Gibt `null` zurück, wenn ein Token nicht zerlegt werden kann
/// (Alles-oder-Nichts).
List<String>? _emit(List<_Token> tokens) {
  final result = <String>[];
  var i = 0;
  try {
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.kind == _TokenKind.cardinal || token.kind == _TokenKind.scale) {
        // Gruppe aus aufeinanderfolgenden CARDINAL- und SCALE-Token sammeln.
        final group = <_Token>[];
        while (i < tokens.length &&
            (tokens[i].kind == _TokenKind.cardinal ||
                tokens[i].kind == _TokenKind.scale)) {
          group.add(tokens[i]);
          i++;
        }
        // Englische Komposition: Akkumulator + Total.
        var accumulator = 0;
        var total = 0;
        for (final t in group) {
          if (t.kind == _TokenKind.cardinal) {
            accumulator += _resolveCardinalValue(t);
          } else if (t.kind == _TokenKind.scale) {
            final scale = int.parse(t.output!);
            if (accumulator == 0) accumulator = 1; // `hundred` allein → 100.
            total += accumulator * scale;
            accumulator = 0;
          }
        }
        total += accumulator;
        result.add(total.toString());
      } else if (token.kind == _TokenKind.digitWord) {
        // Einzelziffer-Wort (`oh`, `zero`) → als String emittiert, ohne
        // Gruppierung mit nachfolgenden Kardinalen.
        result.add(token.output!);
        i++;
      } else if (token.kind == _TokenKind.digits) {
        result.add(token.output!);
        i++;
      } else if (token.kind == _TokenKind.separator) {
        result.add(token.output!);
        i++;
      } else if (token.kind == _TokenKind.sign) {
        result.add(token.output!);
        i++;
      } else {
        // UNKNOWN — sollte vorher bereits erkannt worden sein.
        throw StateError('Unhandled token kind: ${token.kind}');
      }
    }
  } on ArgumentError {
    // Zerlegung fehlgeschlagen — Alles-oder-Nichts.
    return null;
  } on FormatException {
    // Parsing-Fehler bei Skalenwort — Alles-oder-Nichts.
    return null;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Öffentliche API
// ---------------------------------------------------------------------------

/// Wandelt ein Transkript, das ausschließlich aus Zahlwörtern, Ziffern und
/// Symbolen (`komma`/`punkt`/`minus`) besteht, in eine rein numerische
/// Darstellung um.
///
/// Gibt `null` zurück, wenn das Transkript nicht vollständig konvertierbar
/// ist (Alles-oder-Nichts-Garantie, PRD §3.2).
///
/// Das Ergebnis passt garantiert auf `^[0-9.,-]+$` und enthält keine
/// Leerzeichen.
///
/// Beispiel:
/// ```dart
/// toNumericOnly('fünf komma zwei minus drei'); // → '5,2-3'
/// toNumericOnly('Hallo Welt');                  // → null
/// ```
String? toNumericOnly(String text) {
  // Stufe 1: Tokenisieren.
  final rawTokens = text.split(_whitespaceSplitRegex);
  final tokens = rawTokens.map(_cleanToken).where((t) => t.isNotEmpty).toList();

  if (tokens.isEmpty) return null;

  // Ausnahme: reine Satzzeichen-Token werden verworfen (kein UNKNOWN).
  final hasNonPunctuation = tokens.any((t) {
    final c = t.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39); // 0-9
  });
  if (!hasNonPunctuation) return null;

  // Stufe 1.1: Englische Bindestrich-Komposita auftrennen
  // (z. B. `twenty-one` → `["twenty", "one"]`).
  final hyphenSplit = _splitHyphenatedComposites(tokens);

  // Stufe 1.2: Englischen `and`-Filler herausfiltern (zwischen Kardinalen).
  final andFiltered = _filterAndFiller(hyphenSplit);

  // Stufe 1.5: Getrennt geschriebene Komposita zusammenführen (DE: `und`).
  final merged = _mergeSeparatedComposites(andFiltered);

  // Stufe 2: Klassifizieren.
  final classified = _classifyAll(merged);

  // Stufe 3 + 4: Grouping + Emission. Falls die Zerlegung fehlschlägt,
  // gibt _emit `null` zurück (Alles-oder-Nichts).
  final emitted = _emit(classified);
  if (emitted == null) return null;

  // Stufe 5: Verifizieren.
  final result = emitted.join();
  if (result.isEmpty || !_numericOnlyRegex.hasMatch(result)) return null;

  return result;
}

/// Beschneidet einen Roh-Token an den Rändern: alle Zeichen, die weder
/// Buchstabe, Ziffer noch `.`, `,`, `-` sind, werden entfernt. Bei
/// Ziffern-Token (`5,2`) bleiben `.`, `,`, `-` als Teil des Musters
/// erhalten; bei Wort-Token (`drei.`) werden nachgestellte Satzzeichen
/// entfernt. Dann Kleinbuchstaben.
String _cleanToken(String raw) {
  // Führende/schließende Nicht-Alphabet-/Nicht-Ziffern-Zeichen abschneiden.
  var start = 0;
  var end = raw.length;
  while (start < end && !_isAlphanumeric(raw.codeUnitAt(start))) {
    start++;
  }
  while (end > start && !_isAlphanumeric(raw.codeUnitAt(end - 1))) {
    end--;
  }
  if (start >= end) return '';
  var cleaned = raw.substring(start, end).toLowerCase();

  // Wenn der Token ein Ziffernmuster ist (`5,2`, `1.000`), unverändert
  // zurückgeben (inklusive `.`, `,`, `-` als Teil des Musters).
  if (_digitsRegex.hasMatch(cleaned)) return cleaned;

  // Andernfalls: nachgestellte/vor gestellte `.`, `,`, `-` entfernen
  // (Satzzeichen, die nicht Teil eines Ziffernmusters sind).
  cleaned = _trimPunctuation(cleaned);

  return cleaned;
}

String _trimPunctuation(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && _isPunctuation(s.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isPunctuation(s.codeUnitAt(end - 1))) {
    end--;
  }
  return s.substring(start, end);
}

bool _isPunctuation(int codeUnit) {
  return codeUnit == 0x2E || // .
      codeUnit == 0x2C || // ,
      codeUnit == 0x2D; // -
}

bool _isAlphanumeric(int codeUnit) {
  return (codeUnit >= 0x41 && codeUnit <= 0x5A) || // A-Z
      (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
      (codeUnit >= 0x30 && codeUnit <= 0x39); // 0-9
}

// ---------------------------------------------------------------------------
// Russian number-word transform & in-phrase numeric mode
// ---------------------------------------------------------------------------

final _ruWsRegex = RegExp(r'\s+');
final _ruDigitTokenRegex = RegExp(r'^-?[0-9]+(?:[.,][0-9]+)*$');
final _ruNumericResultRegex = RegExp(
  r'^-?[0-9]+(?:[.,][0-9]+)*(?:x-?[0-9]+(?:[.,][0-9]+)*)*$',
);

const _ruZeroWords = {'ноль', 'нуль'};

const _ruOnes = {
  'один': 1,
  'одна': 1,
  'одно': 1,
  'одного': 1,
  'одной': 1,
  'одну': 1,
  'одним': 1,
  'два': 2,
  'две': 2,
  'двух': 2,
  'двум': 2,
  'двумя': 2,
  'три': 3,
  'трёх': 3,
  'трех': 3,
  'трём': 3,
  'трем': 3,
  'тремя': 3,
  'четыре': 4,
  'четырёх': 4,
  'четырех': 4,
  'четырём': 4,
  'четырем': 4,
  'четырьмя': 4,
  'пять': 5,
  'пяти': 5,
  'пятью': 5,
  'шесть': 6,
  'шести': 6,
  'шестью': 6,
  'семь': 7,
  'семи': 7,
  'семью': 7,
  'восемь': 8,
  'восьми': 8,
  'восемью': 8,
  'восьмью': 8,
  'девять': 9,
  'девяти': 9,
  'девятью': 9,
};

const _ruTeens = {
  'десять': 10,
  'десяти': 10,
  'одиннадцать': 11,
  'одиннадцати': 11,
  'двенадцать': 12,
  'двенадцати': 12,
  'тринадцать': 13,
  'тринадцати': 13,
  'четырнадцать': 14,
  'четырнадцати': 14,
  'пятнадцать': 15,
  'пятнадцати': 15,
  'шестнадцать': 16,
  'шестнадцати': 16,
  'семнадцать': 17,
  'семнадцати': 17,
  'восемнадцать': 18,
  'восемнадцати': 18,
  'девятнадцать': 19,
  'девятнадцати': 19,
};

const _ruTens = {
  'двадцать': 20,
  'двадцати': 20,
  'тридцать': 30,
  'тридцати': 30,
  'сорок': 40,
  'сорока': 40,
  'пятьдесят': 50,
  'пятидесяти': 50,
  'шестьдесят': 60,
  'шестидесяти': 60,
  'семьдесят': 70,
  'семидесяти': 70,
  'восемьдесят': 80,
  'восьмидесяти': 80,
  'девяносто': 90,
  'девяноста': 90,
};

const _ruHundreds = {
  'сто': 100,
  'ста': 100,
  'двести': 200,
  'двухсот': 200,
  'триста': 300,
  'трёхсот': 300,
  'трехсот': 300,
  'четыреста': 400,
  'четырёхсот': 400,
  'четырехсот': 400,
  'пятьсот': 500,
  'пятисот': 500,
  'шестьсот': 600,
  'шестисот': 600,
  'семьсот': 700,
  'семисот': 700,
  'восемьсот': 800,
  'восьмисот': 800,
  'девятьсот': 900,
  'девятисот': 900,
};

const _ruScales = {
  'тысяча': 1000,
  'тысячи': 1000,
  'тысяч': 1000,
  'тысячу': 1000,
  'тысячей': 1000,
  'тысячью': 1000,
  'миллион': 1000000,
  'миллиона': 1000000,
  'миллионов': 1000000,
};

const _ruDecimalCommaWords = {'запятая', 'целых', 'целая'};
const _ruDecimalDotWords = {'точка'};
const _ruFractionSuffixes = {
  'десятых',
  'десятая',
  'сотых',
  'сотая',
  'тысячных',
  'тысячная',
};
const _ruMultiplyWords = {'на', 'х', 'x', '×'};

class _RuToken {
  const _RuToken({
    required this.raw,
    required this.leading,
    required this.core,
    required this.trailing,
  });

  final String raw;
  final String leading;
  final String core;
  final String trailing;
}

bool _isRuWordChar(int c) {
  return (c >= 0x30 && c <= 0x39) || // 0-9
      (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0x0400 && c <= 0x04FF) || // Cyrillic
      c == 0x00D7; // ×
}

_RuToken _splitRuToken(String raw) {
  var start = 0;
  var end = raw.length;
  while (start < end &&
      !_isRuWordChar(raw.codeUnitAt(start)) &&
      raw.codeUnitAt(start) != 0x2D /* - */) {
    start++;
  }
  while (end > start && !_isRuWordChar(raw.codeUnitAt(end - 1))) {
    end--;
  }
  if (start >= end) {
    return _RuToken(raw: raw, leading: '', core: '', trailing: '');
  }
  return _RuToken(
    raw: raw,
    leading: raw.substring(0, start),
    core: raw.substring(start, end).toLowerCase(),
    trailing: raw.substring(end),
  );
}

bool _isRuNumberWord(String w) {
  return _ruZeroWords.contains(w) ||
      _ruOnes.containsKey(w) ||
      _ruTeens.containsKey(w) ||
      _ruTens.containsKey(w) ||
      _ruHundreds.containsKey(w) ||
      _ruScales.containsKey(w);
}

class _ParsedRuNumber {
  const _ParsedRuNumber({
    required this.text,
    required this.nextIndex,
    required this.leading,
    required this.trailing,
    required this.isZeroWord,
    required this.fromWords,
  });

  final String text;
  final int nextIndex;
  final String leading;
  final String trailing;
  final bool isZeroWord;
  final bool fromWords;
}

/// Parses a single Russian number (or existing digit token) starting at [index].
/// Returns `null` if tokens[index] does not start a number.
_ParsedRuNumber? _parseRuNumberAt(List<_RuToken> tokens, int index) {
  if (index >= tokens.length) return null;
  final first = tokens[index];
  if (first.core.isEmpty) return null;

  // Existing digit token (e.g. "333", "0,5", "-12").
  if (_ruDigitTokenRegex.hasMatch(first.core)) {
    return _ParsedRuNumber(
      text: first.core,
      nextIndex: index + 1,
      leading: first.leading,
      trailing: first.trailing,
      isZeroWord: false,
      fromWords: false,
    );
  }

  var pos = index;
  var negative = false;
  var leading = first.leading;

  if (first.core == 'минус') {
    if (pos + 1 >= tokens.length || first.trailing.isNotEmpty) return null;
    final next = tokens[pos + 1];
    if (!_isRuNumberWord(next.core) && !_ruDigitTokenRegex.hasMatch(next.core)) {
      return null;
    }
    negative = true;
    pos++;
    if (_ruDigitTokenRegex.hasMatch(next.core)) {
      final numText = next.core.startsWith('-') ? next.core : '-${next.core}';
      return _ParsedRuNumber(
        text: numText,
        nextIndex: pos + 1,
        leading: leading,
        trailing: next.trailing,
        isZeroWord: false,
        fromWords: true,
      );
    }
  }

  final startTok = tokens[pos];
  if (_ruZeroWords.contains(startTok.core)) {
    return _ParsedRuNumber(
      text: negative ? '-0' : '0',
      nextIndex: pos + 1,
      leading: leading,
      trailing: startTok.trailing,
      isZeroWord: !negative,
      fromWords: true,
    );
  }

  if (!_isRuNumberWord(startTok.core)) return null;

  // Rank: 4=scale(1000+), 3=hundreds, 2=tens, 1=ones/teens.
  var total = 0;
  var group = 0;
  var lastRank = 99;
  var trailing = '';

  while (pos < tokens.length) {
    final tok = tokens[pos];
    final w = tok.core;
    if (!_isRuNumberWord(w) || _ruZeroWords.contains(w)) break;
    if (pos > index && !negative && tok.leading.isNotEmpty) break;

    if (_ruHundreds.containsKey(w)) {
      if (lastRank <= 3) break;
      group += _ruHundreds[w]!;
      lastRank = 3;
    } else if (_ruTens.containsKey(w)) {
      if (lastRank <= 2) break;
      group += _ruTens[w]!;
      lastRank = 2;
    } else if (_ruTeens.containsKey(w)) {
      if (lastRank <= 2) break;
      group += _ruTeens[w]!;
      lastRank = 1;
    } else if (_ruOnes.containsKey(w)) {
      if (lastRank <= 1) break;
      group += _ruOnes[w]!;
      lastRank = 1;
    } else if (_ruScales.containsKey(w)) {
      final scale = _ruScales[w]!;
      final multiplier = group == 0 ? 1 : group;
      total += multiplier * scale;
      group = 0;
      lastRank = 4;
    } else {
      break;
    }

    trailing = tok.trailing;
    pos++;
    // Stop number assembly on any trailing punctuation (e.g. "пять, шесть").
    if (trailing.isNotEmpty) break;
  }

  final value = total + group;
  return _ParsedRuNumber(
    text: negative ? '-$value' : '$value',
    nextIndex: pos,
    leading: leading,
    trailing: trailing,
    isZeroWord: false,
    fromWords: true,
  );
}

/// Applies numeric mode to [text]:
/// - Handles pure DE/EN numeric strings via [toNumericOnly].
/// - Converts Russian number words anywhere inside phrases (including
///   decimals like "ноль пять" → "0,5" and dimensions like
///   "триста тридцать три на два" → "333x2").
/// - Strips a trailing period when the whole output is a standalone number or
///   dimension expression.
String applyNumericMode(String text) {
  final deOrEn = toNumericOnly(text);
  if (deOrEn != null) return deOrEn;

  final trimmed = text.trim();
  if (trimmed.isEmpty) return text;

  final rawTokens = trimmed.split(_ruWsRegex);
  final tokens = rawTokens.map(_splitRuToken).toList(growable: false);
  final out = <String>[];

  var i = 0;
  while (i < tokens.length) {
    final first = _parseRuNumberAt(tokens, i);
    if (first == null) {
      out.add(tokens[i].raw);
      i++;
      continue;
    }

    var acc = first.text;
    var trailing = first.trailing;
    var next = first.nextIndex;
    var prevZeroWord = first.isZeroWord;

    // Chain decimals ("ноль пять", "два целых пять десятых") and
    // dimension multipliers ("триста тридцать три на два" → "333x2").
    while (trailing.isEmpty && next < tokens.length) {
      final curTok = tokens[next];
      final w = curTok.core;

      // Case 1: "ноль пять" / "ноль 5" → "0,5"
      if (prevZeroWord && curTok.leading.isEmpty) {
        final frac = _parseRuNumberAt(tokens, next);
        if (frac != null && !frac.text.startsWith('-')) {
          acc = '0,${frac.text}';
          trailing = frac.trailing;
          next = frac.nextIndex;
          prevZeroWord = false;
          continue;
        }
      }

      // Case 2: "<num1> запятая/целых/точка <num2> [десятых/сотых/тысячных]"
      final isCommaWord = _ruDecimalCommaWords.contains(w);
      final isDotWord = _ruDecimalDotWords.contains(w);
      if ((isCommaWord || isDotWord) &&
          curTok.leading.isEmpty &&
          curTok.trailing.isEmpty) {
        final frac = _parseRuNumberAt(tokens, next + 1);
        if (frac != null && frac.leading.isEmpty && !frac.text.startsWith('-')) {
          final sep = isDotWord ? '.' : ',';
          acc = '$acc$sep${frac.text}';
          trailing = frac.trailing;
          next = frac.nextIndex;
          prevZeroWord = false;
          if (trailing.isEmpty &&
              next < tokens.length &&
              _ruFractionSuffixes.contains(tokens[next].core) &&
              tokens[next].leading.isEmpty) {
            trailing = tokens[next].trailing;
            next++;
          }
          continue;
        }
      }

      // Case 3: "<num1> на <num2>" → "<num1>x<num2>"
      if (_ruMultiplyWords.contains(w) &&
          curTok.leading.isEmpty &&
          curTok.trailing.isEmpty) {
        final rhs = _parseRuNumberAt(tokens, next + 1);
        if (rhs != null && rhs.leading.isEmpty) {
          // Allow rhs itself to start with "ноль пять" → "0,5".
          var rhsText = rhs.text;
          var rhsTrailing = rhs.trailing;
          var rhsNext = rhs.nextIndex;
          if (rhs.isZeroWord && rhsTrailing.isEmpty && rhsNext < tokens.length) {
            final rhsFrac = _parseRuNumberAt(tokens, rhsNext);
            if (rhsFrac != null &&
                rhsFrac.leading.isEmpty &&
                !rhsFrac.text.startsWith('-')) {
              rhsText = '0,${rhsFrac.text}';
              rhsTrailing = rhsFrac.trailing;
              rhsNext = rhsFrac.nextIndex;
            }
          }
          acc = '${acc}x$rhsText';
          trailing = rhsTrailing;
          next = rhsNext;
          prevZeroWord = false;
          continue;
        }
      }

      break;
    }

    out.add('${first.leading}$acc$trailing');
    i = next;
  }

  var result = out.join(' ');
  // If the entire output is just a standalone number or dimension expression
  // with a trailing period (added by STT), strip the trailing period.
  if (result.endsWith('.')) {
    final withoutDot = result.substring(0, result.length - 1);
    if (_ruNumericResultRegex.hasMatch(withoutDot)) {
      result = withoutDot;
    }
  }
  return result;
}
