cmake_minimum_required(VERSION 3.20)
project(00_axilite LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/FelixExample.cmake)
felix_example_setup()

set(UPSTREAM "${FELIX_REPO_ROOT}/examples/00_axilite")
felix_retarget_hls(SRC "${UPSTREAM}/hls" KERNELS increment accumulate OUT_ROOT _HLS_ROOT)

build_hls_dir(
  TARGET      hls
  ROOT        "${_HLS_ROOT}"
  DEVICE      "${DEVICE}"
  KERNELS     increment accumulate
  OUT_KERNELS _KERNELS
)

set(CFG_FILE "${CMAKE_CURRENT_SOURCE_DIR}/config.cfg")
add_vbin(TARGET "axilite_hw"  PLATFORM "hw"  CFG "${CFG_FILE}" KERNELS ${_KERNELS})
add_vbin(TARGET "axilite_emu" PLATFORM "emu" CFG "${CFG_FILE}" KERNELS ${_KERNELS})

add_executable(${PROJECT_NAME} "${UPSTREAM}/00_axilite.cpp")
target_link_libraries(${PROJECT_NAME} PRIVATE ${_VRT_LIBS})

add_executable(no_program_test no_program_test.cpp)
target_link_libraries(no_program_test PRIVATE ${_VRT_LIBS})
