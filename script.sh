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
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Build a multipage PDF from images in a Google Drive "Shared with me"
# folder, then upload it one level above the source folder.
#
# Source deletion is opt-in and has additional safeguards. By default, the
# source folder is kept.

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
REMOTE="${RCLONE_REMOTE:-gdrive-study}"
DRIVE_FLAGS=(--drive-shared-with-me --drive-use-trash=true)

REMOTE_DIR=""
PDF_NAME=""
ASSUME_YES=false
NO_UPLOAD=false
SAME_DIR=false
ORIGINAL=false
DELETE_SOURCE=false

MAX_DIM=1600
JPEG_QUALITY=65

usage() {
    cat <<EOF_USAGE
Usage: $SCRIPT_NAME [options]

Download images from a Google Drive "Shared with me" folder, merge them
into one multipage PDF, and upload the PDF one level above the source folder.

By default, the source folder is NOT deleted.

Options:
  -d, --dir PATH       Source folder path relative to "Shared with me"
  -r, --remote NAME    rclone remote name (default: $REMOTE)
  -o, --output NAME    Output PDF filename (default: <folder name>.pdf)
  -n, --no-upload      Do not upload; save the PDF in the current directory
      --same-dir       Upload into the source folder instead of its parent
      --delete-source  Remove the source folder after a verified upload
  -m, --max-size PX    Shrink images whose longest side exceeds PX (default: $MAX_DIM)
  -q, --quality N      JPEG quality inside the PDF, 1-100 (default: $JPEG_QUALITY)
      --original       Keep original resolution and quality (large PDF)
  -y, --yes            Skip ordinary confirmations (never skips deletion confirmation)
  -h, --help           Show this help

Environment:
  RCLONE_REMOTE        Default rclone remote name (overridden by --remote)
  TMPDIR               Temporary directory location (default: /tmp)

Safety notes:
  * --delete-source requires an upload to the parent directory.
  * --delete-source cannot be combined with --same-dir or --no-upload.
  * Deletion requires an interactive, exact-path confirmation. -y cannot bypass it.
  * The deletion preview uses rclone --dry-run.
  * Google Drive trash is explicitly enabled; files are not force-deleted permanently.
EOF_USAGE
}

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

confirm() {
    local prompt="$1" default="${2:-n}" reply hint

    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi

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
}

normalize_source_path() {
    local path="$1"
    local segment
    local -a segments=()

    [[ -n "$path" ]] || die 'Source path is empty; refusing to operate on the remote root.'

    path="${path#/}"
    while [[ "$path" == */ ]]; do
        path="${path%/}"
    done

    [[ -n "$path" ]] || die 'Source path resolves to the remote root; refusing.'
    [[ "$path" != /* ]] || die 'Source path contains multiple leading slashes; refusing.'
    [[ "$path" != *//* ]] || die 'Source path contains an empty path segment; refusing.'

    IFS='/' read -r -a segments <<< "$path"
    for segment in "${segments[@]}"; do
        [[ -n "$segment" ]] || die 'Source path contains an empty segment; refusing.'
        [[ "$segment" != '.' && "$segment" != '..' ]] ||
            die "Source path contains a traversal segment ('$segment'); refusing."
    done

    printf '%s' "$path"
}

PICKED=""
pick_one() {
    local prompt="$1"
    shift

    local -a items=("$@")
    local i reply

    ((${#items[@]} > 0)) || return 1

    if command -v fzf >/dev/null 2>&1; then
        PICKED="$(printf '%s\n' "${items[@]}" | fzf --height=50% --reverse --prompt="$prompt > ")" || return 1
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
            PICKED="${items[reply - 1]}"
            return 0
        fi

        printf 'Enter a number between 1 and %d.\n' "${#items[@]}"
    done
}

resolve_remote() {
    local remote_name
    local -a remotes=()

    [[ -n "$REMOTE" && "$REMOTE" != *:* && "$REMOTE" != */* ]] ||
        die "Invalid remote name: '$REMOTE'"

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

browse_folders() {
    local current="" listing name typed
    local -a dirs menu
    local SELECT='[ Select this folder ]'
    local UP='[ .. Go up ]'
    local TYPE='[ Type a path manually ]'

    while true; do
        if ! listing="$(rclone lsf "${REMOTE}:${current}" "${DRIVE_FLAGS[@]}" --dirs-only 2>&1)"; then
            [[ -n "$current" ]] || die "Cannot list Shared with me: $listing"
            warn "Cannot open '/${current}': $listing"
            current="$(parent_of "$current")"
            continue
        fi

        dirs=()
        while IFS= read -r name; do
            name="${name%/}"
            [[ -n "$name" ]] && dirs+=("$name")
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
                REMOTE_DIR="$typed"
                return 0
                ;;
            *)
                name="${PICKED%/}"
                current="${current:+${current}/}${name}"
                ;;
        esac
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
        --delete-source)
            DELETE_SOURCE=true
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

[[ "$MAX_DIM" =~ ^[0-9]+$ ]] && (( MAX_DIM >= 100 )) ||
    die '--max-size must be a number of pixels (100 or more).'
[[ "$JPEG_QUALITY" =~ ^[0-9]+$ ]] && (( JPEG_QUALITY >= 1 && JPEG_QUALITY <= 100 )) ||
    die '--quality must be a number from 1 to 100.'

if [[ "$DELETE_SOURCE" == true ]]; then
    [[ "$NO_UPLOAD" == false ]] || die '--delete-source cannot be used with --no-upload.'
    [[ "$SAME_DIR" == false ]] || die '--delete-source cannot be used with --same-dir.'
fi

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

resolve_remote

if [[ -z "$REMOTE_DIR" ]]; then
    [[ -t 0 ]] || die 'No folder given. Use --dir PATH when not running interactively.'
    browse_folders
fi

REMOTE_DIR="$(normalize_source_path "$REMOTE_DIR")"
SOURCE_REMOTE="${REMOTE}:${REMOTE_DIR}"
printf '\nSource folder: %s\n' "$SOURCE_REMOTE"

rclone lsd "$SOURCE_REMOTE" "${DRIVE_FLAGS[@]}" --max-depth 1 >/dev/null 2>&1 ||
    die "Source folder not found or not accessible in Shared with me: $SOURCE_REMOTE"

if [[ -z "$PDF_NAME" ]]; then
    default_name="${REMOTE_DIR##*/}.pdf"
    if [[ -t 0 && "$ASSUME_YES" == false ]]; then
        read -e -r -i "$default_name" -p 'PDF name: ' PDF_NAME || die 'Cancelled.'
        PDF_NAME="${PDF_NAME:-$default_name}"
    else
        PDF_NAME="$default_name"
    fi
fi

[[ -n "$PDF_NAME" && "$PDF_NAME" != '.' && "$PDF_NAME" != '..' && "$PDF_NAME" != */* ]] ||
    die 'Output must be a filename, not a path.'
[[ "$PDF_NAME" != *$'\n'* && "$PDF_NAME" != *$'\r'* ]] ||
    die 'Output filename cannot contain a newline.'
[[ "${PDF_NAME,,}" == *.pdf ]] || PDF_NAME="${PDF_NAME}.pdf"

DEST_DIR=""
DEST_FOLDER=""
DEST_REMOTE=""

if [[ "$NO_UPLOAD" == false ]]; then
    if [[ "$SAME_DIR" == true ]]; then
        DEST_DIR="$REMOTE_DIR"
    else
        DEST_DIR="$(parent_of "$REMOTE_DIR")"
        if [[ -z "$DEST_DIR" ]]; then
            if [[ "$DELETE_SOURCE" == true ]]; then
                die 'The source is at the top level of Shared with me. A safe parent destination is unavailable; source deletion is refused.'
            fi
            warn 'The source is at the top level of Shared with me; no parent destination is available.'
            warn 'Falling back to upload into the source folder. The source will be kept.'
            DEST_DIR="$REMOTE_DIR"
        fi
    fi

    if [[ "$DELETE_SOURCE" == true ]]; then
        [[ -n "$DEST_DIR" && "$DEST_DIR" != "$REMOTE_DIR" ]] ||
            die 'Unsafe destination: PDF would not be outside the source folder.'
        [[ "$(parent_of "$REMOTE_DIR")" == "$DEST_DIR" ]] ||
            die 'Unsafe destination: expected the immediate parent of the source folder.'
    fi

    DEST_FOLDER="${REMOTE}:${DEST_DIR}"
    DEST_REMOTE="${DEST_FOLDER}/${PDF_NAME}"

    dest_listing="$(rclone lsf "$DEST_FOLDER" "${DRIVE_FLAGS[@]}" --files-only --max-depth 1)" ||
        die "Cannot list destination folder: /${DEST_DIR}"

    while IFS= read -r filename; do
        if [[ "$filename" == "$PDF_NAME" ]]; then
            confirm "Remote file '/${DEST_DIR}/${PDF_NAME}' already exists. Overwrite?" n || exit 0
            break
        fi
    done <<< "$dest_listing"
else
    OUTPUT="$PWD/$PDF_NAME"
    [[ ! -d "$OUTPUT" ]] || die "Output path is a directory: $OUTPUT"
    if [[ -e "$OUTPUT" ]]; then
        confirm "File '$OUTPUT' already exists. Overwrite?" n || exit 0
    fi
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT

SRC_DIR="$WORKDIR/src"
mkdir -p "$SRC_DIR"

if [[ "$NO_UPLOAD" == false ]]; then
    OUTPUT="$WORKDIR/$PDF_NAME"
fi

printf '\nDownloading folder contents...\n'
rclone copy "$SOURCE_REMOTE" "$SRC_DIR" "${DRIVE_FLAGS[@]}" --progress

IMAGE_LIST="$WORKDIR/images.list"
find "$SRC_DIR" -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
       -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \
       -o -iname '*.tif' -o -iname '*.tiff' \) -print0 |
    sort -z -V > "$IMAGE_LIST"

IMAGES=()
mapfile -d '' -t IMAGES < "$IMAGE_LIST"

((${#IMAGES[@]} > 0)) || die 'No supported image files found in the source folder.'

printf 'Found %d image(s). Page order:\n' "${#IMAGES[@]}"
n=0
for image_path in "${IMAGES[@]}"; do
    n=$((n + 1))
    printf '  %3d. %s\n' "$n" "${image_path#"$SRC_DIR"/}"
done

confirm 'Continue with this order?' y || { printf 'Aborted.\n'; exit 0; }

if [[ "$ORIGINAL" == true ]]; then
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

if [[ "$NO_UPLOAD" == true ]]; then
    printf '\nDone. PDF saved locally: %s\n' "$OUTPUT"
    exit 0
fi

printf '\nUploading PDF to %s...\n' "$DEST_REMOTE"
rclone copyto "$OUTPUT" "$DEST_REMOTE" "${DRIVE_FLAGS[@]}" --progress || {
    warn "Upload failed (you may not have write access to /${DEST_DIR})."
    warn 'The temporary PDF is being deleted. Use --no-upload to keep a local copy.'
    exit 1
}

uploaded_files="$(rclone lsf "$DEST_FOLDER" "${DRIVE_FLAGS[@]}" --files-only --max-depth 1)" ||
    die 'Upload returned success, but the destination could not be verified. Source folder was kept.'
if ! grep -Fxq -- "$PDF_NAME" <<< "$uploaded_files"; then
    die 'Uploaded PDF was not found in the destination listing. Source folder was kept.'
fi

printf '\nPDF upload verified: %s\n' "$DEST_REMOTE"

if [[ "$DELETE_SOURCE" == true ]]; then
    [[ -n "$REMOTE_DIR" && "$REMOTE_DIR" != '.' && "$REMOTE_DIR" != '..' ]] ||
        die 'Unsafe source path detected; refusing deletion.'
    [[ "$DEST_DIR" == "$(parent_of "$REMOTE_DIR")" && "$DEST_DIR" != "$REMOTE_DIR" ]] ||
        die 'Destination is not the immediate parent of the source; refusing deletion.'
    [[ "$DEST_REMOTE" == "${REMOTE}:${DEST_DIR}/${PDF_NAME}" ]] ||
        die 'Destination path mismatch; refusing deletion.'

    rclone lsd "$SOURCE_REMOTE" "${DRIVE_FLAGS[@]}" --max-depth 1 >/dev/null 2>&1 ||
        die 'Source folder can no longer be verified; refusing deletion.'

    printf '\nDeletion preview (dry-run only; no files will be removed):\n'
    rclone purge "$SOURCE_REMOTE" "${DRIVE_FLAGS[@]}" --dry-run -vv ||
        die 'Deletion preview failed; source folder was kept.'

    printf '\nThe following folder is the ONLY deletion target:\n  %s\n' "$SOURCE_REMOTE"
    printf 'Its contents will be moved to Google Drive Trash (not force-deleted permanently).\n'

    if [[ ! -t 0 || ! -t 1 ]]; then
        warn 'No interactive terminal is available. Skipping source deletion.'
        warn 'The PDF is uploaded; the source folder has been kept.'
    else
        typed_path=''
        read -r -p "Type the exact path '$SOURCE_REMOTE' to confirm deletion: " typed_path || typed_path=''

        if [[ "$typed_path" != "$SOURCE_REMOTE" ]]; then
            printf 'Confirmation did not match. Source folder kept.\n'
        else
            rclone lsd "$SOURCE_REMOTE" "${DRIVE_FLAGS[@]}" --max-depth 1 >/dev/null 2>&1 ||
                die 'Source folder verification failed at the last check; refusing deletion.'

            printf '\nRemoving source folder: %s\n' "$SOURCE_REMOTE"
            rclone purge "$SOURCE_REMOTE" "${DRIVE_FLAGS[@]}" --verbose ||
                die 'rclone purge failed. Check Google Drive before retrying; some items may have been processed.'
            printf 'Source folder removal completed.\n'
        fi
    fi
fi

printf '\nDone. Uploaded to: %s\n' "$DEST_REMOTE"
if [[ "$DELETE_SOURCE" == true ]]; then
    printf 'Local temporary files removed.\n'
else
    printf 'Source folder kept. Local temporary files removed.\n'
fi
