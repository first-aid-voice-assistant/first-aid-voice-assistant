final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

final RegExp _digits = RegExp(r'^\d+$');

final RegExp _filler = RegExp(r'^(y+|e+|m+|hm+|ehm+|mhm+|yhm+)$');

const Set<String> _numberWords = {
  'raz',
  'jeden',
  'jedna',
  'dwa',
  'trzy',
  'cztery',
  'pięć',
  'sześć',
  'siedem',
  'osiem',
  'dziewięć',
  'dziesięć',
  'jedenaście',
  'dwanaście',
  'trzynaście',
  'czternaście',
  'piętnaście',
  'szesnaście',
  'siedemnaście',
  'osiemnaście',
  'dziewiętnaście',
  'dwadzieścia',
  'trzydzieści',
  'i',
};

const Set<String> _lastCount = {'trzydzieści', '30'};

bool isCountingOrFiller(String text) {
  final words = text
      .toLowerCase()
      .split(_nonWord)
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return true;
  if (words.any(_lastCount.contains)) return false;
  return words.every(
    (word) =>
        _numberWords.contains(word) ||
        _digits.hasMatch(word) ||
        _filler.hasMatch(word),
  );
}
