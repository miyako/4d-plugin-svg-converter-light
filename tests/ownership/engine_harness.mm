/*
 * Synthetic 4D engine boundary for SVG Converter Light ownership regressions.
 *
 * Links the real plugin source (4DPlugin.cpp), the plugin classes
 * (4D Plugin API/Classes) and the bundled, unmodified 4D Plugin API
 * (4DPluginAPI.c). Two things are replaced:
 *  - gCall4D: models engine-side allocations (Unistrings, handles, pictures)
 *    with malloc/new so ASan reports double frees and use-after-free, and
 *    keeps a live set of every engine string, handle and picture so leaks
 *    are detected exactly.
 *  - cairo and libsvg-cairo: a stub that accepts synthetic SVG text, writes
 *    marker bytes through the PDF stream callback and tracks every surface,
 *    context and parser it hands out. Nothing is rendered.
 *
 * Engine semantics modelled (SDK contract):
 *  - PA_CreateVariable(eVK_Unistring / eVK_Picture) allocates an empty
 *    engine string / picture (4DPluginAPI.c); PA_SetStringVariable and
 *    PA_SetPictureVariable overwrite the variable shallowly.
 *  - PA_ClearVariable releases what the variable owns.
 *  - Pictures are reference counted: PA_DuplicatePicture(p, 1) retains,
 *    PA_DisposePicture releases one reference.
 *  - PA_GetPictureData returns a type string the picture keeps (borrowed)
 *    and copies the format data into the caller's handle.
 *  - Commands that write a picture into an output parameter (READ PICTURE
 *    FILE, CREATE THUMBNAIL) release the picture previously held by that
 *    variable (the most forgiving engine model).
 *  - PA_ConvertCharsetToCharset returns the BYTE size written (SDK comment).
 *
 * No files are read or written.
 */

#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "4DPlugin.h"
#include "C_PICTURE.h"
#include "ARRAY_TEXT.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

extern "C" Call4DProcPtr gCall4D;

typedef std::basic_string<PA_Unichar> u16;

/* ---- cairo / libsvg-cairo stub ---- */

struct _cairo_surface { cairo_write_func_t write; void *closure; int pages; };
struct _cairo { cairo_surface_t *surface; };
struct svg_cairo { std::string svg; };

static std::set<cairo_surface_t *> g_surfaces;
static std::set<cairo_t *> g_crs;
static std::set<svg_cairo_t *> g_svgcs;

static void stub_die(const char *msg) { fprintf(stderr, "ENGINE VIOLATION: %s\n", msg); fflush(stderr); abort(); }

static void stub_write(cairo_surface_t *s, const char *text) {
    s->write(s->closure, (const unsigned char *)text, (unsigned int)strlen(text));
}

extern "C" {

svg_cairo_status_t svg_cairo_create(svg_cairo_t **p) {
    *p = new svg_cairo;
    g_svgcs.insert(*p);
    return SVG_CAIRO_STATUS_SUCCESS;
}

svg_cairo_status_t svg_cairo_destroy(svg_cairo_t *p) {
    if(!g_svgcs.erase(p)) stub_die("destroyed an unknown svg_cairo_t");
    delete p;
    return SVG_CAIRO_STATUS_SUCCESS;
}

/* synthetic SVG: anything starting with "<svg" parses */
svg_cairo_status_t svg_cairo_parse_buffer(svg_cairo_t *p, const char *buf, size_t count) {
    if(!g_svgcs.count(p)) stub_die("parsed into an unknown svg_cairo_t");
    p->svg.assign(buf, count);
    return p->svg.compare(0, 4, "<svg") ? SVG_CAIRO_STATUS_PARSE_ERROR : SVG_CAIRO_STATUS_SUCCESS;
}

void svg_cairo_get_size(svg_cairo_t *p, unsigned int *w, unsigned int *h) {
    if(!g_svgcs.count(p)) stub_die("sized an unknown svg_cairo_t");
    *w = 10; *h = 20;
}

svg_cairo_status_t svg_cairo_render(svg_cairo_t *p, cairo_t *cr) {
    if(!g_svgcs.count(p) || !g_crs.count(cr)) stub_die("rendered with an unknown object");
    return SVG_CAIRO_STATUS_SUCCESS;
}

cairo_surface_t *cairo_pdf_surface_create_for_stream(cairo_write_func_t f, void *closure, double, double) {
    cairo_surface_t *s = new _cairo_surface { f, closure, 0 };
    g_surfaces.insert(s);
    stub_write(s, "%PDF\n");
    return s;
}

void cairo_pdf_surface_set_size(cairo_surface_t *s, double, double) {
    if(!g_surfaces.count(s)) stub_die("resized an unknown surface");
}

void cairo_surface_destroy(cairo_surface_t *s) {
    if(!g_surfaces.erase(s)) stub_die("destroyed an unknown surface");
    stub_write(s, "%%EOF\n");
    delete s;
}

cairo_t *cairo_create(cairo_surface_t *s) {
    if(!g_surfaces.count(s)) stub_die("context on an unknown surface");
    cairo_t *cr = new _cairo { s };
    g_crs.insert(cr);
    return cr;
}

void cairo_destroy(cairo_t *cr) {
    if(!g_crs.erase(cr)) stub_die("destroyed an unknown context");
    delete cr;
}

void cairo_translate(cairo_t *cr, double, double) { if(!g_crs.count(cr)) stub_die("unknown context"); }
void cairo_scale(cairo_t *cr, double, double) { if(!g_crs.count(cr)) stub_die("unknown context"); }

void cairo_show_page(cairo_t *cr) {
    if(!g_crs.count(cr)) stub_die("unknown context");
    stub_write(cr->surface, "page\n");
}

} // extern "C"

namespace {

struct Handle { char *data; PA_long32 len; };
struct Pic { int refs; std::vector<std::pair<u16, std::string>> formats; };

std::set<void *> g_strings;
std::set<Handle *> g_handles;
std::set<Pic *> g_pics;

u16 g_read_path, g_convert_type;
int g_transform_op = 0, g_thumb_w = 0, g_thumb_h = 0;

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "ENGINE VIOLATION: %s\n", msg);
    fflush(stderr);
    abort();
}

PA_Unistring new_string(const PA_Unichar *src, size_t len) {
    PA_Unichar *buf = (PA_Unichar *)malloc((len + 1) * sizeof(PA_Unichar));
    if(len) memcpy(buf, src, len * sizeof(PA_Unichar));
    buf[len] = 0;
    g_strings.insert(buf);
    PA_Unistring s;
    s.fLength = (PA_long32)len;
    s.fString = buf;
    s.fReserved1 = 0;
    s.fReserved2 = 0;
    return s;
}

void free_string(PA_Unistring *s) {
    if(!s->fString) return;
    if(!g_strings.erase(s->fString)) die("disposed a string the engine does not own");
    free(s->fString);
    s->fString = 0;
    s->fLength = 0;
}

Handle *new_handle(PA_long32 len) {
    Handle *h = (Handle *)malloc(sizeof(Handle));
    h->data = (char *)calloc(1, len ? len : 1);
    h->len = len;
    g_handles.insert(h);
    return h;
}

Handle *checked(PA_Handle ph) {
    Handle *h = (Handle *)ph;
    if(!g_handles.count(h)) die("used an unknown handle");
    return h;
}

void free_handle(Handle *h) {
    if(!h) return;
    checked((PA_Handle)h);
    g_handles.erase(h);
    free(h->data);
    free(h);
}

Pic *new_pic() {
    Pic *p = new Pic;
    p->refs = 1;
    g_pics.insert(p);
    return p;
}

Pic *live_pic(PA_Picture pp) {
    Pic *p = (Pic *)pp;
    if(!g_pics.count(p)) die("used a picture the engine does not own");
    return p;
}

void release_pic(PA_Picture pp) {
    if(!pp) return;
    Pic *p = live_pic(pp);
    if(--p->refs == 0) { g_pics.erase(p); delete p; }
}

void clear_var(PA_Variable *v) {
    switch(v->fType) {
        case eVK_Unistring: free_string(&v->uValue.fString); break;
        case eVK_Picture: release_pic(v->uValue.fPicture); v->uValue.fPicture = 0; break;
        case eVK_ArrayUnicode: {
            Handle *h = (Handle *)v->uValue.fArray.fData;
            if(h) {
                PA_Unistring *items = (PA_Unistring *)checked((PA_Handle)h)->data;
                for(PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) free_string(&items[i]);
                free_handle(h);
            }
            break;
        }
        case eVK_ArrayPicture: {
            Handle *h = (Handle *)v->uValue.fArray.fData;
            if(h) {
                PA_Picture *items = (PA_Picture *)checked((PA_Handle)h)->data;
                for(PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) release_pic(items[i]);
                free_handle(h);
            }
            break;
        }
        default: break;
    }
    v->fType = eVK_Undefined;
}

u16 live_text(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Unistring) die(what);
    if(!g_strings.count(v.uValue.fString.fString)) die("engine received a string it does not own");
    return u16(v.uValue.fString.fString, v.uValue.fString.fLength);
}

void live_picture_var(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Picture || !v.uValue.fPicture) die(what);
    live_pic(v.uValue.fPicture);
}

PA_long32 longint(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Longint) die(what);
    return v.uValue.fLongint;
}

/* output picture parameter: the engine releases the old value and stores a new picture */
void write_picture(PA_Variable *v) {
    if(v->fType == eVK_Picture) release_pic(v->uValue.fPicture);
    else if(v->fType != eVK_Undefined) die("picture output parameter has a non-picture value");
    v->fType = eVK_Picture;
    v->uValue.fPicture = new_pic();
}

void command(EngineBlock *eb) {
    PA_Variable **v = (PA_Variable **)eb->fPtr1;
    PA_long32 n = (PA_long32)eb->fParam2;
    switch(eb->fParam1) {
        case 678: /* READ PICTURE FILE(path; picture) */
            if(n != 2) die("READ PICTURE FILE parameter count");
            g_read_path = live_text(*v[0], "path parameter is not text");
            write_picture(v[1]);
            break;
        case 1002: /* CONVERT PICTURE(picture; type) */
            if(n != 2) die("CONVERT PICTURE parameter count");
            live_picture_var(*v[0], "CONVERT PICTURE picture");
            g_convert_type = live_text(*v[1], "type parameter is not text");
            break;
        case 988: /* TRANSFORM PICTURE(picture; operator) */
            if(n != 2) die("TRANSFORM PICTURE parameter count");
            live_picture_var(*v[0], "TRANSFORM PICTURE picture");
            g_transform_op = longint(*v[1], "operator is not longint");
            break;
        case 457: /* PICTURE PROPERTIES(picture; width; height) */
            if(n != 3) die("PICTURE PROPERTIES parameter count");
            live_picture_var(*v[0], "PICTURE PROPERTIES picture");
            v[1]->fType = eVK_Longint; v[1]->uValue.fLongint = 640;
            v[2]->fType = eVK_Longint; v[2]->uValue.fLongint = 480;
            break;
        case 679: /* CREATE THUMBNAIL(picture; thumbnail; width; height) */
            if(n != 4) die("CREATE THUMBNAIL parameter count");
            live_picture_var(*v[0], "CREATE THUMBNAIL source");
            g_thumb_w = longint(*v[2], "width is not longint");
            g_thumb_h = longint(*v[3], "height is not longint");
            write_picture(v[1]);
            break;
        default: die("unexpected command");
    }
    eb->fError = 0;
}

void engine(PA_long32 selector, void *p) {
    EngineBlock *eb = (EngineBlock *)p;
    switch(selector) {
        case EX_HANDLE_MANAGER:
            switch(eb->fParam1) {
                case 1: eb->fHandle = (PA_Handle)new_handle((PA_long32)eb->fParam2); eb->fError = 0; return;
                case 2: free_handle((Handle *)eb->fHandle); eb->fError = 0; return;
                case 3: {
                    Handle *h = checked(eb->fHandle);
                    PA_long32 n = (PA_long32)eb->fParam2;
                    h->data = (char *)realloc(h->data, n ? n : 1);
                    if(n > h->len) memset(h->data + h->len, 0, n - h->len);
                    h->len = n; eb->fError = 0; return;
                }
                case 4: eb->fParam2 = checked(eb->fHandle)->len; eb->fError = 0; return;
                case 5: eb->fParam3 = (sLONG_PTR)checked(eb->fHandle)->data; eb->fError = 0; return;
                case 6: checked(eb->fHandle); eb->fError = 0; return;
                default: die("unmodelled handle manager call");
            }
        case EX_CREATE_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_SET_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            free_string(&eb->fUniString1);
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_DISPOSE_UNISTRING: free_string(&eb->fUniString1); return;
        case EX_CLEAR_VARIABLE: clear_var((PA_Variable *)eb->fPtr1); return;
        case EX_CREATE_PICTURE: eb->fPicture = new_pic(); eb->fError = 0; return;
        case EX_DISPOSE_PICTURE: release_pic(eb->fPicture); return;
        case EX_DUPLICATE_PICTURE:
            if(eb->fParam1 == 0) live_pic(eb->fPicture)->refs++;
            else { live_pic(eb->fPicture); eb->fPicture = new_pic(); }
            return;
        case EX_GET_PICTURE_DATA: {
            Pic *pic = live_pic(eb->fPicture);
            PA_long32 i = (PA_long32)eb->fParam1;
            memset(&eb->fUniString1, 0, sizeof eb->fUniString1);
            if(i < 1 || i > (PA_long32)pic->formats.size()) { eb->fError = -1; return; }
            const std::pair<u16, std::string> &f = pic->formats[i - 1];
            /* the type string stays with the picture (borrowed) */
            eb->fUniString1.fString = (PA_Unichar *)f.first.c_str();
            eb->fUniString1.fLength = (PA_long32)f.first.size();
            if(eb->fHandle) {
                Handle *h = checked(eb->fHandle);
                h->data = (char *)realloc(h->data, f.second.size() ? f.second.size() : 1);
                memcpy(h->data, f.second.data(), f.second.size());
                h->len = (PA_long32)f.second.size();
            }
            eb->fError = 0;
            return;
        }
        case EX_CONVERT_CHARSET_TO_CHARSET: {
            const char *from = (const char *)eb->fPtr1;
            PA_long32 fromSize = (PA_long32)eb->fParam1, toSize = (PA_long32)eb->fParam3, out = 0;
            if(eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16) {
                PA_Unichar *to = (PA_Unichar *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize && (out + 1) * (PA_long32)sizeof(PA_Unichar) <= toSize; ++i)
                    to[out++] = (unsigned char)from[i];
                eb->fParam3 = out * (PA_long32)sizeof(PA_Unichar); /* byte size */
            } else if(eb->fParam2 == eVTC_UTF_16 && eb->fParam4 == eVTC_UTF_8) {
                const PA_Unichar *f = (const PA_Unichar *)from;
                char *to = (char *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize / 2 && out < toSize; ++i) to[out++] = (char)f[i];
                eb->fParam3 = out;
            } else die("unmodelled charset conversion");
            eb->fError = 0;
            return;
        }
        case EX_EXECUTE_COMMAND_BY_ID: command(eb); return;
        default: {
            char msg[64];
            snprintf(msg, sizeof msg, "unmodelled selector %d", (int)selector);
            die(msg);
        }
    }
}

void expect(bool ok, const char *what) {
    if(!ok) {
        fprintf(stderr, "FAIL: %s (live engine strings: %zu, pictures: %zu, handles: %zu, surfaces: %zu, contexts: %zu, parsers: %zu)\n",
                what, g_strings.size(), g_pics.size(), g_handles.size(), g_surfaces.size(), g_crs.size(), g_svgcs.size());
        exit(1);
    }
}

void expect_nothing_live(const char *what) {
    expect(g_strings.empty(), what);
    expect(g_pics.empty(), what);
    expect(g_handles.empty(), what);
    expect(g_surfaces.empty() && g_crs.empty() && g_svgcs.empty(), what);
}

u16 to_u16(const char *s) { u16 r; for(; *s; ++s) r.push_back((PA_Unichar)(unsigned char)*s); return r; }

/* ---- SVGL commands through PluginMain ---- */

const char *kSvg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"20\"/>";

PA_Picture svg_picture(const char *svg) {
    Pic *p = new_pic();
    p->formats.push_back({ to_u16("image/png;.png;"), std::string("\x89PNG", 4) });
    p->formats.push_back({ to_u16("com.svg;.svg;image/svg+xml"), std::string(svg) });
    return (PA_Picture)p;
}

PA_Picture png_picture() {
    Pic *p = new_pic();
    p->formats.push_back({ to_u16("image/png;.png;"), std::string("\x89PNG", 4) });
    return (PA_Picture)p;
}

struct Result { int code; std::string blob; };

std::string blob_text(PA_Handle h) {
    if(!h) return std::string();
    Handle *b = checked(h);
    return std::string(b->data, b->len);
}

/* SVGL Convert(picture; blob; width; height; scale; options) */
Result convert_one(PA_Picture picture) {
    /* an empty BLOB parameter can arrive as a NULL handle (C_BLOB.cpp) */
    PA_Handle blob = 0;
    PA_long32 w = 0, h = 0, opt = 0;
    double scale = 1;
    void *params[6] = { &picture, &blob, &w, &h, &scale, &opt };
    PA_long32 ret = -1;
    PluginBlock pb = { params, &ret, 0 };
    PluginMain(2, &pb);
    Result r = { (int)ret, blob_text(blob) };
    free_handle((Handle *)blob);
    return r;
}

/* SVGL Convert array(picture array; blob; width; height; scale; options) */
Result convert_array(PA_Variable *arr) {
    /* an empty BLOB parameter can arrive as a NULL handle (C_BLOB.cpp) */
    PA_Handle blob = 0;
    PA_long32 w = 0, h = 0, opt = 0;
    double scale = 1;
    void *params[6] = { arr, &blob, &w, &h, &scale, &opt };
    PA_long32 ret = -1;
    PluginBlock pb = { params, &ret, 0 };
    PluginMain(1, &pb);
    Result r = { (int)ret, blob_text(blob) };
    free_handle((Handle *)blob);
    return r;
}

PA_Variable picture_array(const std::vector<PA_Picture> &items) {
    PA_Variable v;
    memset(&v, 0, sizeof v);
    v.fType = eVK_ArrayPicture;
    Handle *h = new_handle((PA_long32)(items.size() * sizeof(PA_Picture)));
    memcpy(h->data, items.data(), items.size() * sizeof(PA_Picture));
    v.uValue.fArray.fNbElements = (PA_long32)items.size() - 1;
    v.uValue.fArray.fData = (PA_Handle)h;
    return v;
}

void control_convert_one_svg() {
    PA_Picture pic = svg_picture(kSvg);
    Result r = convert_one(pic);
    expect(r.code == 0, "SVGL Convert returned 0");
    expect(r.blob == "%PDF\npage\n%%EOF\n", "one-page PDF written to the BLOB");
    expect(live_pic(pic)->refs == 1, "caller picture reference untouched");
    release_pic(pic);
    expect_nothing_live("SVGL Convert leaves nothing behind");
}

void control_convert_one_not_svg() {
    PA_Picture pic = png_picture();
    Result r = convert_one(pic);
    expect(r.code == -2, "picture without SVG returns -2");
    expect(r.blob.empty(), "nothing written");
    release_pic(pic);
    expect_nothing_live("SVGL Convert leaves nothing behind");
}

void control_convert_one_parse_error() {
    PA_Picture pic = svg_picture("not svg");
    Result r = convert_one(pic);
    expect(r.code == SVG_CAIRO_STATUS_PARSE_ERROR, "parse error returned");
    expect(r.blob.empty(), "nothing written");
    release_pic(pic);
    expect_nothing_live("SVGL Convert leaves nothing behind");
}

void control_convert_array_svg() {
    /* element 0 is an empty picture, as in a 4D picture array */
    PA_Variable arr = picture_array({ PA_CreatePicture(0, 0), svg_picture(kSvg), png_picture(), svg_picture(kSvg) });
    Result r = convert_array(&arr);
    expect(r.code == 0, "SVGL Convert array returned 0");
    expect(r.blob == "%PDF\npage\npage\n%%EOF\n", "one PDF, one page per SVG");
    expect(g_pics.size() == 4, "array pictures borrowed, not released");
    PA_ClearVariable(&arr);
    expect_nothing_live("SVGL Convert array leaves nothing behind");
}

void control_convert_array_undefined() {
    PA_Variable arr;
    memset(&arr, 0, sizeof arr);
    arr.fType = eVK_Undefined;
    Result r = convert_array(&arr);
    expect(r.code == 0, "undefined array returns 0");
    expect(r.blob.empty(), "nothing written");
    expect(arr.fType == eVK_Undefined, "caller variable untouched");
    expect_nothing_live("SVGL Convert array leaves nothing behind");
}

/* Contract 1/2: ARRAY_TEXT fills the array via PA_SetStringInArray and must not dispose. */
void control_array_text_transfer() {
    {
        ARRAY_TEXT a;
        a.appendUTF16String((const PA_Unichar *)u"", 0);
        a.appendUTF16String((const PA_Unichar *)u"x", 1);
        a.appendUTF16String((const PA_Unichar *)u"yz", 2);
        PA_Variable arr = PA_CreateVariable(eVK_ArrayUnicode);
        void *params[1] = { &arr };
        a.toParamAtIndex((PackagePtr)params, 1);
        expect(arr.uValue.fArray.fNbElements == 2, "two elements");
        expect(g_strings.size() == 3, "array owns three strings");
        ARRAY_TEXT b;
        b.fromParamAtIndex((PackagePtr)params, 1);
        CUTF16String s; b.copyUTF16StringAtIndex(&s, 2);
        expect(s == CUTF16String((const PA_Unichar *)u"yz"), "borrowed read");
        PA_ClearVariable(&arr);
    }
    expect_nothing_live("array strings released with the array");
}

/* ---- C_PICTURE (built; the SVGL commands call only fromParamAtIndex/getBytesPtr/getBytesLength) ---- */

/* a picture held by C_PICTURE; the harness drops its own reference */
void with_picture(const std::function<void(C_PICTURE &)> &f) {
    {
        C_PICTURE pic;
        PA_Picture src = PA_CreatePicture(0, 0);
        pic.setPicture(src);
        PA_DisposePicture(src);
        expect(g_pics.size() == 1, "one picture held");
        f(pic);
    }
}

void defect_picture_fromfile_ownership() {
    {
        C_PICTURE pic;
        CUTF8String path((const uint8_t *)"/svgl-synthetic/does-not-exist.png");
        pic.fromFileAtPath(&path);
        expect(g_read_path == to_u16("/svgl-synthetic/does-not-exist.png"), "path delivered");
        expect(g_pics.size() == 1, "only the loaded picture is live");
    }
    expect_nothing_live("READ PICTURE FILE parameters and result released");
}

void defect_picture_setbytes_leak() {
    {
        C_PICTURE pic;
        const uint8_t bytes[] = { 1, 2, 3 };
        pic.setBytes(bytes, sizeof bytes);
        expect(g_pics.size() == 1, "only the held picture is live");
    }
    expect_nothing_live("picture created by setBytes released");
}

void defect_picture_createcopy_ownership() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createCopyPNG();
        expect(g_convert_type == to_u16(".png"), "type delivered");
        expect(p == pic.getPicture(), "retained copy returned");
        PA_DisposePicture(p);
    });
    expect_nothing_live("CONVERT PICTURE parameters released");
}

void defect_picture_grayscale_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createGrayScale();
        expect(g_transform_op == 101, "operator delivered");
        PA_DisposePicture(p);
    });
    expect_nothing_live("TRANSFORM PICTURE parameters released");
}

void defect_picture_getsize_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        unsigned int w = 0, h = 0;
        pic.getSize(&w, &h);
        expect(w == 640 && h == 480, "size delivered");
    });
    expect_nothing_live("PICTURE PROPERTIES parameters released");
}

void defect_picture_thumbnail_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture t = pic.createThumbnail(32, 24);
        expect(g_thumb_w == 32 && g_thumb_h == 24, "size delivered");
        expect(t && t != pic.getPicture() && g_pics.count((Pic *)t), "thumbnail handed to the caller");
        PA_DisposePicture(t);
    });
    expect_nothing_live("CREATE THUMBNAIL parameters released");
}

/* C_PICTURE parameter/return transfer. */
void control_picture_param_return() {
    PA_Picture in = PA_CreatePicture(0, 0);
    PA_Picture out = PA_CreatePicture(0, 0);
    PA_Picture ret = 0;
    {
        C_PICTURE pic;
        void *params[2] = { &in, &out };
        pic.fromParamAtIndex((PackagePtr)params, 1);
        pic.toParamAtIndex((PackagePtr)params, 2);
        pic.setReturn((sLONG_PTR *)&ret);
        expect(out == in && ret == in, "same picture retained");
    }
    PA_DisposePicture(in);
    PA_DisposePicture(out);
    PA_DisposePicture(ret);
    expect_nothing_live("all references balanced");
}

const std::map<std::string, std::function<void()>> kTests = {
    { "control_convert_one_svg", control_convert_one_svg },
    { "control_convert_one_not_svg", control_convert_one_not_svg },
    { "control_convert_one_parse_error", control_convert_one_parse_error },
    { "control_convert_array_svg", control_convert_array_svg },
    { "control_convert_array_undefined", control_convert_array_undefined },
    { "control_array_text_transfer", control_array_text_transfer },
    { "defect_picture_fromfile_ownership", defect_picture_fromfile_ownership },
    { "defect_picture_setbytes_leak", defect_picture_setbytes_leak },
    { "defect_picture_createcopy_ownership", defect_picture_createcopy_ownership },
    { "defect_picture_grayscale_owner_leak", defect_picture_grayscale_owner_leak },
    { "defect_picture_getsize_owner_leak", defect_picture_getsize_owner_leak },
    { "defect_picture_thumbnail_owner_leak", defect_picture_thumbnail_owner_leak },
    { "control_picture_param_return", control_picture_param_return },
};

} // namespace

int main(int argc, char **argv) {
    gCall4D = (Call4DProcPtr)engine;
    if(argc == 2 && std::string(argv[1]) == "--list") {
        for(auto &t : kTests) printf("%s\n", t.first.c_str());
        return 0;
    }
    if(argc != 2 || !kTests.count(argv[1])) { fprintf(stderr, "usage: %s --list | <test>\n", argv[0]); return 2; }
    kTests.at(argv[1])();
    printf("PASS %s\n", argv[1]);
    return 0;
}
