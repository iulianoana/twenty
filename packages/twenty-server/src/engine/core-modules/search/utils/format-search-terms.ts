export const formatSearchTerms = (
  searchTerm: string,
  operator: 'and' | 'or' = 'and',
) => {
  if (searchTerm.trim() === '') {
    return '';
  }
  // Hyphenated names (Jean-Luc, Coca-Cola) are indexed as separate words
  const words = searchTerm
    .trim()
    .split(/[\s-]+/)
    .filter((word) => word.length > 0);
  const formattedWords = words.map((word) => {
    const escapedWord = word.replace(/[\\:'&|!()@<>]/g, '\\$&');

    // One- and two-letter prefixes match most of the index and slow search down
    return escapedWord.length >= 3 ? `${escapedWord}:*` : escapedWord;
  });

  return formattedWords.join(` ${operator === 'and' ? '&' : '|'} `);
};
