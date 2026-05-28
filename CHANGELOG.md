# Changelog

## Unreleased

- Add metadata flags (title, author, album, narrator, year, genre)
- Support single-file inputs: mp3, m4a, flac, wav
- Improve chapter handling (prolog/epilog ordering, title normalization, numeric chapters without leading zeros)
- Fix ffmpeg concat list path issues by writing absolute paths
- Accept chapters timestamps with optional milliseconds (HH:MM:SS.mmm)
