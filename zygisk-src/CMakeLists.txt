cmake_minimum_required(VERSION 3.18)
project(hidemount)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(RELEASE_BUILD "Strip all logging for release" OFF)

add_library(hidemount SHARED
    main.cpp
    misc.cpp
    atexit.cpp
)

target_compile_options(hidemount PRIVATE
    -fno-exceptions
    -fno-rtti
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -Os
    -ffunction-sections
    -fdata-sections
)

if(RELEASE_BUILD)
    target_compile_definitions(hidemount PRIVATE RELEASE_BUILD)
    message(STATUS "Release build: logging disabled")
else()
    message(STATUS "Debug build: logging enabled")
endif()

target_link_options(hidemount PRIVATE
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
)

target_link_libraries(hidemount
    log
)
