# Ownership regressions

`engine_harness.mm` links the real `4DPlugin.cpp`, the plugin classes and the unchanged bundled `4D Plugin API` with ASan/UBSan. It replaces the 4D engine (`Call4D`) with a synthetic one that counts live engine strings, handles and reference-counted pictures, and aborts on anything it does not model. cairo and libsvg-cairo are stubbed: synthetic SVG text "parses", nothing is rendered, and the PDF stream callback receives marker bytes so the BLOB output can be checked. Every surface, context and parser the stub hands out is tracked.

`SVGL Convert` and `SVGL Convert array` run through `PluginMain` on synthetic in-memory pictures. No files are read or written.

```sh
tests/ownership/run.sh . fixed                # every test must pass

B=$(mktemp -d); git archive <base-sha> | tar -x -C "$B"
tests/ownership/run.sh "$B" baseline          # named defects must fail, controls pass
```

| Test | Checks |
|---|---|
| `defect_picture_fromfile_ownership` | `C_PICTURE::fromFileAtPath` frees the path once and releases the loaded picture |
| `defect_picture_setbytes_leak` | `C_PICTURE::setBytes` releases the picture it creates |
| `defect_picture_createcopy_ownership` | `createCopy*` reads only the converted type and leaves no empty owners |
| `defect_picture_grayscale_owner_leak`, `defect_picture_getsize_owner_leak`, `defect_picture_thumbnail_owner_leak` | no empty picture owner leaks |
| `control_convert_*` | `SVGL Convert` (SVG, no SVG, parse error) and `SVGL Convert array` (mixed array, undefined variable) leave caller pictures and the array untouched and release every handle, surface, context and parser |
| `control_array_text_transfer`, `control_picture_param_return` | `ARRAY_TEXT` transfer, picture parameter/return |

`C_PICTURE` is compiled into the plugin, but the SVGL commands only call `fromParamAtIndex`, `getBytesPtr` and `getBytesLength`.

Not covered:
- Windows and a real 4D runtime; real cairo/libsvg rendering.
- Whether the type string from `PA_GetPictureData` is owned by the caller. The harness models it as borrowed from the picture, as every `C_PICTURE` caller assumes.
- How the real engine treats the old value of a picture output parameter. The harness assumes the most forgiving model: the engine releases it.
- The BLOB parameter is passed as a NULL handle. A non-NULL empty BLOB makes `C_BLOB::fromParamAtIndex` take `&vector[0]` of an empty vector, which UBSan reports; that is not an ownership issue and is not changed here.
