4d-plugin-svg-converter-light
=============================

4D implementation of the SVG2PDF program.

### Platform

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img src="https://cloud.githubusercontent.com/assets/1725068/18940649/21945000-8645-11e6-86ed-4a0f800e5a73.png" width="32" height="32" /> <img src="https://cloud.githubusercontent.com/assets/1725068/18940648/2192ddba-8645-11e6-864d-6d5692d55717.png" width="32" height="32" />

## Syntax

```
error:=SVGL Convert (svg;image;width;height;scale)
```

Parameter|Type|Description
------------|------------|----
svg|PICTURE|
image|BLOB|
width|LONGINT|
height|LONGINT|
scale|REAL|
error|LONGINT|

```
error:=SVGL Convert array (svg;image;width;height;scale)
```

Parameter|Type|Description
------------|------------|----
svg|ARRAY PICTURE|
image|BLOB|each svg is a page in PDF
width|LONGINT|
height|LONGINT|
scale|REAL|
error|LONGINT|
