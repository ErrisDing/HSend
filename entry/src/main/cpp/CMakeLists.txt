cmake_minimum_required(VERSION 3.16)
project(hsend_tls LANGUAGES C CXX)

include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
FetchContent_Declare(mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2
    URL_HASH SHA256=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b)
FetchContent_MakeAvailable(mbedtls)

add_library(hsend_tls SHARED tls_stream.cpp)
target_compile_features(hsend_tls PRIVATE cxx_std_17)
target_link_libraries(hsend_tls PRIVATE mbedtls libace_napi.z.so libuv.so)
