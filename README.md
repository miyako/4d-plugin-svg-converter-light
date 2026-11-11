4d-plugin-svg-converter-light
=============================

Converts SVG pictures to PDF. The plugin parses the SVG with a bundled copy of libsvg / libsvg-cairo (the code behind the [SVG2PDF](https://github.com/db9052/pdf2svg) program) and draws it on a cairo PDF surface, so the result is a vector PDF document returned in a `BLOB`. One command converts a single `Picture`; the other turns an `ARRAY PICTURE` into one multi-page PDF, one page per SVG.

Not every SVG feature is implemented (`mask`, for example, is not).

**Related projects**: [4d-plugin-PDF2SVG](https://github.com/miyako/4d-plugin-PDF2SVG), [4d-plugin-svg-converter](https://github.com/miyako/4d-plugin-svg-converter)

| Command | Returns | Purpose |
|---|---|---|
| [SVGL Convert](#svgl-convert) | `Longint` status | Convert one SVG picture to a one-page PDF |
| [SVGL Convert array](#svgl-convert-array) | `Longint` status | Convert a picture array to a multi-page PDF |

**Platforms:** macOS, Windows (64-bit)

---

## Requirements & platform notes

- **The picture must contain SVG data.** The plugin looks for the `.svg` format among the formats stored in the picture (for example a picture read from an `.svg` file). A picture that holds only PNG, JPEG or PDF data is not converted.
- **The PDF is appended to the `BLOB` you pass.** The plugin reads the current contents of the `BLOB` parameter and adds the PDF bytes after them. Pass an empty `BLOB` (`SET BLOB SIZE($pdf;0)`), or the result is not a valid PDF.
- **Both commands take six parameters.** The sixth (`Longint`) is read but ignored; pass `0`.
- **Units.** One SVG user unit (pixel) becomes one PDF point (1/72 inch).
- **Images inside the SVG.** `<image>` elements are drawn when they reference PNG or JPEG data, either inline (a base64 `data:` URI) or as a local file URL. Referenced files are read from disk with the rights of the 4D process, so think twice before converting SVG from untrusted sources.
- **Windows binary.** Behaviour marked "since this version's review fixes" below reaches Windows only once `Windows64/SVG Converter Light.4DX` is rebuilt by the release workflow.
- Bundled libraries:
  - macOS: cairo 1.12.14, pixman, libpng and libjpeg are linked statically. Text is drawn with the fonts installed on the Mac (through Quartz). libxml2 and zlib are the system's. To build the plugin yourself, first run `scripts/build-macos-deps.sh`: it builds the four libraries into `a/` as universal (arm64 + x86_64) archives from pinned source releases. The release workflow runs it too and caches the result.
  - Windows: the DLLs in `Contents/Windows64/` (cairo, pixman, libpng, libjpeg, zlib, libxml2, libiconv, freetype, fontconfig).

---

## SVGL Convert

### Syntax

```
status:=SVGL Convert ( svg ; pdf ; width ; height ; scale ; reserved )
```

| Parameter | Type | Description |
|---|---|---|
| `svg` | `Picture` | Picture that contains SVG data |
| `pdf` | `BLOB` | Receives the PDF document (appended to the current contents) |
| `width` | `Longint` | Page width in points, or `0` (see below) |
| `height` | `Longint` | Page height in points, or `0` (see below) |
| `scale` | `Real` | Scale factor, used only when `width` and `height` are both `0` or less. `0` means `1` |
| `reserved` | `Longint` | **Ignored**. Pass `0` |
| Result | `Longint` | `0` on success, otherwise an error code (see [Error handling & troubleshooting](#error-handling--troubleshooting)) |

### Description

`SVGL Convert` renders the SVG stored in `svg` on a single PDF page and writes the PDF document into `pdf`.

The page size comes from the SVG's own size (its `width` and `height` attributes; an SVG without them measured 450 × 450 in a test) and the three size parameters:

| `width` | `height` | Page size | Drawing |
|---|---|---|---|
| ≤ 0 | ≤ 0 | SVG size × `scale` | scaled by `scale` |
| ≤ 0 | > 0 | `height`; the width keeps the aspect ratio | scaled to fit `height` |
| > 0 | ≤ 0 | `width`; the height keeps the aspect ratio | scaled to fit `width` |
| > 0 | > 0 | `width` × `height` | scaled to fit inside the page, aspect ratio kept, centred |

`scale` is ignored as soon as `width` or `height` is positive. A `scale` of `0` is treated as `1`. A negative or non-finite `scale` is also treated as `1` since this version's review fixes; before, it produced an invalid page size.

If the picture contains no SVG data, the command returns `-2` and leaves `pdf` unchanged.

### Example

```4d
C_PICTURE($svg)
C_BLOB($pdf)
C_LONGINT($status)

READ PICTURE FILE(Get 4D folder(Database folder)+"drawing.svg";$svg)
SET BLOB SIZE($pdf;0)

$status:=SVGL Convert($svg;$pdf;0;0;1;0)

If ($status=0)
	BLOB TO DOCUMENT(Get 4D folder(Database folder)+"drawing.pdf";$pdf)
End if
```

Fit the drawing on an A4 portrait page (595 × 842 points), centred:

```4d
SET BLOB SIZE($pdf;0)
$status:=SVGL Convert($svg;$pdf;595;842;0;0)
```

Make the page 200 points wide and let the height follow the aspect ratio:

```4d
SET BLOB SIZE($pdf;0)
$status:=SVGL Convert($svg;$pdf;200;0;0;0)
```

---

## SVGL Convert array

### Syntax

```
status:=SVGL Convert array ( svgs ; pdf ; width ; height ; scale ; reserved )
```

| Parameter | Type | Description |
|---|---|---|
| `svgs` | `ARRAY PICTURE` | Pictures that contain SVG data, one page each |
| `pdf` | `BLOB` | Receives the PDF document (appended to the current contents) |
| `width` | `Longint` | Page width in points, or `0` |
| `height` | `Longint` | Page height in points, or `0` |
| `scale` | `Real` | Scale factor, used only when `width` and `height` are both `0` or less. `0` means `1` |
| `reserved` | `Longint` | **Ignored**. Pass `0` |
| Result | `Longint` | Status of the last page processed: `0` on success, otherwise an error code |

### Description

`SVGL Convert array` writes one PDF document with one page per SVG picture in `svgs`, in array order. Each page is sized with the same rules as [SVGL Convert](#svgl-convert), from that picture's own SVG size, so pages can differ in size when `width` and `height` are `0`.

- **Element 0 is included.** The loop starts at element `0`, so a picture stored there becomes the first page. Elements without SVG data (such as an empty element `0`) are skipped without error.
- **Only the last status is returned.** Each page overwrites the result, so a failure on an early page is hidden by a later success; that page is simply missing from the PDF.
- If no element contains SVG data, the result is `0` and `pdf` is unchanged.
- **Since this version's review fixes**, all pages go into a single PDF document. Earlier builds wrote a separate, unfinished PDF per picture into the same `BLOB` (macOS's PDF reader saw only the last page) and leaked memory for every page but the last.

### Example

```4d
ARRAY PICTURE($svgs;0)
C_PICTURE($svg)
C_BLOB($pdf)
C_LONGINT($status)

READ PICTURE FILE(Get 4D folder(Database folder)+"page1.svg";$svg)
APPEND TO ARRAY($svgs;$svg)
READ PICTURE FILE(Get 4D folder(Database folder)+"page2.svg";$svg)
APPEND TO ARRAY($svgs;$svg)

SET BLOB SIZE($pdf;0)
$status:=SVGL Convert array($svgs;$pdf;0;0;1;0)

If ($status=0)
	BLOB TO DOCUMENT(Get 4D folder(Database folder)+"pages.pdf";$pdf)
End if
```

Put every SVG on a page of the same size (US Letter, 612 × 792 points):

```4d
SET BLOB SIZE($pdf;0)
$status:=SVGL Convert array($svgs;$pdf;612;792;0;0)
```

---

## Error handling & troubleshooting

Both commands report problems through their result only; they never raise a 4D error.

| Result | Meaning |
|---|---|
| `0` | Success |
| `1` | Out of memory |
| `2` | I/O error |
| `3` | File not found |
| `4` | Invalid value. Since this version's review fixes, also returned when the SVG's size is 0 or the computed page size is unusable |
| `5` | Invalid call |
| `6` | Parse error: the SVG could not be parsed |
| `-2` | The picture contains no SVG data (`SVGL Convert`) |

- **Result `-2`, or an unchanged `BLOB`**: the picture has no `.svg` format. Load it from the `.svg` file itself, not from a PNG or PDF rendering of it.
- **The output does not open as a PDF**: the `BLOB` was not empty before the call. Clear it with `SET BLOB SIZE($pdf;0)` first.
- **A page is missing from the multi-page PDF**: that picture failed or had no SVG data. `SVGL Convert array` returns only the last status, so convert the pictures one by one with [SVGL Convert](#svgl-convert) to find the culprit.
- **Parts of the drawing are missing**: libsvg doesn't implement the whole SVG specification (`mask`, for example).
- **The sixth parameter has no effect**: it is ignored.

---

## Quick reference

```4d
SET BLOB SIZE($pdf;0)
$status:=SVGL Convert($svg;$pdf;0;0;1;0)  // one page, SVG size

SET BLOB SIZE($pdf;0)
$status:=SVGL Convert($svg;$pdf;595;842;0;0)  // fit on A4, centred

SET BLOB SIZE($pdf;0)
$status:=SVGL Convert array($svgs;$pdf;0;0;1;0)  // one page per SVG

If ($status=0)
	BLOB TO DOCUMENT($path;$pdf)
End if
```
