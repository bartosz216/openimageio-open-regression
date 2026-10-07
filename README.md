# Tracking down a 23x regression in OpenImageIO's image-open path

**Result:** the reported 18x slowdown when opening OpenEXR files in OpenImageIO 3.0
is not in the EXR decoder, the plugin loader, or the header parser. It is a one-time
OpenColorIO config construction that OIIO 3.0 pulled inside `ImageInput::open()`.
The EXR case had been fixed on the 3.1 branch by accident, but the same pattern was
still live on `main` for JPEG, HDR and DDS. Both reports were closed by a merged
fix two weeks after the first comment.

Upstream:
- [OpenImageIO#4629](https://github.com/AcademySoftwareFoundation/OpenImageIO/issues/4629) - the original report, filed February 2025, with no investigation until a maintainer reopened the question in September 2026
- [my analysis on #4629](https://github.com/AcademySoftwareFoundation/OpenImageIO/issues/4629#issuecomment-5785678901) - cause, reproduction, and current status of both branches
- [OpenImageIO#5490](https://github.com/AcademySoftwareFoundation/OpenImageIO/issues/5490) - new issue I filed for the general case on `main`
- [OpenImageIO#5507](https://github.com/AcademySoftwareFoundation/OpenImageIO/pull/5507) - the merged fix, which closed both
- [post-merge verification on Linux](https://github.com/AcademySoftwareFoundation/OpenImageIO/issues/5490#issuecomment-6026996292) - before/after on one dependency tree, plus OIIO's internal timers

---

## 1. The report

An engineer at NVIDIA filed #4629 against OpenImageIO, the Academy Software
Foundation's standard image I/O library for VFX. Reading a 2K HDRI got slower
between 2.5.16.0 and 3.0.0.3, and the numbers pointed at a specific place:

| | 2.5.16.0 | 3.0.0.3 |
|---|---|---|
| `t1` - open + read `ImageSpec` | 0.00086 s | 0.01555 s |
| `t2` - read pixels | 0.03874 s | 0.03294 s |

Decoding got *faster*. Opening got 18x slower. That asymmetry is the whole reason
this issue was worth picking up: it rules out the EXR decoder before you write a
line of code, and leaves `ImageInput::open()`, format probing and `ImageSpec`
construction.

The report then sat for nineteen months without anyone investigating it. In
September 2026 a maintainer (lgritz) reopened the question in the thread, asking
three things: (a) is it still an issue on a modern OIIO, a modern OCIO, and modern
OCIO configs; (b) do we care; (c) is this really an OCIO problem, or is it best
solved in OIIO.

Those questions set the target for everything below. (a) needs a measurement on
pinned versions, and (c) needs a mechanism, not a symptom.

## 2. Method

One rule, applied throughout: **change one variable per measurement, and make the
variable something you can point at.**

That rule is what made the investigation short. Every hypothesis below was killed
or confirmed by a measurement that differed from the previous one in exactly one
respect - a dependency version, one line of C++, or where a constructor ran.

Environment for everything that follows: Linux 6.18 (WSL2), gcc 13.3.0,
Intel i7-5820K, all builds release via vcpkg, no `OCIO` environment variable set
(so OpenColorIO uses its built-in config). Medians of five runs, first run
discarded as warm-up. Absolute numbers are machine-specific; the structure is not.

## 3. First hypothesis - and why it was wrong

Reading the 3.0.x and 3.1.x release notes surfaced a promising candidate:

> **#4832** - `perf(exr): Speed up OpenEXR non-core header read time`, merged
> 2025-07-24, released in 3.0.9.0.

It adds `size()`, `isStatelessRead()` and an offset-based `read()` to OIIO's
`Imf::IStream` subclass, under `#if OPENEXR_CODED_VERSION >= 30300`. OpenEXR 3.3
had changed its stream API so that subclasses lacking those methods take a heavy
penalty on header reads - upstream issues
[openexr#1915](https://github.com/AcademySoftwareFoundation/openexr/issues/1915),
[#1984](https://github.com/AcademySoftwareFoundation/openexr/issues/1984) and
[#2073](https://github.com/AcademySoftwareFoundation/openexr/issues/2073) cover
the fallout. The PR author measured ~6x on small files.

It fit the symptom exactly: header read slow, pixel decode unaffected.

It was also wrong, and one command killed it:

```console
$ ~/workspace/vcpkg-2516/vcpkg list openexr
openexr:x64-linux    3.3.1
$ ~/workspace/vcpkg-3003/vcpkg list openexr
openexr:x64-linux    3.3.1
```

Same OpenEXR on both sides of the regression. Diffing `exr_pvt.h` between the two
tags confirmed it from the other direction: `OpenEXRInputStream` is functionally
identical in `v2.5.16.0` and `v3.0.0.3` - `read()`, `tellg()`, `seekg()`, `clear()`,
and nothing else. Against the same OpenEXR, both should be equally slow. One was
not.

**This is the most useful step in the whole investigation.** A plausible,
well-evidenced, upstream-corroborated hypothesis was eliminated in under a minute,
before any build. The alternative - bisecting OIIO between the two tags - would
have burned days looking for a commit that does not exist.

## 4. The actual cause

With the dependency explanation gone, the difference had to be OIIO source. It is,
and it is one line. In `src/openexr.imageio/exrinput.cpp`:

```cpp
// v2.5.16.0
spec.attribute("oiio:ColorSpace", "Linear");

// v3.0.0.3
if (pvt::channels_are_rgb(spec))
    spec.set_colorspace("lin_rec709");
```

The first writes a string into an attribute map. The second goes here:

```cpp
// src/libOpenImageIO/formatspec.cpp
void ImageSpec::set_colorspace(string_view colorspace)
{
    ColorConfig::default_colorconfig().set_colorspace(*this, colorspace);
}

// src/libOpenImageIO/color_ocio.cpp
const ColorConfig& ColorConfig::default_colorconfig()
{
    static ColorConfig config;   // constructed on first call
    return config;
}
```

`channels_are_rgb()` is true for any RGB image, so from 3.0 onward, reading an EXR
header constructs the entire OpenColorIO config - in a code path whose caller asked
only for metadata and may never touch color at all. OIIO 3.0 also made OpenColorIO
a *required* dependency (#4367, minimum raised from 1.1 to 2.2), so the config is
always there to be built.

## 5. Proving it

The decisive measurement needs no rebuild of OIIO and no second version. Inside a
single 3.0.0.3 build, move the constructor out of the timed region:

```cpp
OIIO::ColorConfig::default_colorconfig();   // one added line
auto t0 = std::chrono::steady_clock::now();
auto in = OIIO::ImageInput::open(argv[1]);
const OIIO::ImageSpec& spec = in->spec();
auto t1 = std::chrono::steady_clock::now();
```

| build | OpenColorIO | `open` + `ImageSpec` | range |
|---|---|---|---|
| 2.5.16.0 | not linked | 0.00051 s | 0.00046 - 0.00100 |
| 3.0.0.3 | 2.2.1 | 0.01057 s | 0.01035 - 0.01113 |
| **3.0.0.3, config constructed before the timer** | 2.2.1 | **0.00045 s** | - |
| 3.1.14.0 | 2.5.2 | 0.00070 s | 0.00067 - 0.00076 |

**23.5x inside one build, one variable, no rebuild.** The open path itself never
regressed - with the config pre-built, 3.0.0.3 is marginally faster than 2.5.16.0.

The 2.5.16.0 row is deliberately *not* the headline. That vcpkg tree does not link
OpenColorIO at all, since it was optional before 3.0, so it is not a like-for-like
baseline. Leading with it would have invited the correct objection that this is a
packaging difference. The within-build comparison is immune to that.

## 6. Why 3.1 looks fixed, and why that is misleading

3.1.14.0 measures fine - but not because anyone fixed this. In 3.1.4.0,
[#4840](https://github.com/AcademySoftwareFoundation/OpenImageIO/pull/4840)
("Don't assume unlabeled OpenEXR files are `lin_rec709`") removed the heuristic for
**color-correctness** reasons. Today `set_colorspace()` runs only for files
carrying `acesImageContainerFlag` or `colorInteropID`:

```cpp
// v3.1.14.0
if (spec.get_int_attribute("acesImageContainerFlag") == 1) {
    spec.set_colorspace("lin_ap0_scene");
} else if (auto c = spec.find_attribute("colorInteropID", TypeString)) {
    spec.set_colorspace(c->get_ustring());
}
```

An ordinary unlabeled EXR never touches OCIO. The performance issue was closed as a
side effect, by a change that never mentions it.

Two consequences follow, and both are reportable:

**The 3.0 branch still has it.** `v3.0.21.0` (August 2026),
`src/openexr.imageio/exrinput.cpp` lines 397-398 - unchanged.

**The pattern is alive on `main` for other formats.** Several readers still call
`set_colorspace()` unconditionally in `open()`:

```cpp
// src/jpeg.imageio/jpeginput.cpp  - every JPEG
m_spec.set_colorspace("srgb_rec709_scene");

// src/hdr.imageio/hdrinput.cpp
m_spec.set_colorspace("lin_rec709_scene");

// src/dds.imageio/ddsinput.cpp
m_spec.set_colorspace(colorspace);
```

Measured on 3.1.14.0 with a JPEG:

| | median | range |
|---|---|---|
| as-is | 0.0208 s | 0.0203 - 0.0217 |
| config constructed before the timer | 0.00049 s | 0.00045 - 0.00055 |

And the cost is growing with OpenColorIO: ~10 ms with OCIO 2.2.1, ~20 ms with
OCIO 2.5.2, both on the built-in config.

## 7. Why it looks avoidable

`ColorConfig::set_colorspace()` needs the config for exactly one decision:

```cpp
if (!equivalent(colorspace, "sRGB"))
    spec.erase_attribute("Exif:ColorSpace");
```

In `JpgInput::open()`, `set_colorspace()` runs at ~line 329 and `decode_exif()` at
~line 352. At that moment `Exif:ColorSpace`, `tiff:ColorSpace`,
`tiff:PhotometricInterpretation` and `oiio:Gamma` are all absent from the
freshly-built spec. Every erase is a no-op; the `equivalent()` result cannot change
the outcome. The full config initialization buys nothing.

The codebase already does this the cheap way in places - `png_pvt.h` makes the same
kind of assumption with a plain `spec.attribute("oiio:ColorSpace", ...)`, and
`tiffinput.cpp` sidesteps `set_colorspace()` with an explicit comment, though for an
unrelated reason. #4433 did the equivalent for `oiiotool` startup.

## 8. A claim that did not survive better instruments

An early comparison suggested 3.1.14.0 was ~1.7x slower than 2.5.16.0 on the open
path, hinting at a residual regression. Re-measuring with a purpose-built
reproducer on `steady_clock` instead of the original `system_clock` harness brought
it to 1.4x, or **0.19 ms absolute** - with the two builds also differing in OpenEXR
version (3.3.1 vs 3.4.15) and in whether OpenColorIO is linked at all.

That is noise, not a finding, and it was dropped from both reports rather than
shipped as a weak claim. Worth recording: the same discipline that killed the
OpenEXR hypothesis also killed one of my own.

## 9. Reproducer

```cpp
// oiio_open_bench.cpp
//   c++ -O2 -std=c++17 oiio_open_bench.cpp -lOpenImageIO -o oiio_open_bench
//   ./oiio_open_bench image.jpg            # as-is
//   ./oiio_open_bench image.jpg prewarm    # ColorConfig constructed first
#include <OpenImageIO/color.h>
#include <OpenImageIO/imageio.h>
#include <chrono>
#include <cstdio>

int main(int argc, char** argv)
{
    if (argc < 2) { std::fprintf(stderr, "usage: %s <image> [prewarm]\n", argv[0]); return 1; }
    if (argc > 2)
        OIIO::ColorConfig::default_colorconfig();   // construct before timing

    auto t0 = std::chrono::steady_clock::now();
    auto in = OIIO::ImageInput::open(argv[1]);
    if (!in) { std::fprintf(stderr, "could not open %s\n", argv[1]); return 1; }
    const OIIO::ImageSpec& spec = in->spec();
    auto t1 = std::chrono::steady_clock::now();

    std::printf("open+spec: %.6f s  (%dx%d, %d ch)\n",
                std::chrono::duration<double>(t1 - t0).count(),
                spec.width, spec.height, spec.nchannels);
    return 0;
}
```

Pinning a specific OIIO version without disturbing an existing toolchain is done
with a separate vcpkg clone per version:

```bash
git clone https://github.com/microsoft/vcpkg vcpkg-3003
cd vcpkg-3003 && git checkout 6e1219d && ./bootstrap-vcpkg.sh
./vcpkg install openimageio      # 3.0.0.3
```

Each clone keeps its own `installed/` tree, so versions never mix. `6e1219d` is the
vcpkg commit that bumped the port to 3.0.0.3; its parent gives 2.5.16.0.

## 10. What the method bought

| step | cost | outcome |
|---|---|---|
| Read 3.0.x / 3.1.x release notes | ~30 min | produced the OpenEXR hypothesis and, separately, #4840 |
| `vcpkg list openexr` on both trees | seconds | killed the OpenEXR hypothesis, and with it a multi-day bisect |
| Diff `exrinput.cpp` across four tags | ~20 min | located the one-line cause |
| One added line in the benchmark | minutes | proved the cause inside a single build |

No `git bisect`, no building OIIO from source, no profiler. The whole path from
"open regression, cause unknown" to "this line, this mechanism, here is the proof"
ran on release notes, `git`-hosted source at four tags, and one line of C++.

The generalizable part is the order: **eliminate the dependency explanation before
you bisect the application.** A bisect assumes the answer lies between your two
commits. Checking that assumption costs one command; skipping it costs days.

## 11. Outcome

**Fixed.** [OpenImageIO#5507](https://github.com/AcademySoftwareFoundation/OpenImageIO/pull/5507) -
"fix(color): load the color config on first use, not on construction" - was
merged into `main`, and lgritz closed #5490 as completed by it. #4629, which the
PR also referenced, is closed as well. Two weeks from the first comment to a merged fix, on a report that had sat
for nineteen months.

### What landed

Two changes, and together they remove the cost at both levels.

**The config is no longer loaded when a `ColorConfig` is constructed.** It is loaded
on first real use, once per instance:

```cpp
// src/libOpenImageIO/color_ocio.cpp, ColorConfig::Impl
// Load the config on first use: it is expensive, and many operations,
// such as reading images, never need it.
bool init_once()
{
    std::call_once(m_init_flag, [this] {
        OIIO::pvt::LoggedTimer logtime("ColorConfig::init");
        m_init_ok = init(m_init_filename);
    });
    return m_init_ok;
}
```

`default_colorconfig()` still builds its function-local static - but that is now a
cheap shell rather than a parsed OCIO config.

**`set_colorspace()` consults the config only when the answer can matter** - the
gate proposed in section 7, in this form:

```cpp
// src/libOpenImageIO/color_ocio.cpp, ColorConfig::set_colorspace
// Only an existing "Exif:ColorSpace" needs the config, to judge sRGB.
if (spec.find_attribute("Exif:ColorSpace")
    && colorspace != "srgb_rec709_scene"
    && !equivalent(colorspace, "srgb_rec709_scene"))
    spec.erase_attribute("Exif:ColorSpace");
```

The cheap checks run first; `equivalent()`, the only call that needs a loaded
config, runs last and only when both cheap checks pass.

**The readers did not need to change.** `jpeginput.cpp` still calls
`m_spec.set_colorspace("srgb_rec709_scene")` at the same line, and `hdrinput.cpp`
still calls `set_colorspace("lin_rec709_scene")`. For JPEG, the attribute is not on
the spec yet at that point and the name is the literal sRGB one; for HDR the
attribute is never there. Neither reaches `equivalent()`. That is the argument made
in the #5490 thread before the merge: the narrow gate alone covers the reported
formats, without touching a single reader.

### Independent verification after the merge

Every measurement in the upstream threads had been taken on Apple silicon. After the
merge I built OpenImageIO from source on Linux and measured both sides against one
dependency tree: the PR's merge-base (`5d186c29e`) against `main` with the fix
(`f05656438`). Linux x86-64 under WSL2, gcc 13.3, OpenColorIO 2.5.2; first
`ImageInput::open()` + `spec()` in a fresh process; before and after runs
alternating, one warm-up pair discarded, ten measured pairs
([`bench_compare.sh`](bench_compare.sh)):

| ms, median (range) | before | after |
|---|---|---|
| JPEG | 21.267 (20.976 - 21.710) | 0.671 (0.625 - 0.702) |
| EXR, untagged - control | 0.837 (0.790 - 0.961) | 0.839 (0.781 - 0.929) |

The untagged EXR is the control. It never touched the config, even before the fix,
and it does not move. The JPEG open loses 20.6 ms.

OpenImageIO's own timers confirm it without a stopwatch. With
`OPENIMAGEIO_LOG_TIMES=2`, a JPEG open on the fixed build logs no `ColorConfig::init`
at all. An `oiiotool --colorconvert` run, which does need the config, logs it at
21.46 ms per load - the same cost that disappeared from the open path, measured
independently.

Posted upstream as a
[follow-up on #5490](https://github.com/AcademySoftwareFoundation/OpenImageIO/issues/5490#issuecomment-6026996292).

### How the discussion got there

Both reports drew a response within a day.

On #4629, **zachlewis** - the project's OpenColorIO maintainer - reproduced the
mechanism on current `main` (`8004015ac`, OCIO 2.5.1, macOS arm64), timing the
first `open()` + `spec()` in a fresh process across 40 paired, interleaved
repetitions:

| 1920x1080 half EXR | current `main` | with his change |
|---|---|---|
| with `colorInteropID` | 11.86 ms | 0.76 ms |
| untagged, non-ACES | 0.71 ms | 0.72 ms |

That confirms the reading of the source in section 6 - an untagged EXR no longer
touches the config on `main` - and sharpens it: the cost survives on *tagged*
files, which includes every EXR OpenImageIO itself writes when it knows the color
space. He answered (c) with "best fixed in OpenImageIO", and has a PR in
preparation that defers config resolution until a conversion actually needs it,
verified by byte-identical attribute dumps across 4,460 test files and 1,716 EXRs
read through the C API.

On #5490, **lgritz** proposed the narrow fix directly:

```cpp
if (colorspace != "srgb_rec709_scene" && spec.has_attribute("Exif:ColorSpace"))
    if (!default_colorconfig().equivalent(colorspace, "srgb_rec709_scene"))
        spec.erase_attribute("Exif:ColorSpace");
```

which is the change proposed in section 7 above, arrived at independently: gate the
config construction on the one attribute whose presence makes the config's answer
matter. The subsequent exchange settled the direction at both levels - readers may
set `oiio:ColorSpace` directly where the reader builds the whole spec itself, and,
in lgritz's words, `ImageSpec::set_colorspace` should not instantiate a
`ColorConfig`, even the default one, except where one is needed.

One correction came back the other way. zachlewis pointed out that setting
`oiio:ColorSpace` directly is only safe for a small reserved set of names -
`srgb_rec709_scene`, `srgb_rec709_display`, `lin_rec709_scene`, `lin_ap1_scene`,
`scene_linear` - because those are the only ones `ColorConfig` resolves
definitionally. The #5490 report had cited `png_pvt.h` setting the attribute
directly as evidence that the cheap path was generally available; it is not. The
three readers in the report all happen to fall inside that set, which he confirmed:
"As long as we conform to that 'safe set' of reserved interop IDs and it helps
bypass initializing the ColorConfig too early, I'm all for it."

Question (c) - OCIO or OIIO? - ended up answered "both". The fix landed in OIIO,
and brechtvl pointed out in the thread that OpenColorIO's own config loading has
room for optimization too
([OpenColorIO#2357](https://github.com/AcademySoftwareFoundation/OpenColorIO/pull/2357)).

### What the reports contributed

Not the patch - zachlewis wrote it. What they contributed is what made the patch
straightforward to write: a mechanism stated at the line level instead of a symptom,
a proof inside a single build that the config construction was the whole cost,
evidence that the problem reached beyond EXR to JPEG, HDR and DDS on current `main`,
and a proposed gate that lgritz arrived at independently and that shipped in
essentially that form. After the merge, the same reproducer supplied the only
measurements of the fix outside Apple silicon.
