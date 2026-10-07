# Raw measurement logs

Unedited program output from every run used in the README and in the upstream
reports. Nothing is averaged or filtered here; medians in the README are derived
from these numbers, discarding the first run of a series as warm-up.
The only edit: absolute paths under the home directory are shortened to `~`.

## Environment

| | |
|---|---|
| OS | Linux 6.18.33.2-microsoft-standard-WSL2 x86_64 (WSL2 on Windows) |
| Compiler | gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| CPU | Intel Core i7-5820K @ 3.30 GHz |
| Build type | Release, via vcpkg toolchain |
| `OCIO` env var | not set - OpenColorIO uses its built-in config |

### Pinned builds

| directory | vcpkg clone | OpenImageIO | OpenEXR | OpenColorIO |
|---|---|---|---|---|
| `build-2516` | `vcpkg-2516` @ `6e1219d^` | 2.5.16.0 | 3.3.1 | not installed |
| `build-3003` | `vcpkg-3003` @ `6e1219d` | 3.0.0.3 | 3.3.1 | 2.2.1#3 |
| `build` | `vcpkg` @ current | 3.1.14.0#1 | 3.4.15 | 2.5.2 |

OpenColorIO was an optional dependency before OIIO 3.0 and the 2.5.16.0 tree does
not link it at all. That is why the 2.5.16.0 row is context in the README rather
than the headline comparison.

### Test files

- EXR: `hdrihaven_teufelsberg_inner_2k.exr`, 2048x1024, 3 channels -
  from the reproducer attached to OpenImageIO#4629, originally
  `NVIDIA/MDL-SDK/examples/mdl_sdk/dxr/content/hdri/`
- JPEG: `960px-Varso_Tower_Warsaw_22(cropped).jpg`, 960x639, 3 channels -
  Wikimedia Commons

Neither file is committed to this repository.

---

## A. Final reproducer - `oiio_open_bench`, EXR

Times `ImageInput::open()` + `spec()` only. `steady_clock`.

### A.1 - 2.5.16.0 (`build-2516`)

```
open+spec: 0.001645 s  (2048x1024, 3 ch)      <- warm-up, cold page cache
open+spec: 0.000460 s  (2048x1024, 3 ch)
open+spec: 0.000489 s  (2048x1024, 3 ch)
open+spec: 0.000530 s  (2048x1024, 3 ch)
open+spec: 0.000997 s  (2048x1024, 3 ch)
```

Median of the four post-warm-up runs: **0.00051 s**, range 0.00046 - 0.00100.
The 0.000997 outlier is left in; sub-millisecond timings jitter on this box.

### A.2 - 3.0.0.3 (`build-3003`)

```
open+spec: 0.010395 s  (2048x1024, 3 ch)
open+spec: 0.010352 s  (2048x1024, 3 ch)
open+spec: 0.011126 s  (2048x1024, 3 ch)
open+spec: 0.010504 s  (2048x1024, 3 ch)
open+spec: 0.010644 s  (2048x1024, 3 ch)
```

Median discarding the first: **0.01057 s**, range 0.01035 - 0.01113.
No cold-cache outlier - the file was already resident from series A.1.

### A.3 - 3.1.14.0 (`build`)

```
open+spec: 0.000732 s  (2048x1024, 3 ch)
open+spec: 0.000728 s  (2048x1024, 3 ch)
open+spec: 0.000678 s  (2048x1024, 3 ch)
open+spec: 0.000702 s  (2048x1024, 3 ch)
open+spec: 0.000669 s  (2048x1024, 3 ch)
open+spec: 0.000757 s  (2048x1024, 3 ch)
```

Median discarding the first: **0.00070 s**, range 0.00067 - 0.00076.

---

## B. The isolating experiment

Earlier harness, which reported `t1` (open + `ImageSpec`) and `t2` (pixel read)
separately. Only `t1` is relevant.

### B.1 - 3.0.0.3 with `OIIO::ColorConfig::default_colorconfig();` before the timer

Same binary, same dependencies, one added line. OIIO not rebuilt.

```
t1:  0.000485638   t2:  0.0402972   sum: 0.0407828
t1:  0.000454419   t2:  0.0285975   sum: 0.0290519
t1:  0.000507156   t2:  0.0306292   sum: 0.0311364
t1:  0.000427819   t2:  0.0335421   sum: 0.0339699
t1:  0.000444595   t2:  0.0278577   sum: 0.0283023
```

`t1` median **0.00045 s** against 0.01057 s without the line: **23.5x**,
a 10.1 ms fixed difference.

### B.2 - 3.1.14.0, JPEG, without the pre-warm line

```
t1:  0.0217339   t2:  0.0289679   sum: 0.0507019
t1:  0.0206550   t2:  0.0284205   sum: 0.0490755
t1:  0.0207694   t2:  0.0277562   sum: 0.0485256
t1:  0.0211920   t2:  0.0294432   sum: 0.0506352
t1:  0.0203338   t2:  0.0283216   sum: 0.0486554
```

Median **0.0208 s**, range 0.0203 - 0.0217.

### B.3 - 3.1.14.0, JPEG, with the pre-warm line

```
t1:  0.000499092   t2:  0.0286795   sum: 0.0291786
t1:  0.000453200   t2:  0.0269947   sum: 0.0274479
t1:  0.000489323   t2:  0.0272103   sum: 0.0276996
t1:  0.000548972   t2:  0.0280306   sum: 0.0285796
t1:  0.000490064   t2:  0.0281949   sum: 0.0286849
```

Median **0.00049 s**, range 0.00045 - 0.00055. Spread under 10% in both B.2 and
B.3, so this is not a cold-cache artifact.

Comparing B.1 (OCIO 2.2.1, ~10.1 ms) with B.2/B.3 (OCIO 2.5.2, ~20.3 ms): the
config construction roughly doubled in cost between those OpenColorIO versions.

---

## C. Superseded series

Kept for provenance. These used the reproducer from OpenImageIO#4629, which
timed with `system_clock`.

### C.1 - 3.1.14.0, EXR, original harness

```
t1:  0.00197832    t2:  0.0321184   sum: 0.0340967      <- cold page cache
t1:  0.000851318   t2:  0.0322206   sum: 0.0330719
t1:  0.000884256   t2:  0.0305475   sum: 0.0314317
t1:  0.00103099    t2:  0.0315056   sum: 0.0325365
t1:  0.000945057   t2:  0.0330526   sum: 0.0339977
t1:  0.00086614    t2:  0.0314231   sum: 0.0322893
```

Median **0.00088 s**. Against the 2.5.16.0 baseline this looked like a residual
~1.7x regression on the open path. Re-measuring with `oiio_open_bench` on
`steady_clock` (series A.3) gave 0.00070 s, i.e. 1.4x, or **0.19 ms absolute** -
between builds that also differ in OpenEXR version and in whether OpenColorIO is
linked at all. That is noise, and the claim was dropped rather than reported.

---

## D. Post-merge verification - OpenImageIO built from source

After [#5507](https://github.com/AcademySoftwareFoundation/OpenImageIO/pull/5507)
was merged. Both sides are built from source against the same, current vcpkg tree,
so the only difference between them is the OpenImageIO source.

| | OpenImageIO source | OpenColorIO |
|---|---|---|
| before | merge-base of #5507, `5d186c29e` | 2.5.2 |
| after | `main` with #5507 merged, `f05656438` | 2.5.2 |

Measured with [`bench_compare.sh`](../bench_compare.sh): before and after runs
alternate, one warm-up pair is discarded, ten pairs are measured. The script
prints summary statistics only, so per-run values were not retained for this
series. The `->` lines are the `libOpenImageIO` each binary actually loaded,
checked by the script before it measures.

### D.1 - JPEG

```
$ ./bench_compare.sh varso.jpg
~/workspace/oiio-bench/build-base/oiio_open_bench
    -> ~/workspace/oiio-inst-base/lib/libOpenImageIO.so.3.3.0
~/workspace/oiio-bench/build-pr/oiio_open_bench
    -> ~/workspace/oiio-inst-pr/lib/libOpenImageIO.so.3.3.0

image:   varso.jpg
before:  median  21.267 ms   range  20.976 -  21.710 ms   (n=10)
after:   median   0.671 ms   range   0.625 -   0.702 ms   (n=10)
```

### D.2 - EXR, untagged (control)

```
$ ./bench_compare.sh teufelsberg.exr
~/workspace/oiio-bench/build-base/oiio_open_bench
    -> ~/workspace/oiio-inst-base/lib/libOpenImageIO.so.3.3.0
~/workspace/oiio-bench/build-pr/oiio_open_bench
    -> ~/workspace/oiio-inst-pr/lib/libOpenImageIO.so.3.3.0

image:   teufelsberg.exr
before:  median   0.837 ms   range   0.790 -   0.961 ms   (n=10)
after:   median   0.839 ms   range   0.781 -   0.929 ms   (n=10)
```

### D.3 - OpenImageIO's internal timers

With `OPENIMAGEIO_LOG_TIMES=2`, OIIO prints its timing report at exit.

Fixed build, plain JPEG open - the config is never loaded:

```
$ OPENIMAGEIO_LOG_TIMES=2 ./build-pr/oiio_open_bench varso.jpg 2>&1 | grep -i colorconfig \
  || echo "ColorConfig nie wczytany"
ColorConfig nie wczytany
```

Positive control on the same build - a conversion that must load it:

```
$ OPENIMAGEIO_LOG_TIMES=2 ~/workspace/oiio-inst-pr/bin/oiiotool varso.jpg \
  --colorconvert srgb_rec709_scene lin_rec709_scene -o /tmp/cc.exr 2>&1 | grep -i colorconfig
ColorConfig::init             2   0.043s  (avg  21.46ms)
```

21.46 ms per config load, against 20.6 ms removed from the JPEG open in D.1.

---

## Reported figures, for comparison

From OpenImageIO#4629, measured by the original reporter on unknown hardware as
averages of 100 runs:

| | 2.5.16.0 | 3.0.0.3 |
|---|---|---|
| `t1` | 0.00086496 s | 0.0155549 s |
| `t2` | 0.0387352 s | 0.0329414 s |

Their ratio on `t1` is 18x; the ratio reproduced here is 20.7x. Absolute values
are not comparable across machines and were not expected to match.
