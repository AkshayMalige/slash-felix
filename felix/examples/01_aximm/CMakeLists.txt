cmake_minimum_required(VERSION 3.20)
project(01_aximm LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/FelixExample.cmake)
felix_example_setup()

set(UPSTREAM "${FELIX_REPO_ROOT}/examples/01_aximm")
felix_retarget_hls(SRC "${UPSTREAM}/hls" KERNELS dma offset OUT_ROOT _HLS_ROOT)

build_hls_dir(
  TARGET      hls
  ROOT        "${_HLS_ROOT}"
  DEVICE      "${DEVICE}"
  KERNELS     dma offset
  OUT_KERNELS _KERNELS
)

set(CFG_FILE "${CMAKE_CURRENT_SOURCE_DIR}/config.cfg")
add_vbin(TARGET "aximm_hw"  PLATFORM "hw"  CFG "${CFG_FILE}" KERNELS ${_KERNELS})
add_vbin(TARGET "aximm_emu" PLATFORM "emu" CFG "${CFG_FILE}" KERNELS ${_KERNELS})
add_vbin(TARGET "aximm_ddr23_hw" PLATFORM "hw" CFG "${CMAKE_CURRENT_SOURCE_DIR}/config_ddr23.cfg" KERNELS ${_KERNELS})

add_executable(${PROJECT_NAME} "${UPSTREAM}/01_aximm.cpp")
target_link_libraries(${PROJECT_NAME} PRIVATE ${_VRT_LIBS})
