# gt_link: link checks of the shell's GT quads (gt_link.cpp)
cmake_minimum_required(VERSION 3.20)
project(gt_link LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/FelixExample.cmake)
felix_example_setup()

add_executable(gt_link gt_link.cpp)
target_link_libraries(gt_link PRIVATE ${_VRT_LIBS})
