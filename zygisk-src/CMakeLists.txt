cmake_minimum_required(VERSION 3.18)
project(hidemount)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(hidemount SHARED
    main.cpp
    misc.cpp
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

target_link_options(hidemount PRIVATE
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
)

target_link_libraries(hidemount
    log
)
