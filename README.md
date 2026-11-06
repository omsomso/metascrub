# MetaScrub

A macOS app (SwiftUI, Liquid Glass) for seeing, editing and removing the metadata inside files:
GPS positions in photos, camera and phone models, authors and companies in documents, edit
history, encoder tags, the prompts and workflows AI image generators save, and the "downloaded
from" records macOS attaches to files.

It has two parts, picked in the sidebar:

- **Cleaner**: drop any number of files or folders, press **Clean**. Choose **Replace originals**
  (asks once; "Don't ask again" skips that) or **Save copies to folder**. Each row shows what
  kind of personal data was found (Location, Device, People, History) and, afterwards, how many
  fields were removed and anything kept (hover for details).
- **Viewer**: drop files (on the window, the sidebar or the Dock icon) to see every field,
  grouped into sections. Click a value to edit it, hover a row to remove it, use **Add Field**
  for new ones. Changes are listed in a bar at the bottom: **Save** rewrites the file, **Save
  As…** writes a copy and leaves the original alone, **Revert** drops the edits. Photos and
  videos with a position get a location card; the map only loads when you press **Show Map**
  (it fetches tiles from Apple Maps). **Send to Cleaner** moves a file to the Cleaner.
  Right-click a row for **Copy Value**; long values (such as a whole workflow) also have a Copy
  button.

### AI image generators

Images from ComfyUI, Automatic1111/Forge, InvokeAI, SwarmUI, NovelAI and Fooocus carry the
generator's data: ComfyUI saves its node graph (`prompt`) and canvas (`workflow`) as PNG text,
Automatic1111-style tools a `parameters` text (in PNG text, or the EXIF user comment in JPEG and
WebP). The viewer shows it under **AI Generation Data** and tags the file "AI Workflow"; a
**Generation Details** summary lists the model, LoRAs, prompts, seed, steps, CFG, sampler,
scheduler and size. JSON (node graphs, workflows) and fields over 4,000 characters are read-only
(Copy takes them); plain parameter text can be edited, and any of them removed. Saving other edits
keeps them. Clean removes all of it.

Cleaning options (Cleaner → Options): remove extended attributes (on), keep the colour profile
(on), keep the orientation (on), keep the original file dates (off; otherwise the cleaned file is
dated now).

## What it handles

| Format | Read | Edit | Clean | How cleaning works |
| --- | --- | --- | --- | --- |
| JPEG | EXIF, GPS, IPTC, XMP, maker notes, AI parameters in EXIF | yes | yes | Drops EXIF/XMP/IPTC/comment/preview segments and anything after the image; keeps the compressed picture byte for byte, JFIF density, Adobe colour info, ICC profile (option) and a minimal orientation tag (option) |
| PNG | text chunks (incl. AI workflows), EXIF, XMP | yes: text chunks directly, other fields by a lossless rewrite that keeps every text chunk | yes | Keeps only image, transparency, colour, animation (APNG) and density chunks |
| HEIC / HEIF / AVIF | EXIF, GPS, XMP | yes (lossless copy; re-compresses only if macOS refuses a change, and says so) | yes | Blanks the EXIF and XMP items in place; the picture, depth and HDR data, orientation and colour are untouched |
| GIF | comments, XMP | read-only | yes | Keeps frames, timing and looping; drops comments and other application blocks |
| WebP | EXIF, XMP | read-only (macOS can't write WebP) | yes | Drops the EXIF and XMP chunks and their header flags |
| TIFF | EXIF, GPS, IPTC, XMP | yes | yes | Re-saves the pixels without metadata (lossless) |
| Other images ImageIO reads (camera raw, PSD, BMP…) | yes | no | file attributes only | — |
| MP3 | ID3v2.2–2.4, ID3v1, APE | ID3v2.3/2.4 and ID3v1 | yes | Keeps only the audio frames |
| FLAC | Vorbis comments, pictures, other blocks | comments, remove pictures/blocks | yes | Keeps stream info and seek table |
| WAV | INFO, bext, iXML, XMP, ID3 | INFO fields | yes | Keeps format, audio, cue/loop/instrument chunks |
| AIFF / AIFF-C | name/author/copyright/annotation, comments, ID3 | text chunks | yes | Keeps format, audio, markers, instrument, channel layout |
| MP4 / MOV / M4A / M4V / 3GP | iTunes tags, QuickTime metadata and user data, location | yes (pass-through export, nothing re-encoded) | yes | Turns the metadata boxes into padding of the same size and zeroes the recording times; nothing moves |
| PDF | Info dictionary, XMP, comment authors | Info fields, remove XMP | yes | PDFKit re-saves it (dropping old revisions); then the XMP packet, Producer and dates are blanked and comment author names cleared |
| Word / Excel / PowerPoint (docx, xlsx, pptx…) | core, app and custom properties, thumbnail, part dates | yes | yes | Empties core and custom properties, removes company/manager/template/editing time and the thumbnail, resets the ZIP part dates |
| OpenDocument (odt, ods, odp…) | meta.xml, thumbnail | yes | yes | Empties meta.xml (keeps statistics), removes the thumbnail |
| Any other file | file info, extended attributes, Spotlight | dates, remove attributes | extended attributes | — |

For every file the viewer also shows file-system details (dates are editable), extended
attributes (download source, quarantine, Finder tags; each removable), and what Spotlight indexed.

After cleaning, the file is read again and anything still present is reported as "kept" rather
than assumed gone.

### Known limits

- Saving edits to MP4-family files goes through AVFoundation's pass-through export. Codecs it
  can't copy (for example xHE-AAC audio) fail with a message and the file is left as it was;
  cleaning those files still works.
- PDFKit doesn't keep custom Info fields when saving, and stamps its own Producer; MetaScrub puts
  the Producer back when it fits in the same space. Names inside Office documents (comment and
  tracked-change authors) and inside PDF page content aren't changed.
- ID3v2.2 tags, timed metadata tracks in videos, Ogg/Opus, Matroska/WebM, EPUB and camera raw
  files are read-only or not read.
- macOS adds a few attributes it protects itself (`com.apple.provenance`, `com.apple.macl`); they
  can't be removed and aren't counted.

## Build and run

```sh
./build.sh                       # builds build/MetaScrub.app (ad-hoc signed, local use)
open build/MetaScrub.app
```

Requires macOS 26 (Liquid Glass) and Xcode 26 or newer; the script uses Xcode's toolchain. Copy
the app to /Applications to keep it. The icon is drawn by `icon/make_icon.swift`; run
`icon/make-icns.sh` to rebuild `Resources/AppIcon.icns`.

### With omso Builder

The repository is registered in omso Builder and describes its build in `omso-build.json`:
`build.sh`, the engine tests (`test.sh`), then `MetaScrub --self-test`, which makes a photo and a
PDF with personal metadata in the run folder and checks that cleaning and editing work and leave
the pixels and text alone. **Build & Install** then copies `MetaScrub.app` into
`/Applications/omso` (the only app folder omso Builder installs to).

Command line (same engine, no window):

```sh
build/MetaScrub.app/Contents/MacOS/MetaScrub --inspect FILE…
build/MetaScrub.app/Contents/MacOS/MetaScrub --clean FILE… --out FOLDER
build/MetaScrub.app/Contents/MacOS/MetaScrub --clean FILE… --in-place
build/MetaScrub.app/Contents/MacOS/MetaScrub --self-test FOLDER   # checks the build on generated files
```

Clean options: `--keep-attributes`, `--drop-color-profile`, `--drop-orientation`, `--keep-dates`.

## Tests

```sh
./test.sh                        # xcrun swift test with Xcode's toolchain; extra arguments are passed on
```

The tests build sample files for every format (with known metadata), then read, edit and clean
them and check the content survives. An opt-in smoke test runs the same edit-then-clean cycle on
copies of real files and checks pixels, decoded audio, video frames and PDF text are unchanged:

```sh
METASCRUB_SAMPLES=/path/to/folder ./test.sh --filter RealFileTests
```

Screens can be captured without clicking: `METASCRUB_SNAPSHOT=/tmp/shots METASCRUB_FILES=a.jpg:b.pdf`
launches the app, saves PNGs of each screen, cleans copies into `/tmp/shots/cleaned` and quits.

## Layout

```text
Sources/MetaScrubCore/      engine, no UI
  Model.swift               report, sections, entries, edits, options
  Engine.swift              inspect / clean / save, file replacement
  FileFormat.swift          format detection from the first bytes
  FileSystem.swift          file info, extended attributes, Spotlight, safe writing
  Binary.swift              byte reading/writing helpers, CRC-32
  Formats/                  one handler per family (images, ID3/MP3, FLAC, WAV/AIFF, MP4, PDF, ZIP/Office)
Sources/MetaScrub/          SwiftUI app: sidebar, Cleaner, Viewer, command line, snapshots
Tests/MetaScrubCoreTests/   fixtures and per-format tests
```
