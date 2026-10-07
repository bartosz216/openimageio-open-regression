cmake_minimum_required(VERSION 3.18)
project(oiio_open_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Always measure a Release build. A Debug measurement is worthless here.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

find_package(OpenImageIO CONFIG REQUIRED)

add_executable(oiio_open_bench oiio_open_bench.cpp)
target_link_libraries(oiio_open_bench PRIVATE OpenImageIO::OpenImageIO)
