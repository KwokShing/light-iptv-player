# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(light_iptv_player LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "light_iptv_player")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# === Override the bundled libmpv with a build from zhongfly/mpv-winbuild ===
# media_kit_libs_windows_video ships an older (2023-09-24) libmpv-2.dll that
# can't demux MPEG-DASH. Rather than committing a ~120 MB DLL to the repo, we
# fetch a *pinned* zhongfly/mpv-winbuild release at configure time (cached under
# the build dir), verify its SHA-256, extract libmpv-2.dll, and install it
# *after* the plugin's bundled libraries above so the install step's final
# result is the DASH-capable DLL. media_kit loads "libmpv-2.dll" by name at
# runtime and only uses the standard mpv_* C API, so a drop-in replacement works
# without touching the plugin itself.
#
# To bump the version: pick a "mpv-dev-x86_64-*.7z" asset from
# https://github.com/zhongfly/mpv-winbuild/releases and update the three
# variables below (name, URL and SHA-256 from that release's sha256.txt).
set(ZHONGFLY_MPV_ARCHIVE_NAME "mpv-dev-x86_64-20260707-git-4c220ffd95.7z")
set(ZHONGFLY_MPV_URL
  "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-07-07-4c220ffd95/${ZHONGFLY_MPV_ARCHIVE_NAME}")
set(ZHONGFLY_MPV_SHA256 "3e6ae941378473f31c222800e05eac621c71a01cd3836e02b9ca8d8aa8ac93b6")

set(ZHONGFLY_MPV_ARCHIVE "${CMAKE_BINARY_DIR}/${ZHONGFLY_MPV_ARCHIVE_NAME}")
set(ZHONGFLY_MPV_SRC "${CMAKE_BINARY_DIR}/zhongfly_libmpv")
set(CUSTOM_LIBMPV "${ZHONGFLY_MPV_SRC}/libmpv-2.dll")

# Drop a stale cached archive if its hash no longer matches the pinned one.
if(EXISTS "${ZHONGFLY_MPV_ARCHIVE}")
  file(SHA256 "${ZHONGFLY_MPV_ARCHIVE}" ZHONGFLY_MPV_ARCHIVE_SHA256)
  if(NOT ZHONGFLY_MPV_ARCHIVE_SHA256 STREQUAL ZHONGFLY_MPV_SHA256)
    message(STATUS "Cached zhongfly libmpv archive is stale; removing it.")
    file(REMOVE "${ZHONGFLY_MPV_ARCHIVE}")
    file(REMOVE_RECURSE "${ZHONGFLY_MPV_SRC}")
  endif()
endif()

# Download the pinned archive if it isn't already cached.
if(NOT EXISTS "${ZHONGFLY_MPV_ARCHIVE}")
  message(STATUS "Downloading zhongfly libmpv from ${ZHONGFLY_MPV_URL} ...")
  file(DOWNLOAD "${ZHONGFLY_MPV_URL}" "${ZHONGFLY_MPV_ARCHIVE}"
    EXPECTED_HASH SHA256=${ZHONGFLY_MPV_SHA256}
    SHOW_PROGRESS
    STATUS ZHONGFLY_MPV_DL_STATUS)
  list(GET ZHONGFLY_MPV_DL_STATUS 0 ZHONGFLY_MPV_DL_CODE)
  if(NOT ZHONGFLY_MPV_DL_CODE EQUAL 0)
    list(GET ZHONGFLY_MPV_DL_STATUS 1 ZHONGFLY_MPV_DL_MSG)
    file(REMOVE "${ZHONGFLY_MPV_ARCHIVE}")
    message(FATAL_ERROR "Failed to download zhongfly libmpv "
      "(${ZHONGFLY_MPV_DL_CODE}): ${ZHONGFLY_MPV_DL_MSG}")
  endif()
endif()

# Extract libmpv-2.dll (CMake's bundled libarchive reads .7z). The DLL lives at
# the archive root, so a full extract is fine; the extra headers/import lib are
# harmless and simply ignored.
if(NOT EXISTS "${CUSTOM_LIBMPV}")
  file(MAKE_DIRECTORY "${ZHONGFLY_MPV_SRC}")
  message(STATUS "Extracting ${ZHONGFLY_MPV_ARCHIVE_NAME} ...")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xf "${ZHONGFLY_MPV_ARCHIVE}"
    WORKING_DIRECTORY "${ZHONGFLY_MPV_SRC}"
    RESULT_VARIABLE ZHONGFLY_MPV_EXTRACT_RESULT)
  if(NOT ZHONGFLY_MPV_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to extract ${ZHONGFLY_MPV_ARCHIVE_NAME}.")
  endif()
endif()

if(EXISTS "${CUSTOM_LIBMPV}")
  message(STATUS "Overriding bundled libmpv-2.dll with ${CUSTOM_LIBMPV}")
  install(FILES "${CUSTOM_LIBMPV}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  message(WARNING "zhongfly libmpv-2.dll not found after extraction; "
    "using media_kit's bundled (non-DASH) build.")
endif()
