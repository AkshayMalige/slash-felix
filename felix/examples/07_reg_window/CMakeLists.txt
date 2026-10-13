cmake_minimum_required(VERSION 3.20)
project(07_reg_window LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/FelixExample.cmake)
felix_example_setup()

build_hls_dir(
  TARGET      hls
  ROOT        "${CMAKE_CURRENT_SOURCE_DIR}/hls"
  DEVICE      "${DEVICE}"
  KERNELS     reg_window
  OUT_KERNELS _KERNELS
)

set(CFG_FILE "${CMAKE_CURRENT_SOURCE_DIR}/config.cfg")
add_vbin(TARGET "reg_window_hw" PLATFORM "hw" CFG "${CFG_FILE}" KERNELS ${_KERNELS})

add_executable(${PROJECT_NAME} 07_reg_window.cpp)
target_link_libraries(${PROJECT_NAME} PRIVATE ${_VRT_LIBS})
