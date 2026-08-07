cmake_minimum_required(VERSION 3.15)
project(stb_image_vendor LANGUAGES C)

# One translation unit: stb_image_impl.c selects the implementation and the
# local configuration (restricted format set, no stdio, dimension cap) ahead
# of #including the unmodified vendored header. See PATCHES.md.
add_library(stb_image_vendor STATIC stb_image_impl.c)
set_target_properties(stb_image_vendor PROPERTIES POSITION_INDEPENDENT_CODE ON)
