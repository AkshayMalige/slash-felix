cmake_minimum_required(VERSION 3.20)
project(ddr_capacity LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/FelixExample.cmake)
felix_example_setup()

add_executable(ddr_capacity ddr_capacity.cpp)
target_link_libraries(ddr_capacity PRIVATE ${_VRT_LIBS})
