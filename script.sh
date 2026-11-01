#!/usr/bin/env bash
#
# Copyright 2026 Irvan
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied.
# See the License for the specific language governing
# permissions and limitations under the License.

set -Eeuo pipefail

# Build a multipage PDF from images in a Google Drive "Shared with me"
# folder, then upload it ONE LEVEL ABOVE the source folder.
#
# The PDF is built in a temporary directory and removed after the upload.
# Use --no-upload to keep a local copy in the current directory instead.
#
# Requires: rclone, ImageMagick (magick or convert), find, sort
# Optional: fzf (fuzzy folder browser; falls back to a numbered menu)

SCRIPT_NAME="${0##*/}"
REMOTE="${RCLONE_REMOTE:-gdrive-study}"
SHARED_FLAG=(--drive-shared-with-me)
REMOTE_DIR=""
PDF_NAME=""
ASSUME_YES=false
NO_UPLOAD=false
SAME_DIR=false
ORIGINAL=false
MAX_DIM=1600      
JPEG_QUALITY=65  

usage() {
    cat <<EOF_USAGE
Usage: $SCRIPT_NAME [options]

Download the images from a Google Drive folder (Shared with me), merge them
into one multipage PDF, and upload it one level above the source folder.
The PDF is built in a temp directory and deleted afterwards.
Run without options to pick the folder interactively.

Options:
  -d, --dir PATH      Source folder path (skips the interactive browser)
  -r, --remote NAME   rclone remote name (default: $REMOTE)
  -o, --output NAME   Output PDF name (default: <folder name>.pdf)
  -n, --no-upload     Don't upload; save the PDF in the current directory
      --same-dir      Upload into the source folder instead of its parent
  -m, --max-size PX   Shrink images whose longest side exceeds PX (default: $MAX_DIM)
  -q, --quality N     JPEG quality inside the PDF, 1-100 (default: $JPEG_QUALITY)
      --original      Keep original resolution and quality (large PDF)
  -y, --yes           Skip confirmations (overwrite without asking)
  -h, --help          Show this help

Environment:
  RCLONE_REMOTE       Default remote name (overridden by --remote)
  TMPDIR              Where the temporary directory is created (default: /tmp)
EOF_USAGE
}

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

confirm() {
    local prompt="$1" default="${2:-n}" reply hint

    $ASSUME_YES && return 0

    if [[ "$default" == y ]]; then
        hint='[Y/n]'
    else
        hint='[y/N]'
    fi

    read -r -p "$prompt $hint " reply || return 1
    reply="${reply:-$default}"
    [[ "$reply" == [yY]* ]]
}

parent_of() {
    local path="${1%/}"
    if [[ "$path" == */* ]]; then
        printf '%s' "${path%/*}"
    fi
    return 0
}

PICKED=""
pick_one() {
    local prompt="$1"
    shift

    local -a items=("$@")
    local i reply

    ((${#items[@]} > 0)) || return 1

    if command -v fzf >/dev/null 2>&1; then
        PICKED="$(printf '%s\n' "${items[@]}" |
            fzf --height=50% --reverse --prompt="$prompt > ")" || return 1
        [[ -n "$PICKED" ]] || return 1
        return 0
    fi

    printf '\n%s\n' "$prompt"
    for i in "${!items[@]}"; do
        printf '  %3d) %s\n' "$((i + 1))" "${items[i]}"
    done

    while true; do
        read -r -p '# (q to cancel)> ' reply || return 1
        [[ "$reply" == q ]] && return 1

        if [[ "$reply" =~ ^[0-9]+$ ]] &&
            (( reply >= 1 && reply <= ${#items[@]} )); then
            PICKED="${items[reply-1]}"
            return 0
        fi

        printf 'Enter a number between 1 and %d.\n' "${#items[@]}"
    done
}

while (($# > 0)); do
    case "$1" in
        -d|--dir)
            (($# >= 2)) || die "Missing value for $1"
            REMOTE_DIR="$2"
            shift 2
            ;;
        -r|--remote)
            (($# >= 2)) || die "Missing value for $1"
            REMOTE="$2"
            shift 2
            ;;
        -o|--output)
            (($# >= 2)) || die "Missing value for $1"
            PDF_NAME="$2"
            shift 2
            ;;
        -m|--max-size)
            (($# >= 2)) || die "Missing value for $1"
            MAX_DIM="$2"
            shift 2
            ;;
        -q|--quality)
            (($# >= 2)) || die "Missing value for $1"
            JPEG_QUALITY="$2"
            shift 2
            ;;
        --original)
            ORIGINAL=true
            shift
            ;;
        -n|--no-upload)
            NO_UPLOAD=true
            shift
            ;;
        --same-dir)
            SAME_DIR=true
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (see --help)"
            ;;
    esac
done

[[ "$MAX_DIM" =~ ^[0-9]+$ ]] && ((MAX_DIM >= 100)) ||
    die '--max-size must be a number of pixels (100 or more).'
[[ "$JPEG_QUALITY" =~ ^[0-9]+$ ]] && ((JPEG_QUALITY >= 1 && JPEG_QUALITY <= 100)) ||
    die '--quality must be a number from 1 to 100.'

for cmd in rclone find sort; do
    command -v "$cmd" >/dev/null 2>&1 || die "Command '$cmd' not found."
done

if command -v magick >/dev/null 2>&1; then
    IM=(magick)
elif command -v convert >/dev/null 2>&1; then
    IM=(convert)
else
    die 'ImageMagick not found (need "magick" or "convert").'
fi

resolve_remote() {
    local remote_name
    local -a remotes=()

    mapfile -t remotes < <(rclone listremotes)

    for remote_name in "${remotes[@]}"; do
        [[ "$remote_name" == "${REMOTE}:" ]] && return 0
    done

    ((${#remotes[@]} > 0)) || die 'No rclone remotes configured. Run: rclone config'
    [[ -t 0 ]] || die "rclone remote '${REMOTE}:' not found. Check: rclone listremotes"

    warn "rclone remote '${REMOTE}:' not found."
    pick_one 'Select an rclone remote' "${remotes[@]}" || die 'Cancelled.'
    REMOTE="${PICKED%:}"
}
resolve_remote

browse_folders() {
    local current="" listing name typed
    local -a dirs menu
    local SELECT='[ Select this folder ]'
    local UP='[ .. Go up ]'
    local TYPE='[ Type a path manually ]'

    while true; do
        if ! listing="$(rclone lsf "${REMOTE}:${current}" "${SHARED_FLAG[@]}" --dirs-only 2>&1)"; then
            [[ -n "$current" ]] || die "Cannot list Shared with me: $listing"
            warn "Cannot open '/${current}': $listing"
            current="$(parent_of "$current")"
            continue
        fi

        dirs=()
        while IFS= read -r name; do
            name="${name%/}"
            if [[ -n "$name" ]]; then
                dirs+=("$name")
            fi
        done <<< "$listing"

        if ((${#dirs[@]} > 0)); then
            mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | sort -V)
        fi

        menu=()
        if [[ -n "$current" ]]; then
            menu+=("$SELECT" "$UP")
        fi
        menu+=("$TYPE")
        for name in "${dirs[@]}"; do
            menu+=("${name}/")
        done

        pick_one "Browsing: /${current}" "${menu[@]}" || die 'Cancelled.'

        case "$PICKED" in
            "$SELECT")
                REMOTE_DIR="$current"
                return 0
                ;;
            "$UP")
                current="$(parent_of "$current")"
                ;;
            "$TYPE")
                read -e -r -p 'Path: ' typed || die 'Cancelled.'
                typed="${typed#/}"
                typed="${typed%/}"

                if [[ -n "$typed" ]] &&
                    rclone lsf "${REMOTE}:${typed}" "${SHARED_FLAG[@]}" --dirs-only --max-depth 1 >/dev/null 2>&1; then
                    current="$typed"
                else
                    warn "Path not found: /${typed}"
                fi
                ;;
            *)
                name="${PICKED%/}"
                current="${current:+${current}/}${name}"
                ;;
        esac
    done
}

if [[ -z "$REMOTE_DIR" ]]; then
    [[ -t 0 ]] || die 'No folder given. Use --dir PATH when not running interactively.'
    browse_folders
else
    REMOTE_DIR="${REMOTE_DIR#/}"
    REMOTE_DIR="${REMOTE_DIR%/}"

    rclone lsf "${REMOTE}:${REMOTE_DIR}" "${SHARED_FLAG[@]}" --max-depth 1 >/dev/null 2>&1 ||
        die "Folder not found in Shared with me: /${REMOTE_DIR}"
fi

[[ -n "$REMOTE_DIR" ]] || die 'Source folder cannot be empty.'
printf '\nSource folder: %s:/%s\n' "$REMOTE" "$REMOTE_DIR"

if [[ -z "$PDF_NAME" ]]; then
    default_name="${REMOTE_DIR##*/}.pdf"

    if [[ -t 0 ]] && ! $ASSUME_YES; then
        read -e -r -i "$default_name" -p 'PDF name: ' PDF_NAME || die 'Cancelled.'
        PDF_NAME="${PDF_NAME:-$default_name}"
    else
        PDF_NAME="$default_name"
    fi
fi

PDF_NAME="${PDF_NAME##*/}"
[[ -n "$PDF_NAME" && "$PDF_NAME" != '.' ]] || die 'Invalid PDF filename.'
[[ "${PDF_NAME,,}" == *.pdf ]] || PDF_NAME="${PDF_NAME}.pdf"

if $NO_UPLOAD; then
    OUTPUT="$PWD/$PDF_NAME"
    [[ ! -d "$OUTPUT" ]] || die "Output path is a directory: $OUTPUT"
    if [[ -e "$OUTPUT" ]]; then
        confirm "File '$OUTPUT' already exists. Overwrite?" n || exit 0
    fi
else
    if $SAME_DIR; then
        DEST_DIR="$REMOTE_DIR"
    else
        DEST_DIR="$(parent_of "$REMOTE_DIR")"
        if [[ -z "$DEST_DIR" ]]; then
            warn 'Source is a top-level shared folder; its parent (the Shared with me root) is not writable.'
            warn 'Uploading into the source folder instead.'
            DEST_DIR="$REMOTE_DIR"
        fi
    fi

    DEST_FOLDER="${REMOTE}:${DEST_DIR}"
    DEST_REMOTE="${DEST_FOLDER}/${PDF_NAME}"

    dest_listing="$(rclone lsf "$DEST_FOLDER" "${SHARED_FLAG[@]}" --files-only --max-depth 1)" ||
        die "Cannot list destination folder: /${DEST_DIR}"

    while IFS= read -r filename; do
        if [[ "$filename" == "$PDF_NAME" ]]; then
            confirm "Remote file '/${DEST_DIR}/${PDF_NAME}' already exists. Overwrite?" n || exit 0
            break
        fi
    done <<< "$dest_listing"
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT

SRC_DIR="$WORKDIR/src"
mkdir -p "$SRC_DIR"

if ! $NO_UPLOAD; then
    OUTPUT="$WORKDIR/$PDF_NAME"
fi

printf '\nDownloading folder contents...\n'
rclone copy "${REMOTE}:${REMOTE_DIR}" "$SRC_DIR" "${SHARED_FLAG[@]}" --progress

IMAGE_LIST="$WORKDIR/images.list"
find "$SRC_DIR" -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
       -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \
       -o -iname '*.tif' -o -iname '*.tiff' \
    \) -print0 | sort -z -V > "$IMAGE_LIST"

IMAGES=()
mapfile -d '' -t IMAGES < "$IMAGE_LIST"

((${#IMAGES[@]} > 0)) || die 'No supported image files found in the source folder.'

printf 'Found %d image(s). Page order:\n' "${#IMAGES[@]}"
n=0
for image in "${IMAGES[@]}"; do
    n=$((n + 1))
    printf '  %3d. %s\n' "$n" "${image#"$SRC_DIR"/}"
done

confirm 'Continue with this order?' y || { echo 'Aborted.'; exit 0; }

if $ORIGINAL; then
    printf '\nCreating PDF (original quality)...\n'
    "${IM[@]}" "${IMAGES[@]}" -auto-orient "$OUTPUT"
else
    printf '\nCreating PDF (max %dpx, JPEG quality %d)...\n' "$MAX_DIM" "$JPEG_QUALITY"
    "${IM[@]}" "${IMAGES[@]}" -auto-orient \
        -resize "${MAX_DIM}x${MAX_DIM}>" \
        -background white -alpha remove -alpha off \
        -compress JPEG -quality "$JPEG_QUALITY" \
        "$OUTPUT"
fi

[[ -s "$OUTPUT" ]] || die 'PDF creation failed or produced an empty file.'
printf 'PDF size: %s\n' "$(du -h -- "$OUTPUT" | cut -f1)"

if $NO_UPLOAD; then
    printf '\nDone. PDF saved locally: %s\n' "$OUTPUT"
    exit 0
fi

printf '\nUploading PDF to %s...\n' "$DEST_REMOTE"
if ! rclone copyto "$OUTPUT" "$DEST_REMOTE" "${SHARED_FLAG[@]}" --progress; then
    warn "Upload failed (you may not have write access to /${DEST_DIR})."
    warn 'The temporary PDF is being deleted. Try --same-dir, or --no-upload to keep a local copy.'
    exit 1
fi

printf '\nDone. Uploaded to: %s\n' "$DEST_REMOTE"
printf 'No local copy kept (temp files removed).\n'