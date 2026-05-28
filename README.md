# m4b-builder

Create Apple Books–compatible `.m4b` audiobooks from audio files using Bash + FFmpeg.

**Highlights**

- Multi-file audiobooks (each file becomes a chapter)
- Single-file audiobooks + `chapters.txt`
- Cover embedding (`cover.jpg` / `cover.png`)
- Presets: `--small` / `--balanced` / `--high`
- Optional metadata flags (author, album, narrator, …)
- Chapter markers compatible with Apple Books

---

## Requirements

- macOS / Linux
- `ffmpeg` (includes `ffprobe`)

### Install FFmpeg (macOS)

```bash
brew install ffmpeg
```

---

## Install

### Option A: Run from this repo

```bash
git clone https://github.com/YOUR_USERNAME/m4b-builder.git
cd m4b-builder
chmod +x m4b-builder.sh m4b-builder
```

Run:

```bash
./m4b-builder <input-folder> [quality] [options]
```

### Option B: Install globally (recommended)

1) Create a local bin directory:

```bash
mkdir -p ~/.local/bin
```

2) Copy the executable wrapper (recommended) and the script:

```bash
cp m4b-builder m4b-builder.sh ~/.local/bin/
chmod +x ~/.local/bin/m4b-builder ~/.local/bin/m4b-builder.sh
```

3) Add to your `PATH`.

Zsh (default on macOS):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Bash:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

4) Verify:

```bash
m4b-builder --help
```

---

## Usage

```bash
m4b-builder <input-folder> [quality] [options]
```

### Quality modes

- `--small` (48k, mono)
- `--balanced` (64k, mono) **default**
- `--high` (96k, stereo)

### Metadata options

- `--title "..."` (defaults to folder name)
- `--author "..."`
- `--album "..."`
- `--narrator "..."`
- `--year 2005`
- `--genre "Audiobook"`

Example:

```bash
m4b-builder ./MyBook \
  --high \
  --author "John Flanagan" \
  --title "Hraničářův učeň (1) - Rozvaliny Gorlanu" \
  --album "Hraničářův učeň" \
  --narrator "Matouš Ruml" \
  --genre "Audiobook" \
  --year 2005
```

---

## Input formats

`<input-folder>` determines the default embedded title and should contain your audio + optional assets.

### Multi-file mode (multiple `.mp3` files)

Folder structure:

```text
MyBook/
├── prolog.mp3       (optional)
├── 01.mp3
├── 02.mp3
├── 03.mp3
└── cover.jpg        (optional)
```

What happens:

- MP3s are sorted by filename
- If present, `prolog.mp3` / `prologue.mp3` is forced to the beginning
- If present, `epilog.mp3` / `epilogue.mp3` is forced to the end
- Each file becomes a chapter
  - Special titles: Prolog/Prologue/Epilog/Epilogue
  - Numeric titles become `Kapitola N` (leading zeros are removed)
- Output written to `audiobook.m4b` in the current working directory

Run:

```bash
m4b-builder ./MyBook
```

Tips:

- Use zero-padded numbering (`01`, `02`, `03`) to keep chapter order stable.

### Single-file mode (one audio file + `chapters.txt`)

Supported single-file input extensions:

- `.mp3`
- `.m4a`
- `.flac`
- `.wav`

Folder structure:

```text
MyBook/
├── book.m4a
├── chapters.txt
└── cover.png        (optional)
```

Example `chapters.txt`:

```text
00:00:00 Introduction
00:05:12 Chapter 1
00:18:44 Chapter 2
01:03:11 Chapter 3
```

Notes:

- Timestamps must be `HH:MM:SS`
- Milliseconds are also accepted: `HH:MM:SS.mmm` (example: `00:00:00.000`)
- The chapter title is everything after the timestamp

Run:

```bash
m4b-builder ./MyBook
```

---

## Output

The script writes:

```text
audiobook.m4b
```

Compatible with:

- Apple Books (macOS / iOS)
- iPhone / iPad

---

## Troubleshooting

### `ffmpeg` not found / `ffprobe` not found

```bash
brew install ffmpeg
```

### Cover not embedded

Put one of these files in the input folder:

- `cover.jpg`
- `cover.png`

---

## Notes / limitations

- Output filename is currently fixed to `audiobook.m4b`.
- Multi-file mode is MP3-only (single-file mode supports more formats).

---

## Contributing

Issues and pull requests are welcome.

---

## License

MIT (see `LICENSE`).
