import { formatSearchTerms } from 'src/engine/core-modules/search/utils/format-search-terms';

describe('formatSearchTerms', () => {
  it('should format the search terms', () => {
    const formattedTerms = formatSearchTerms('my search input', 'and');

    expect(formattedTerms).toBe('my:* & search:* & input:*');
  });

  it('should format the search terms with or', () => {
    const formattedTerms = formatSearchTerms('my search input', 'or');

    expect(formattedTerms).toBe('my:* | search:* | input:*');
  });

  it('should split hyphenated words', () => {
    const formattedTerms = formatSearchTerms('Jean-Luc Picard', 'and');

    expect(formattedTerms).toBe('Jean:* & Luc:* & Picard:*');
  });
});

describe('formatSearchTerms edge cases', () => {
  it('should return an empty string for blank input', () => {
    expect(formatSearchTerms('   ', 'and')).toBe('');
  });

  it('should escape tsquery operators', () => {
    expect(formatSearchTerms("O'Brien", 'and')).toBe("O\\'Brien:*");
  });
});
