// oiio_open_bench.cpp
//
// Times OpenImageIO's ImageInput::open() plus reading the ImageSpec — the
// metadata path, not pixel decoding.
//
// Build:
//   cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake \
//                       -DCMAKE_BUILD_TYPE=Release
//   cmake --build build
//
// Run:
//   ./build/oiio_open_bench image.exr            # as-is
//   ./build/oiio_open_bench image.exr prewarm    # ColorConfig constructed first
//
// The difference between the two invocations is the point of the benchmark:
// with any second argument, the OpenColorIO config is constructed before the
// timer starts instead of lazily inside open().
//
// Always build Release, and discard the first run of a series as warm-up
// (page cache).

#include <OpenImageIO/color.h>
#include <OpenImageIO/imageio.h>

#include <chrono>
#include <cstdio>

int
main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <image> [prewarm]\n", argv[0]);
        return 1;
    }

    if (argc > 2)
        OIIO::ColorConfig::default_colorconfig();  // construct before timing

    auto t0 = std::chrono::steady_clock::now();
    auto in = OIIO::ImageInput::open(argv[1]);
    if (!in) {
        std::fprintf(stderr, "could not open %s: %s\n", argv[1],
                     OIIO::geterror().c_str());
        return 1;
    }
    const OIIO::ImageSpec& spec = in->spec();
    auto t1 = std::chrono::steady_clock::now();

    std::printf("open+spec: %.6f s  (%dx%d, %d ch)\n",
                std::chrono::duration<double>(t1 - t0).count(), spec.width,
                spec.height, spec.nchannels);
    return 0;
}
