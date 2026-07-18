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
# resolve the LATEST zhongfly/mpv-winbuild release at configure time via the
# GitHub API, download its "mpv-dev-x86_64-*.7z" asset (SHA-256 verified using
# the digest the API reports), extract libmpv-2.dll, and install it *after* the
# plugin's bundled libraries above so the install step's final result is the
# DASH-capable DLL. media_kit loads "libmpv-2.dll" by name at runtime and only
# uses the standard mpv_* C API, so a drop-in replacement works without touching
# the plugin itself.
#
# Trade-offs of tracking "latest":
#   * Needs network + GitHub API at CMake *configure* time (i.e. on a fresh /
#     cleaned build or whenever CMake re-runs -- not on every incremental build).
#     Unauthenticated GitHub API allows 60 requests/hour/IP.
#   * Builds are no longer perfectly reproducible. To pin a specific release,
#     configure with -DLIBMPV_RELEASE_TAG=<tag> (e.g. 2026-07-07-4c220ffd95).
#   * On any failure (offline, rate-limited, ...) we reuse a previously cached
#     DLL, and only as a last resort fall back to media_kit's bundled build, so
#     the build never hard-fails just because GitHub is unreachable.

set(ZHONGFLY_MPV_SRC "${CMAKE_BINARY_DIR}/zhongfly_libmpv")
set(CUSTOM_LIBMPV "${ZHONGFLY_MPV_SRC}/libmpv-2.dll")
set(ZHONGFLY_MPV_STAMP "${ZHONGFLY_MPV_SRC}/.resolved-asset")

# Optional pin: -DLIBMPV_RELEASE_TAG=<tag> targets that release instead of latest.
if(DEFINED LIBMPV_RELEASE_TAG AND NOT LIBMPV_RELEASE_TAG STREQUAL "")
  set(ZHONGFLY_MPV_API_URL
    "https://api.github.com/repos/zhongfly/mpv-winbuild/releases/tags/${LIBMPV_RELEASE_TAG}")
else()
  set(ZHONGFLY_MPV_API_URL
    "https://api.github.com/repos/zhongfly/mpv-winbuild/releases/latest")
endif()

set(ZHONGFLY_MPV_ASSET_NAME "")
set(ZHONGFLY_MPV_ASSET_URL "")
set(ZHONGFLY_MPV_ASSET_SHA256 "")

# --- Resolve the newest mpv-dev-x86_64 (non-v3, non-lgpl) asset via GitHub API.
if(NOT CMAKE_VERSION VERSION_LESS "3.19")
  set(ZHONGFLY_MPV_API_JSON "${CMAKE_BINARY_DIR}/zhongfly_release.json")
  message(STATUS "Resolving zhongfly libmpv release from ${ZHONGFLY_MPV_API_URL} ...")
  file(DOWNLOAD "${ZHONGFLY_MPV_API_URL}" "${ZHONGFLY_MPV_API_JSON}"
    HTTPHEADER "Accept: application/vnd.github+json"
    HTTPHEADER "X-GitHub-Api-Version: 2022-11-28"
    STATUS ZHONGFLY_MPV_API_STATUS)
  list(GET ZHONGFLY_MPV_API_STATUS 0 ZHONGFLY_MPV_API_CODE)
  if(ZHONGFLY_MPV_API_CODE EQUAL 0)
    file(READ "${ZHONGFLY_MPV_API_JSON}" ZHONGFLY_MPV_JSON)
    string(JSON ZHONGFLY_MPV_ASSET_COUNT ERROR_VARIABLE ZHONGFLY_MPV_JSON_ERR
      LENGTH "${ZHONGFLY_MPV_JSON}" assets)
    if(ZHONGFLY_MPV_JSON_ERR STREQUAL "NOTFOUND" AND ZHONGFLY_MPV_ASSET_COUNT GREATER 0)
      math(EXPR ZHONGFLY_MPV_LAST "${ZHONGFLY_MPV_ASSET_COUNT} - 1")
      foreach(i RANGE ${ZHONGFLY_MPV_LAST})
        string(JSON ZHONGFLY_MPV_NAME GET "${ZHONGFLY_MPV_JSON}" assets ${i} name)
        # Match e.g. mpv-dev-x86_64-20260707-git-4c220ffd95.7z. Requiring a digit
        # right after the arch excludes the "-v3-" and "-lgpl-" variants.
        if(ZHONGFLY_MPV_NAME MATCHES "^mpv-dev-x86_64-[0-9].*\\.7z$")
          set(ZHONGFLY_MPV_ASSET_NAME "${ZHONGFLY_MPV_NAME}")
          string(JSON ZHONGFLY_MPV_ASSET_URL
            GET "${ZHONGFLY_MPV_JSON}" assets ${i} browser_download_url)
          string(JSON ZHONGFLY_MPV_DIGEST ERROR_VARIABLE ZHONGFLY_MPV_DIGEST_ERR
            GET "${ZHONGFLY_MPV_JSON}" assets ${i} digest)
          if(ZHONGFLY_MPV_DIGEST_ERR STREQUAL "NOTFOUND"
              AND ZHONGFLY_MPV_DIGEST MATCHES "^sha256:")
            string(REGEX REPLACE "^sha256:" "" ZHONGFLY_MPV_ASSET_SHA256
              "${ZHONGFLY_MPV_DIGEST}")
          endif()
          break()
        endif()
      endforeach()
    endif()
    if(ZHONGFLY_MPV_ASSET_NAME STREQUAL "")
      message(WARNING "Could not find an mpv-dev-x86_64 asset in the GitHub API response.")
    endif()
  else()
    list(GET ZHONGFLY_MPV_API_STATUS 1 ZHONGFLY_MPV_API_MSG)
    message(WARNING "Failed to query GitHub API for libmpv release "
      "(${ZHONGFLY_MPV_API_CODE}): ${ZHONGFLY_MPV_API_MSG}")
  endif()
else()
  message(WARNING "CMake ${CMAKE_VERSION} < 3.19 cannot parse JSON; "
    "skipping automatic libmpv resolution.")
endif()

# --- Download + extract the resolved asset (skipped if already current).
if(NOT ZHONGFLY_MPV_ASSET_NAME STREQUAL "")
  set(ZHONGFLY_MPV_ARCHIVE "${CMAKE_BINARY_DIR}/${ZHONGFLY_MPV_ASSET_NAME}")

  # Do we already have this exact asset extracted?
  set(ZHONGFLY_MPV_CURRENT FALSE)
  if(EXISTS "${CUSTOM_LIBMPV}" AND EXISTS "${ZHONGFLY_MPV_STAMP}")
    file(READ "${ZHONGFLY_MPV_STAMP}" ZHONGFLY_MPV_PREV)
    string(STRIP "${ZHONGFLY_MPV_PREV}" ZHONGFLY_MPV_PREV)
    if(ZHONGFLY_MPV_PREV STREQUAL "${ZHONGFLY_MPV_ASSET_NAME}")
      set(ZHONGFLY_MPV_CURRENT TRUE)
    endif()
  endif()

  if(ZHONGFLY_MPV_CURRENT)
    message(STATUS "zhongfly libmpv ${ZHONGFLY_MPV_ASSET_NAME} already up to date.")
  else()
    # New version -> drop any previous extraction.
    file(REMOVE_RECURSE "${ZHONGFLY_MPV_SRC}")
    file(MAKE_DIRECTORY "${ZHONGFLY_MPV_SRC}")

    # (Re)download unless a cached archive already matches the expected hash.
    set(ZHONGFLY_MPV_NEED_DL TRUE)
    if(EXISTS "${ZHONGFLY_MPV_ARCHIVE}" AND NOT ZHONGFLY_MPV_ASSET_SHA256 STREQUAL "")
      file(SHA256 "${ZHONGFLY_MPV_ARCHIVE}" ZHONGFLY_MPV_HAVE_SHA)
      if(ZHONGFLY_MPV_HAVE_SHA STREQUAL "${ZHONGFLY_MPV_ASSET_SHA256}")
        set(ZHONGFLY_MPV_NEED_DL FALSE)
      endif()
    endif()

    if(ZHONGFLY_MPV_NEED_DL)
      message(STATUS "Downloading ${ZHONGFLY_MPV_ASSET_NAME} ...")
      if(NOT ZHONGFLY_MPV_ASSET_SHA256 STREQUAL "")
        file(DOWNLOAD "${ZHONGFLY_MPV_ASSET_URL}" "${ZHONGFLY_MPV_ARCHIVE}"
          EXPECTED_HASH SHA256=${ZHONGFLY_MPV_ASSET_SHA256}
          SHOW_PROGRESS STATUS ZHONGFLY_MPV_DL_STATUS)
      else()
        message(WARNING "GitHub API provided no SHA-256 digest; "
          "downloading ${ZHONGFLY_MPV_ASSET_NAME} without hash verification.")
        file(DOWNLOAD "${ZHONGFLY_MPV_ASSET_URL}" "${ZHONGFLY_MPV_ARCHIVE}"
          SHOW_PROGRESS STATUS ZHONGFLY_MPV_DL_STATUS)
      endif()
      list(GET ZHONGFLY_MPV_DL_STATUS 0 ZHONGFLY_MPV_DL_CODE)
      if(NOT ZHONGFLY_MPV_DL_CODE EQUAL 0)
        list(GET ZHONGFLY_MPV_DL_STATUS 1 ZHONGFLY_MPV_DL_MSG)
        file(REMOVE "${ZHONGFLY_MPV_ARCHIVE}")
        message(WARNING "Failed to download ${ZHONGFLY_MPV_ASSET_NAME} "
          "(${ZHONGFLY_MPV_DL_CODE}): ${ZHONGFLY_MPV_DL_MSG}")
      endif()
    endif()

    # Extract libmpv-2.dll (CMake's bundled libarchive reads .7z). The DLL lives
    # at the archive root; extra headers/import lib are harmless and ignored.
    if(EXISTS "${ZHONGFLY_MPV_ARCHIVE}")
      message(STATUS "Extracting ${ZHONGFLY_MPV_ASSET_NAME} ...")
      execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${ZHONGFLY_MPV_ARCHIVE}"
        WORKING_DIRECTORY "${ZHONGFLY_MPV_SRC}"
        RESULT_VARIABLE ZHONGFLY_MPV_EXTRACT_RESULT)
      if(ZHONGFLY_MPV_EXTRACT_RESULT EQUAL 0 AND EXISTS "${CUSTOM_LIBMPV}")
        file(WRITE "${ZHONGFLY_MPV_STAMP}" "${ZHONGFLY_MPV_ASSET_NAME}")
      else()
        message(WARNING "Failed to extract libmpv-2.dll from ${ZHONGFLY_MPV_ASSET_NAME}.")
      endif()
    endif()
  endif()
endif()

# --- Install the resolved DLL over media_kit's, or fall back with a warning.
if(EXISTS "${CUSTOM_LIBMPV}")
  message(STATUS "Overriding bundled libmpv-2.dll with ${CUSTOM_LIBMPV}")
  install(FILES "${CUSTOM_LIBMPV}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  message(WARNING "No zhongfly libmpv-2.dll available; "
    "using media_kit's bundled (non-DASH) build.")
endif()

# === MMT/TLV to MPEG-TS converter (Windows x64) ===
# FFmpeg/libmpv has no ARIB MMT/TLV demuxer. dantto4k's latest Windows CI
# artifact supports already-descrambled HTTP streams; the v1.0.2-rc1 release
# does not yet recognize --frontend-descrambled. Resolve the newest artifact
# metadata from GitHub, download it through nightly.link (GitHub's artifact
# endpoint requires authentication), and verify it against GitHub's SHA-256.
set(DANTTO4K_DIR "${CMAKE_BINARY_DIR}/dantto4k")
set(DANTTO4K_EXE "${DANTTO4K_DIR}/dantto4k.exe")
set(DANTTO4K_STAMP "${DANTTO4K_DIR}/.artifact-id")
set(DANTTO4K_LICENSE "${DANTTO4K_DIR}/LICENSE.txt")
set(DANTTO4K_API_JSON "${CMAKE_BINARY_DIR}/dantto4k-artifacts.json")
set(DANTTO4K_API_URL
  "https://api.github.com/repos/nekohkr/dantto4k/actions/artifacts?name=dantto4k-main-windows-x64&per_page=1")
set(DANTTO4K_ARTIFACT_ID "")
set(DANTTO4K_ARTIFACT_SHA256 "")

if(NOT CMAKE_VERSION VERSION_LESS "3.19")
  file(DOWNLOAD "${DANTTO4K_API_URL}" "${DANTTO4K_API_JSON}"
    HTTPHEADER "Accept: application/vnd.github+json"
    HTTPHEADER "X-GitHub-Api-Version: 2022-11-28"
    TLS_VERIFY ON STATUS DANTTO4K_API_STATUS)
  list(GET DANTTO4K_API_STATUS 0 DANTTO4K_API_CODE)
  if(DANTTO4K_API_CODE EQUAL 0)
    file(READ "${DANTTO4K_API_JSON}" DANTTO4K_API_RESPONSE)
    string(JSON DANTTO4K_ARTIFACT_COUNT ERROR_VARIABLE DANTTO4K_JSON_ERROR
      LENGTH "${DANTTO4K_API_RESPONSE}" artifacts)
    if(DANTTO4K_JSON_ERROR STREQUAL "NOTFOUND"
        AND DANTTO4K_ARTIFACT_COUNT GREATER 0)
      string(JSON DANTTO4K_ARTIFACT_ID
        GET "${DANTTO4K_API_RESPONSE}" artifacts 0 id)
      string(JSON DANTTO4K_ARTIFACT_DIGEST
        GET "${DANTTO4K_API_RESPONSE}" artifacts 0 digest)
      string(REGEX REPLACE "^sha256:" "" DANTTO4K_ARTIFACT_SHA256
        "${DANTTO4K_ARTIFACT_DIGEST}")
    endif()
  else()
    message(WARNING "Failed to resolve the latest dantto4k artifact.")
  endif()
endif()

set(DANTTO4K_CURRENT FALSE)
if(NOT DANTTO4K_ARTIFACT_ID STREQUAL ""
    AND EXISTS "${DANTTO4K_EXE}" AND EXISTS "${DANTTO4K_STAMP}")
  file(READ "${DANTTO4K_STAMP}" DANTTO4K_PREVIOUS_ID)
  string(STRIP "${DANTTO4K_PREVIOUS_ID}" DANTTO4K_PREVIOUS_ID)
  if(DANTTO4K_PREVIOUS_ID STREQUAL "${DANTTO4K_ARTIFACT_ID}")
    set(DANTTO4K_CURRENT TRUE)
  endif()
endif()

if(NOT DANTTO4K_ARTIFACT_ID STREQUAL "" AND NOT DANTTO4K_CURRENT)
  set(DANTTO4K_ARCHIVE
    "${CMAKE_BINARY_DIR}/dantto4k-${DANTTO4K_ARTIFACT_ID}.zip")
  set(DANTTO4K_URL
    "https://nightly.link/nekohkr/dantto4k/actions/artifacts/${DANTTO4K_ARTIFACT_ID}.zip")
  file(DOWNLOAD "${DANTTO4K_URL}" "${DANTTO4K_ARCHIVE}"
    EXPECTED_HASH SHA256=${DANTTO4K_ARTIFACT_SHA256}
    TLS_VERIFY ON STATUS DANTTO4K_DOWNLOAD_STATUS)
  list(GET DANTTO4K_DOWNLOAD_STATUS 0 DANTTO4K_DOWNLOAD_CODE)
  if(DANTTO4K_DOWNLOAD_CODE EQUAL 0)
    set(DANTTO4K_STAGING "${CMAKE_BINARY_DIR}/dantto4k-staging")
    file(REMOVE_RECURSE "${DANTTO4K_STAGING}")
    file(MAKE_DIRECTORY "${DANTTO4K_STAGING}")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xf "${DANTTO4K_ARCHIVE}"
      WORKING_DIRECTORY "${DANTTO4K_STAGING}"
      RESULT_VARIABLE DANTTO4K_EXTRACT_RESULT)
    if(DANTTO4K_EXTRACT_RESULT EQUAL 0
        AND EXISTS "${DANTTO4K_STAGING}/dantto4k.exe")
      file(REMOVE_RECURSE "${DANTTO4K_DIR}")
      file(RENAME "${DANTTO4K_STAGING}" "${DANTTO4K_DIR}")
      file(WRITE "${DANTTO4K_STAMP}" "${DANTTO4K_ARTIFACT_ID}")
    else()
      message(WARNING "Failed to extract the dantto4k artifact.")
    endif()
  else()
    message(WARNING "Failed to download the dantto4k artifact.")
  endif()
endif()

if(EXISTS "${DANTTO4K_EXE}" AND NOT EXISTS "${DANTTO4K_LICENSE}")
  file(DOWNLOAD
    "https://raw.githubusercontent.com/nekohkr/dantto4k/main/LICENSE"
    "${DANTTO4K_LICENSE}"
    EXPECTED_HASH SHA256=c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
    TLS_VERIFY ON STATUS DANTTO4K_LICENSE_STATUS)
endif()

if(EXISTS "${DANTTO4K_EXE}")
  install(FILES "${DANTTO4K_EXE}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  if(EXISTS "${DANTTO4K_LICENSE}")
    install(FILES "${DANTTO4K_LICENSE}"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses/dantto4k"
      COMPONENT Runtime)
  endif()
else()
  message(WARNING "dantto4k.exe unavailable; MMT/TLV playback will be disabled.")
endif()
