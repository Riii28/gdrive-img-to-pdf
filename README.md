# Google Drive Image to PDF

A Bash utility to download images from a Google Drive **Shared with me** folder, combine them into a single multipage PDF, and upload the result back to Google Drive.

The PDF is generated in a temporary directory and automatically removed after a successful upload. You can also use `--no-upload` to save the PDF locally.

## Features

- Browse Google Drive shared folders interactively.
- Fuzzy folder selection with `fzf` (optional).
- Automatically falls back to a numbered menu when `fzf` is unavailable.
- Combine multiple images into a single multipage PDF.
- Automatically sort images using natural version sorting.
- Resize and compress images to reduce PDF file size.
- Preserve original image resolution and quality when needed.
- Upload the resulting PDF to the parent folder or source folder.
- Save the PDF locally without uploading.
- Automatically clean up temporary files.

## Requirements

### Required

- [rclone](https://rclone.org/) — Google Drive access and file transfers.
- [ImageMagick](https://imagemagick.org/) — Image processing and PDF generation.
- `find`
- `sort`

### Optional

- [fzf](https://github.com/junegunn/fzf) — Fuzzy folder selection.

## Installation

Clone the repository:

```bash
git clone <repository-url>
cd <repository-directory>
```

Make the script executable:

```bash
chmod +x script.sh
```

## Configuration

Before using the script, configure `rclone` with a Google Drive remote.

Run:

```bash
rclone config
```

Create a Google Drive remote and complete the authentication process.

By default, the script uses a remote named:

```text
gdrive-study
```

You can change the default remote using the `RCLONE_REMOTE` environment variable:

```bash
RCLONE_REMOTE=mydrive ./script.sh
```

Alternatively, specify a remote directly using `--remote`:

```bash
./script.sh --remote mydrive
```

The remote must have access to the relevant folder in Google Drive's **Shared with me** section.

## Usage

### Interactive mode

Run the script without arguments:

```bash
./script.sh
```

The script will:

1. Display available folders in Google Drive's Shared with me.
2. Allow you to navigate through folders.
3. Let you select the source folder.
4. Ask for the output PDF filename.
5. Display the detected images and their processing order.
6. Ask for confirmation before generating the PDF.
7. Generate and upload the PDF.

### Specify a source folder

Skip the interactive folder browser by providing a folder path:

```bash
./script.sh --dir "Study/Mathematics"
```

### Save the PDF locally

Use `--no-upload` to prevent uploading the PDF.

```bash
./script.sh --dir "Study/Mathematics" --no-upload
```

The generated PDF will be saved in the current working directory.

### Specify the output filename

```bash
./script.sh \
  --dir "Study/Mathematics" \
  --output "Mathematics Notes.pdf"
```

### Upload to the source folder

By default, the PDF is uploaded **one level above the source folder**.

Use `--same-dir` to upload it directly into the source folder instead:

```bash
./script.sh --dir "Study/Mathematics" --same-dir
```

### Use original image quality

By default, images are resized and compressed to reduce PDF size.

Use `--original` to preserve their original resolution and quality:

```bash
./script.sh --dir "Study/Mathematics" --original
```

This may produce significantly larger PDF files.

## Options

| Option | Description |
|---|---|
| `-d, --dir PATH` | Source folder path. Skips interactive folder selection. |
| `-r, --remote NAME` | Specify the rclone remote. Default: `gdrive-study`. |
| `-o, --output NAME` | Specify the output PDF filename. |
| `-n, --no-upload` | Save the PDF locally without uploading. |
| `--same-dir` | Upload the PDF into the source folder instead of its parent. |
| `-m, --max-size PX` | Maximum image dimension in pixels. Default: `1600`. |
| `-q, --quality N` | JPEG quality from 1 to 100. Default: `65`. |
| `--original` | Preserve original image resolution and quality. |
| `-y, --yes` | Skip confirmations and automatically overwrite existing files. |
| `-h, --help` | Display help information. |

## Image Processing

By default, the script applies the following processing:

- Automatically correct image orientation.
- Resize images whose longest side exceeds 1600 pixels.
- Convert transparency to a white background.
- Compress images using JPEG compression.
- Set JPEG quality to 65.

You can customize the image dimensions and quality:

```bash
./script.sh \
  --dir "Study/Mathematics" \
  --max-size 2000 \
  --quality 80
```

To avoid resizing and compression, use `--original`.

### Supported Image Formats

- JPG / JPEG
- PNG
- WEBP
- BMP
- GIF
- TIF / TIFF

Images are processed in natural version order.

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `RCLONE_REMOTE` | Default rclone remote name. | `gdrive-study` |
| `TMPDIR` | Directory used for temporary files. | `/tmp` |

## Examples

Generate and upload a PDF:

```bash
./script.sh --dir "Study/Chapter 1"
```

Generate a locally saved PDF:

```bash
./script.sh --dir "Study/Chapter 1" --no-upload
```

Upload directly into the source folder:

```bash
./script.sh --dir "Study/Chapter 1" --same-dir
```

Use a different Google Drive remote:

```bash
./script.sh --remote mydrive --dir "Study/Chapter 1"
```

Generate a compressed PDF with custom settings:

```bash
./script.sh \
  --dir "Study/Chapter 1" \
  --max-size 1800 \
  --quality 75 \
  --output "Chapter 1.pdf"
```

Skip confirmation prompts:

```bash
./script.sh --dir "Study/Chapter 1" --yes
```

## Notes

- The script only accesses Google Drive folders available through `rclone`'s `--drive-shared-with-me` flag.
- Uploading requires sufficient write permissions on the destination folder.
- By default, the destination is the parent folder of the selected source folder.
- If the source folder is at the root of Shared with me, the script falls back to uploading into the source folder.
- Temporary files are automatically removed when the script exits.
- When using `--no-upload`, the generated PDF remains in the current working directory.
- Existing files require confirmation before being overwritten, unless `--yes` is specified.

## License

Copyright 2026 Irvan.

This project is licensed under the [Apache License 2.0](LICENSE).