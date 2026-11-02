# Node-facing target only. Never include this header in the Ark module.
set(DSH_NODE_NAPI_RENAME_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/../node/napi-rename.h"
    CACHE FILEPATH "Mainline-generated Node 24.22.1 N-API rename header")
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang" OR CMAKE_CXX_COMPILER_VERSION VERSION_LESS 23)
  message(FATAL_ERROR "Use the same Clang 23+ and static libc++ toolchain as target libnode, not SDK Clang 15")
endif()
if(NOT CMAKE_READELF)
  find_program(CMAKE_READELF NAMES llvm-readelf readelf)
endif()
if(NOT CMAKE_READELF)
  message(FATAL_ERROR "The native toolchain must provide readelf for the symbol gate")
endif()
set(DSH_NAPI_VERIFY "${CMAKE_CURRENT_SOURCE_DIR}/napi_isolation.py")
set(DSH_NAPI_INPUTS --node-headers "${NODE_SOURCE_DIR}/src"
    --rename-header "${DSH_NODE_NAPI_RENAME_HEADER}"
    --libnode "${NODE_LIBRARY_DIR}/libnode.so" --readelf "${CMAKE_READELF}")
execute_process(COMMAND "${Python3_EXECUTABLE}" "${DSH_NAPI_VERIFY}" ${DSH_NAPI_INPUTS}
                RESULT_VARIABLE DSH_NAPI_RESULT)
if(NOT DSH_NAPI_RESULT EQUAL 0)
  message(FATAL_ERROR "Node N-API rename/header/export gate failed; no unisolated fallback is available")
endif()
target_compile_options(dsh_node_runner PRIVATE -stdlib=libc++ -include "${DSH_NODE_NAPI_RENAME_HEADER}")
target_link_options(dsh_node_runner PRIVATE -stdlib=libc++ -static-libstdc++ -Wl,--exclude-libs,ALL -Wl,-z,nodelete)
add_custom_command(TARGET dsh_node_runner POST_BUILD
  COMMAND "${Python3_EXECUTABLE}" "${DSH_NAPI_VERIFY}" ${DSH_NAPI_INPUTS}
          --role runner --consumer "$<TARGET_FILE:dsh_node_runner>"
          --report "${CMAKE_CURRENT_BINARY_DIR}/napi-isolation.json"
  VERBATIM)
