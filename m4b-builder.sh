#!/bin/bash

# ============================================
# m4b-builder
# Create Apple Books compatible .m4b audiobooks
# Supports:
# - Multiple MP3 chapters
# - Single MP3 + chapters.txt
# - Cover image
# - Small / balanced / high quality modes
# ============================================

set -e

# ---------- DEFAULTS ----------

QUALITY_MODE="balanced"
OUTPUT_NAME="audiobook.m4b"

# Optional metadata (can be set via flags)
META_TITLE=""
META_AUTHOR=""
META_ALBUM=""
META_NARRATOR=""
META_YEAR=""
META_GENRE=""

# ---------- HELP ----------

show_help() {
    echo ""
    echo "m4b-builder"
    echo ""
    echo "Usage:"
    echo "  m4b-builder <input-folder> [quality] [options]"
    echo ""
    echo "Quality modes:"
    echo "  --small      48k mono"
    echo "  --balanced   64k mono (default)"
    echo "  --high       96k stereo"
    echo ""
    echo "Metadata options:"
    echo "  --title <text>       Override embedded title (default: folder name)"
    echo "  --author <text>      Author/artist"
    echo "  --album <text>       Album (often same as title)"
    echo "  --narrator <text>    Comment field (common place for narrator info)"
    echo "  --year <YYYY>        Year/date"
    echo "  --genre <text>       Genre"
    echo ""
    echo "Multi-file mode:"
    echo "  prolog.mp3 (optional)"
    echo "  01.mp3"
    echo "  02.mp3"
    echo "  03.mp3"
    echo ""
    echo "Single-file mode:"
    echo "  book.mp3 / book.m4a / book.flac / book.wav"
    echo "  chapters.txt"
    echo ""
    echo "Optional:"
    echo "  cover.jpg"
    echo "  cover.png"
    echo ""
}

# ---------- VALIDATION ----------

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    show_help
    exit 0
fi

if [ -z "$1" ]; then
    echo "ERROR: Missing input folder"
    show_help
    exit 1
fi

INPUT_DIR="$1"
shift

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Folder does not exist"
    exit 1
fi

# Normalize INPUT_DIR to an absolute path so ffmpeg concat lists can't break
# when the list file is located in a temp directory.
INPUT_DIR_ABS=$(cd "$INPUT_DIR" && pwd -P)
INPUT_DIR="$INPUT_DIR_ABS"

if ! command -v ffmpeg &> /dev/null; then
    echo "ERROR: ffmpeg is not installed"
    exit 1
fi

if ! command -v ffprobe &> /dev/null; then
    echo "ERROR: ffprobe is not installed"
    exit 1
fi

# ---------- PARSE ARGS (quality + options) ----------

QUALITY_ARG=""
if [ $# -gt 0 ]; then
    case "$1" in
        --small|--balanced|--high)
            QUALITY_ARG="$1"
            shift
            ;;
    esac
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --title)
            META_TITLE="$2"; shift 2 ;;
        --author)
            META_AUTHOR="$2"; shift 2 ;;
        --album)
            META_ALBUM="$2"; shift 2 ;;
        --narrator)
            META_NARRATOR="$2"; shift 2 ;;
        --year)
            META_YEAR="$2"; shift 2 ;;
        --genre)
            META_GENRE="$2"; shift 2 ;;
        --help|-h)
            show_help; exit 0 ;;
        *)
            echo "ERROR: Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# ---------- QUALITY MODES ----------

case "$QUALITY_ARG" in
    --small)
        AUDIO_BITRATE="48k"
        AUDIO_CHANNELS="1"
        QUALITY_MODE="small"
        ;;
    --high)
        AUDIO_BITRATE="96k"
        AUDIO_CHANNELS="2"
        QUALITY_MODE="high"
        ;;
    *)
        AUDIO_BITRATE="64k"
        AUDIO_CHANNELS="1"
        QUALITY_MODE="balanced"
        ;;
esac

# ---------- TEMP FILES ----------

TEMP_LIST=$(mktemp)
TEMP_META=$(mktemp)

cleanup() {
    rm -f "$TEMP_LIST"
    rm -f "$TEMP_META"
}

trap cleanup EXIT

# ---------- HELPERS ----------

time_to_ms() {
    IFS=: read -r H M S <<< "$1"
    # Allow optional fractional seconds (e.g. 00:00:00.000)
    S=${S%%.*}
    echo $((10#$H * 3600000 + 10#$M * 60000 + 10#$S * 1000))
}

# Convert a possibly-relative path to an absolute path.
# macOS doesn't ship realpath(1) by default.
abs_path() {
    local p="$1"
    if [[ "$p" = /* ]]; then
        printf '%s\n' "$p"
    else
        printf '%s\n' "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")"
    fi
}

normalize_chapter_title() {
    # Normalizes common special chapter names.
    # Examples:
    #   prolog   -> Prolog
    #   prologue -> Prologue
    #   epilog   -> Epilog
    #   epilogue -> Epilogue
    #   03       -> Kapitola 3
    local t="$1"
    local lower
    lower=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        prolog) echo "Prolog" ;;
        prologue) echo "Prologue" ;;
        epilog) echo "Epilog" ;;
        epilogue) echo "Epilogue" ;;
        *)
            # If title looks like "Kapitola 01" (any casing), normalize to "Kapitola 1"
            if [[ "$lower" =~ ^kapitola[[:space:]]+([0-9]+)$ ]]; then
                local n="${BASH_REMATCH[1]}"
                echo "Kapitola $((10#$n))"
                return
            fi
            echo "$t"
            ;;
    esac
}

# Return a sortable key so special chapters can be forced to the start/end.
# The output is: "<priority>\t<basename>\t<fullpath>".
# Lower priority values sort first.
chapter_sort_key() {
    local file="$1"
    local base lower
    base=$(basename "$file")
    lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        prolog.mp3|prologue.mp3) printf '00\t%s\t%s\n' "$base" "$file" ;;
        epilog.mp3|epilogue.mp3) printf '99\t%s\t%s\n' "$base" "$file" ;;
        *) printf '50\t%s\t%s\n' "$base" "$file" ;;
    esac
}

# ---------- CREATE METADATA ----------

echo ";FFMETADATA1" > "$TEMP_META"

# Count MP3s for multi-file mode selection.
MP3_COUNT=$(find "$INPUT_DIR" -maxdepth 1 -name "*.mp3" | wc -l | tr -d ' ')

# Detect single-file candidates for supported extensions.
AUDIO_COUNT=$(find "$INPUT_DIR" -maxdepth 1 \( \
    -name "*.mp3" -o \
    -name "*.flac" -o \
    -name "*.m4a" -o \
    -name "*.wav" \
\) | wc -l | tr -d ' ')

if [ "$AUDIO_COUNT" -eq 0 ]; then
    echo "ERROR: No audio files found (mp3/flac/m4a/wav)"
    exit 1
fi

# ============================================
# MULTI FILE MODE
# ============================================

if [ "$MP3_COUNT" -gt 1 ]; then

    echo ""
    echo "Mode: Multi-file"
    echo ""

    START=0

    # Build a sorted file list where prolog/prologue is first and epilog/epilogue is last.
    SORTED_FILES=$(find "$INPUT_DIR" -maxdepth 1 -name "*.mp3" -print0 \
        | while IFS= read -r -d '' f; do chapter_sort_key "$f"; done \
        | sort -t $'\t' -k1,1n -k2,2 \
        | cut -f3)

    while IFS= read -r FILE; do

        FILE_ABS=$(abs_path "$FILE")

        echo "Found: $(basename "$FILE_ABS")"

        # IMPORTANT: ffmpeg resolves relative paths in concat lists relative to the list file.
        # Always write absolute paths.
        echo "file '$FILE_ABS'" >> "$TEMP_LIST"

        DURATION=$(ffprobe \
            -i "$FILE_ABS" \
            -show_entries format=duration \
            -v quiet \
            -of csv="p=0")

        DURATION_MS=$(printf "%.0f" "$(echo "$DURATION * 1000" | bc)")

        END=$((START + DURATION_MS))

        TITLE=$(basename "$FILE_ABS" .mp3)
        TITLE=$(normalize_chapter_title "$TITLE")

        {
            echo "[CHAPTER]"
            echo "TIMEBASE=1/1000"
            echo "START=$START"
            echo "END=$END"
            echo "title=$TITLE"
        } >> "$TEMP_META"

        START=$END

    done <<< "$SORTED_FILES"

# ============================================
# SINGLE FILE MODE
# ============================================

else

    echo ""
    echo "Mode: Single-file"
    echo ""

    AUDIO_FILE=$(find "$INPUT_DIR" -maxdepth 1 \( \
        -name "*.mp3" -o \
        -name "*.flac" -o \
        -name "*.m4a" -o \
        -name "*.wav" \
    \) | head -n 1)

    if [ -z "$AUDIO_FILE" ]; then
        echo "ERROR: No audio file found (mp3/flac/m4a/wav)"
        exit 1
    fi

    AUDIO_FILE_ABS=$(abs_path "$AUDIO_FILE")

    echo "file '$AUDIO_FILE_ABS'" >> "$TEMP_LIST"

    CHAPTER_FILE="$INPUT_DIR/chapters.txt"

    if [ ! -f "$CHAPTER_FILE" ]; then
        echo "ERROR: chapters.txt not found"
        exit 1
    fi

    TOTAL_DURATION=$(ffprobe \
        -i "$AUDIO_FILE_ABS" \
        -show_entries format=duration \
        -v quiet \
        -of csv="p=0")

    TOTAL_DURATION_MS=$(printf "%.0f" "$(echo "$TOTAL_DURATION * 1000" | bc)")

    # Read chapters file into an array (portable; avoids bash-only mapfile).
    CHAPTER_LINES=()
    while IFS= read -r line || [ -n "$line" ]; do
        # skip empty lines
        [ -z "$line" ] && continue
        CHAPTER_LINES+=("$line")
    done < "$CHAPTER_FILE"

    for ((i=0; i<${#CHAPTER_LINES[@]}; i++)); do

        LINE="${CHAPTER_LINES[$i]}"

        START_TIME=$(echo "$LINE" | awk '{print $1}')
        TITLE=$(echo "$LINE" | cut -d' ' -f2-)
        TITLE=$(normalize_chapter_title "$TITLE")

        START_MS=$(time_to_ms "$START_TIME")

        if [ $i -lt $((${#CHAPTER_LINES[@]} - 1)) ]; then

            NEXT_LINE="${CHAPTER_LINES[$((i+1))]}"
            NEXT_TIME=$(echo "$NEXT_LINE" | awk '{print $1}')
            END_MS=$(time_to_ms "$NEXT_TIME")

        else

            END_MS=$TOTAL_DURATION_MS

        fi

        {
            echo "[CHAPTER]"
            echo "TIMEBASE=1/1000"
            echo "START=$START_MS"
            echo "END=$END_MS"
            echo "title=$TITLE"
        } >> "$TEMP_META"

    done

fi

# ---------- COVER ----------

COVER_FILE=""

if [ -f "$INPUT_DIR/cover.jpg" ]; then
    COVER_FILE="$INPUT_DIR/cover.jpg"
elif [ -f "$INPUT_DIR/cover.png" ]; then
    COVER_FILE="$INPUT_DIR/cover.png"
fi

# ---------- BUILD ----------

BOOK_TITLE=$(basename "$INPUT_DIR")

# Title that will be embedded as metadata
if [ -n "$META_TITLE" ]; then
    BOOK_TITLE="$META_TITLE"
fi

# Build ffmpeg metadata arguments (only include what user set)
FFMETA_ARGS=("-metadata" "title=$BOOK_TITLE")
if [ -n "$META_AUTHOR" ]; then FFMETA_ARGS+=("-metadata" "artist=$META_AUTHOR"); fi
if [ -n "$META_ALBUM" ]; then FFMETA_ARGS+=("-metadata" "album=$META_ALBUM"); fi
if [ -n "$META_GENRE" ]; then FFMETA_ARGS+=("-metadata" "genre=$META_GENRE"); fi
# Use date (common across containers)
if [ -n "$META_YEAR" ]; then FFMETA_ARGS+=("-metadata" "date=$META_YEAR"); fi
# No universal "narrator" tag; store in comment (works in many players)
if [ -n "$META_NARRATOR" ]; then FFMETA_ARGS+=("-metadata" "comment=Narrator: $META_NARRATOR"); fi

echo ""
echo "Building audiobook..."
echo ""
echo "Quality: $QUALITY_MODE"
echo "Bitrate: $AUDIO_BITRATE"
if [ -n "$META_AUTHOR" ]; then echo "Author: $META_AUTHOR"; fi
if [ -n "$META_NARRATOR" ]; then echo "Narrator: $META_NARRATOR"; fi
if [ -n "$META_YEAR" ]; then echo "Year: $META_YEAR"; fi
if [ -n "$META_GENRE" ]; then echo "Genre: $META_GENRE"; fi
if [ -n "$META_ALBUM" ]; then echo "Album: $META_ALBUM"; fi
echo "Cover: $(basename "$COVER_FILE")"
echo ""

if [ -n "$COVER_FILE" ]; then

    ffmpeg \
        -f concat \
        -safe 0 \
        -i "$TEMP_LIST" \
        -i "$TEMP_META" \
        -i "$COVER_FILE" \
        -map 0:a \
        -map_metadata 1 \
        -map 2:v \
        -c:a aac \
        -b:a "$AUDIO_BITRATE" \
        -ac "$AUDIO_CHANNELS" \
        -c:v copy \
        -disposition:v attached_pic \
        -movflags +faststart \
        "${FFMETA_ARGS[@]}" \
        "$OUTPUT_NAME"

else

    ffmpeg \
        -f concat \
        -safe 0 \
        -i "$TEMP_LIST" \
        -i "$TEMP_META" \
        -map_metadata 1 \
        -c:a aac \
        -b:a "$AUDIO_BITRATE" \
        -ac "$AUDIO_CHANNELS" \
        -movflags +faststart \
        "${FFMETA_ARGS[@]}" \
        "$OUTPUT_NAME"

fi

echo ""
echo "=================================="
echo "DONE"
echo "=================================="
echo ""
echo "Created:"
echo "  $OUTPUT_NAME"
echo ""