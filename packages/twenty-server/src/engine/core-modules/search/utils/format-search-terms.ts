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
  const formattedWords = words.map((word) =>
    word.replace(/[\\:'&|!()@<>]/g, '\\$&'),
  );

  return formattedWords.join(` ${operator === 'and' ? '&' : '|'} `);
};
