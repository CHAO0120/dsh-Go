cmake_minimum_required(VERSION 3.16)
project(dsh_ohos_node_runner LANGUAGES CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  message(FATAL_ERROR "Build the product runner with the OpenHarmony native SDK toolchain")
endif()
set(NODE_SOURCE_DIR "" CACHE PATH "Node source matching ../node-version.json")
set(NODE_LIBRARY_DIR "" CACHE PATH "O7b output containing libnode.so")
if(NOT EXISTS "${NODE_SOURCE_DIR}/src/node.h" OR NOT EXISTS "${NODE_LIBRARY_DIR}/libnode.so")
  message(FATAL_ERROR "Provide the pinned Node source and target shared-library output")
endif()

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(Threads REQUIRED)
find_path(DSH_DEVICEINFO_INCLUDE_DIR NAMES deviceinfo.h)
find_library(DSH_DEVICEINFO_LIBRARY NAMES deviceinfo_ndk.z)
if(NOT DSH_DEVICEINFO_INCLUDE_DIR OR NOT DSH_DEVICEINFO_LIBRARY)
  message(FATAL_ERROR "The OpenHarmony SDK must provide deviceinfo.h and libdeviceinfo_ndk.z.so (API 10+)")
endif()
set(DSH_NODE_VERSION_PIN "${CMAKE_CURRENT_SOURCE_DIR}/../node-version.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${DSH_NODE_VERSION_PIN}" "${CMAKE_CURRENT_SOURCE_DIR}/generate-node-version.py")
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/generate-node-version.py"
          --pin "${DSH_NODE_VERSION_PIN}" --output "${CMAKE_CURRENT_BINARY_DIR}/dsh_node_version.h"
  RESULT_VARIABLE DSH_NODE_VERSION_RESULT)
if(NOT DSH_NODE_VERSION_RESULT EQUAL 0)
  message(FATAL_ERROR "Invalid OHOS Node version pin")
endif()

add_library(dsh_node_runner SHARED node_runner.cpp publication_binding.cc)
target_compile_features(dsh_node_runner PRIVATE cxx_std_20)
target_compile_definitions(dsh_node_runner PRIVATE NAPI_VERSION=8)
target_compile_options(dsh_node_runner PRIVATE -fvisibility=hidden)
target_include_directories(dsh_node_runner PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}"
  "${DSH_DEVICEINFO_INCLUDE_DIR}"
  "${NODE_SOURCE_DIR}/src" "${NODE_SOURCE_DIR}/deps/v8/include" "${NODE_SOURCE_DIR}/deps/uv/include")
target_link_libraries(dsh_node_runner PRIVATE "${NODE_LIBRARY_DIR}/libnode.so" "${DSH_DEVICEINFO_LIBRARY}" Threads::Threads)
target_link_options(dsh_node_runner PRIVATE -Wl,-z,defs)
include("${CMAKE_CURRENT_SOURCE_DIR}/napi-isolation.cmake")
