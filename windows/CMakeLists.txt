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

# === Override bundled mpv DLLs with KwokShing/mpv-builds ===
# This Windows build includes FFmpeg's mmttlv demuxer, so MMT/TLV streams are
# handled directly by libmpv without a separate converter.
# Prefer the mpv-windows-x86_64.zip asset from the latest GitHub Release. Only
# when no published Release exists, or that Release has no matching Windows
# asset, fall back to the newest non-expired Actions artifact via nightly.link.
# Release assets are single ZIPs containing mpv-win; Actions downloads are
# double ZIPs whose outer archive contains mpv-windows-x86_64.zip.
# Extraction happens entirely in staging. The existing cache is replaced only
# after SHA-256 and mpv-win/libmpv-2.dll have been verified; failures retain the
# cached runtime. media_kit is the final fallback.
set(KWOKSHING_MPV_CACHE "${CMAKE_BINARY_DIR}/kwokshing_mpv")
set(KWOKSHING_MPV_RUNTIME "${KWOKSHING_MPV_CACHE}/mpv-win")
set(CUSTOM_LIBMPV "${KWOKSHING_MPV_RUNTIME}/libmpv-2.dll")
set(KWOKSHING_MPV_STAMP "${KWOKSHING_MPV_CACHE}/.source-stamp")
set(KWOKSHING_MPV_RELEASE_JSON "${CMAKE_BINARY_DIR}/kwokshing-mpv-release.json")
set(KWOKSHING_MPV_ARTIFACTS_JSON "${CMAKE_BINARY_DIR}/kwokshing-mpv-artifacts.json")
set(KWOKSHING_MPV_RELEASE_API_URL
  "https://api.github.com/repos/KwokShing/mpv-builds/releases/latest")
set(KWOKSHING_MPV_ARTIFACTS_API_URL
  "https://api.github.com/repos/KwokShing/mpv-builds/actions/artifacts?name=mpv-windows-x86_64&per_page=1")
set(KWOKSHING_MPV_SOURCE_KIND "")
set(KWOKSHING_MPV_SOURCE_ID "")
set(KWOKSHING_MPV_SOURCE_SHA256 "")
set(KWOKSHING_MPV_SOURCE_URL "")
set(KWOKSHING_MPV_SOURCE_DOUBLE_ZIP FALSE)
set(KWOKSHING_MPV_RELEASE_ABSENT FALSE)

if(NOT CMAKE_VERSION VERSION_LESS "3.19")
  message(STATUS "Resolving the latest KwokShing/mpv-builds Release ...")
  file(DOWNLOAD "${KWOKSHING_MPV_RELEASE_API_URL}" "${KWOKSHING_MPV_RELEASE_JSON}"
    HTTPHEADER "Accept: application/vnd.github+json"
    HTTPHEADER "X-GitHub-Api-Version: 2022-11-28"
    TLS_VERIFY ON STATUS KWOKSHING_MPV_RELEASE_STATUS
    LOG KWOKSHING_MPV_RELEASE_LOG)
  list(GET KWOKSHING_MPV_RELEASE_STATUS 0 KWOKSHING_MPV_RELEASE_CODE)
  if(KWOKSHING_MPV_RELEASE_CODE EQUAL 0)
    file(READ "${KWOKSHING_MPV_RELEASE_JSON}" KWOKSHING_MPV_RELEASE_RESPONSE)
    string(JSON KWOKSHING_MPV_RELEASE_ASSET_COUNT
      ERROR_VARIABLE KWOKSHING_MPV_RELEASE_ASSET_COUNT_ERROR
      LENGTH "${KWOKSHING_MPV_RELEASE_RESPONSE}" assets)
    if(KWOKSHING_MPV_RELEASE_ASSET_COUNT_ERROR STREQUAL "NOTFOUND")
      set(KWOKSHING_MPV_RELEASE_ASSET_FOUND FALSE)
      set(KWOKSHING_MPV_RELEASE_ASSET_INDEX 0)
      while(KWOKSHING_MPV_RELEASE_ASSET_INDEX LESS KWOKSHING_MPV_RELEASE_ASSET_COUNT)
        string(JSON KWOKSHING_MPV_RELEASE_ASSET_NAME
          ERROR_VARIABLE KWOKSHING_MPV_RELEASE_ASSET_NAME_ERROR
          GET "${KWOKSHING_MPV_RELEASE_RESPONSE}" assets
            ${KWOKSHING_MPV_RELEASE_ASSET_INDEX} name)
        if(KWOKSHING_MPV_RELEASE_ASSET_NAME_ERROR STREQUAL "NOTFOUND"
            AND KWOKSHING_MPV_RELEASE_ASSET_NAME STREQUAL "mpv-windows-x86_64.zip")
          set(KWOKSHING_MPV_RELEASE_ASSET_FOUND TRUE)
          string(JSON KWOKSHING_MPV_RELEASE_ASSET_ID
            ERROR_VARIABLE KWOKSHING_MPV_RELEASE_ASSET_ID_ERROR
            GET "${KWOKSHING_MPV_RELEASE_RESPONSE}" assets
              ${KWOKSHING_MPV_RELEASE_ASSET_INDEX} id)
          string(JSON KWOKSHING_MPV_RELEASE_ASSET_URL
            ERROR_VARIABLE KWOKSHING_MPV_RELEASE_ASSET_URL_ERROR
            GET "${KWOKSHING_MPV_RELEASE_RESPONSE}" assets
              ${KWOKSHING_MPV_RELEASE_ASSET_INDEX} browser_download_url)
          string(JSON KWOKSHING_MPV_RELEASE_ASSET_DIGEST
            ERROR_VARIABLE KWOKSHING_MPV_RELEASE_ASSET_DIGEST_ERROR
            GET "${KWOKSHING_MPV_RELEASE_RESPONSE}" assets
              ${KWOKSHING_MPV_RELEASE_ASSET_INDEX} digest)
          if(KWOKSHING_MPV_RELEASE_ASSET_ID_ERROR STREQUAL "NOTFOUND"
              AND KWOKSHING_MPV_RELEASE_ASSET_URL_ERROR STREQUAL "NOTFOUND"
              AND KWOKSHING_MPV_RELEASE_ASSET_DIGEST_ERROR STREQUAL "NOTFOUND"
              AND KWOKSHING_MPV_RELEASE_ASSET_DIGEST MATCHES "^sha256:")
            string(REGEX REPLACE "^sha256:" "" KWOKSHING_MPV_RELEASE_SHA256
              "${KWOKSHING_MPV_RELEASE_ASSET_DIGEST}")
            string(LENGTH "${KWOKSHING_MPV_RELEASE_SHA256}"
              KWOKSHING_MPV_RELEASE_SHA256_LENGTH)
            if(KWOKSHING_MPV_RELEASE_SHA256_LENGTH EQUAL 64
                AND KWOKSHING_MPV_RELEASE_SHA256 MATCHES "^[0-9A-Fa-f]+$")
              string(TOLOWER "${KWOKSHING_MPV_RELEASE_SHA256}"
                KWOKSHING_MPV_SOURCE_SHA256)
              set(KWOKSHING_MPV_SOURCE_KIND "release")
              set(KWOKSHING_MPV_SOURCE_ID "${KWOKSHING_MPV_RELEASE_ASSET_ID}")
              set(KWOKSHING_MPV_SOURCE_URL "${KWOKSHING_MPV_RELEASE_ASSET_URL}")
            else()
              message(WARNING "The latest mpv Release asset has an invalid SHA-256; "
                "retaining the cached mpv runtime.")
            endif()
          else()
            message(WARNING "The latest mpv Release asset metadata is incomplete; "
              "retaining the cached mpv runtime.")
          endif()
          break()
        endif()
        math(EXPR KWOKSHING_MPV_RELEASE_ASSET_INDEX
          "${KWOKSHING_MPV_RELEASE_ASSET_INDEX} + 1")
      endwhile()
      if(NOT KWOKSHING_MPV_RELEASE_ASSET_FOUND)
        set(KWOKSHING_MPV_RELEASE_ABSENT TRUE)
        message(STATUS "The latest mpv Release has no Windows asset; "
          "falling back to Actions artifacts.")
      endif()
    else()
      message(WARNING "The latest mpv Release metadata could not be parsed; "
        "retaining the cached mpv runtime.")
    endif()
  elseif("${KWOKSHING_MPV_RELEASE_LOG}" MATCHES "HTTP/[0-9.]+ 404"
      OR "${KWOKSHING_MPV_RELEASE_LOG}" MATCHES "error: 404")
    set(KWOKSHING_MPV_RELEASE_ABSENT TRUE)
    message(STATUS "No published mpv Release exists; falling back to Actions artifacts.")
  else()
    list(GET KWOKSHING_MPV_RELEASE_STATUS 1 KWOKSHING_MPV_RELEASE_MESSAGE)
    message(WARNING "Failed to query the latest KwokShing/mpv-builds Release "
      "(${KWOKSHING_MPV_RELEASE_CODE}): ${KWOKSHING_MPV_RELEASE_MESSAGE}; "
      "retaining the cached mpv runtime.")
  endif()

  if(KWOKSHING_MPV_RELEASE_ABSENT)
    message(STATUS "Resolving the latest KwokShing/mpv-builds Windows artifact ...")
    file(DOWNLOAD "${KWOKSHING_MPV_ARTIFACTS_API_URL}"
      "${KWOKSHING_MPV_ARTIFACTS_JSON}"
      HTTPHEADER "Accept: application/vnd.github+json"
      HTTPHEADER "X-GitHub-Api-Version: 2022-11-28"
      TLS_VERIFY ON STATUS KWOKSHING_MPV_ARTIFACTS_STATUS)
    list(GET KWOKSHING_MPV_ARTIFACTS_STATUS 0 KWOKSHING_MPV_ARTIFACTS_CODE)
    if(KWOKSHING_MPV_ARTIFACTS_CODE EQUAL 0)
      file(READ "${KWOKSHING_MPV_ARTIFACTS_JSON}"
        KWOKSHING_MPV_ARTIFACTS_RESPONSE)
      string(JSON KWOKSHING_MPV_ARTIFACT_COUNT
        ERROR_VARIABLE KWOKSHING_MPV_ARTIFACT_COUNT_ERROR
        LENGTH "${KWOKSHING_MPV_ARTIFACTS_RESPONSE}" artifacts)
      if(KWOKSHING_MPV_ARTIFACT_COUNT_ERROR STREQUAL "NOTFOUND"
          AND KWOKSHING_MPV_ARTIFACT_COUNT GREATER 0)
        string(JSON KWOKSHING_MPV_ARTIFACT_ID
          ERROR_VARIABLE KWOKSHING_MPV_ARTIFACT_ID_ERROR
          GET "${KWOKSHING_MPV_ARTIFACTS_RESPONSE}" artifacts 0 id)
        string(JSON KWOKSHING_MPV_ARTIFACT_DIGEST
          ERROR_VARIABLE KWOKSHING_MPV_ARTIFACT_DIGEST_ERROR
          GET "${KWOKSHING_MPV_ARTIFACTS_RESPONSE}" artifacts 0 digest)
        string(JSON KWOKSHING_MPV_ARTIFACT_EXPIRED
          ERROR_VARIABLE KWOKSHING_MPV_ARTIFACT_EXPIRED_ERROR
          GET "${KWOKSHING_MPV_ARTIFACTS_RESPONSE}" artifacts 0 expired)
        if(KWOKSHING_MPV_ARTIFACT_ID_ERROR STREQUAL "NOTFOUND"
            AND KWOKSHING_MPV_ARTIFACT_DIGEST_ERROR STREQUAL "NOTFOUND"
            AND KWOKSHING_MPV_ARTIFACT_EXPIRED_ERROR STREQUAL "NOTFOUND")
          if(KWOKSHING_MPV_ARTIFACT_EXPIRED)
            message(WARNING "The latest KwokShing/mpv-builds artifact is expired; "
              "retaining the cached mpv runtime.")
          elseif(KWOKSHING_MPV_ARTIFACT_DIGEST MATCHES "^sha256:")
            string(REGEX REPLACE "^sha256:" "" KWOKSHING_MPV_ARTIFACT_SHA256
              "${KWOKSHING_MPV_ARTIFACT_DIGEST}")
            string(LENGTH "${KWOKSHING_MPV_ARTIFACT_SHA256}"
              KWOKSHING_MPV_ARTIFACT_SHA256_LENGTH)
            if(KWOKSHING_MPV_ARTIFACT_SHA256_LENGTH EQUAL 64
                AND KWOKSHING_MPV_ARTIFACT_SHA256 MATCHES "^[0-9A-Fa-f]+$")
              string(TOLOWER "${KWOKSHING_MPV_ARTIFACT_SHA256}"
                KWOKSHING_MPV_SOURCE_SHA256)
              set(KWOKSHING_MPV_SOURCE_KIND "artifact")
              set(KWOKSHING_MPV_SOURCE_ID "${KWOKSHING_MPV_ARTIFACT_ID}")
              set(KWOKSHING_MPV_SOURCE_URL
                "https://nightly.link/KwokShing/mpv-builds/actions/artifacts/${KWOKSHING_MPV_ARTIFACT_ID}.zip")
              set(KWOKSHING_MPV_SOURCE_DOUBLE_ZIP TRUE)
            else()
              message(WARNING "GitHub returned an invalid artifact SHA-256; "
                "retaining the cached mpv runtime.")
            endif()
          else()
            message(WARNING "GitHub returned no artifact SHA-256; "
              "retaining the cached mpv runtime.")
          endif()
        else()
          message(WARNING "The KwokShing/mpv-builds artifact metadata is incomplete; "
            "retaining the cached mpv runtime.")
        endif()
      else()
        message(WARNING "No mpv-windows-x86_64 artifact was returned; "
          "retaining the cached mpv runtime.")
      endif()
    else()
      list(GET KWOKSHING_MPV_ARTIFACTS_STATUS 1
        KWOKSHING_MPV_ARTIFACTS_MESSAGE)
      message(WARNING "Failed to query KwokShing/mpv-builds artifacts "
        "(${KWOKSHING_MPV_ARTIFACTS_CODE}): ${KWOKSHING_MPV_ARTIFACTS_MESSAGE}; "
        "retaining the cached mpv runtime.")
    endif()
  endif()
else()
  message(WARNING "CMake ${CMAKE_VERSION} cannot parse GitHub source metadata; "
    "retaining the cached mpv runtime.")
endif()

set(KWOKSHING_MPV_CURRENT FALSE)
if(NOT KWOKSHING_MPV_SOURCE_KIND STREQUAL "")
  set(KWOKSHING_MPV_SOURCE_STAMP
    "${KWOKSHING_MPV_SOURCE_KIND}:${KWOKSHING_MPV_SOURCE_ID}:${KWOKSHING_MPV_SOURCE_SHA256}")
  if(EXISTS "${CUSTOM_LIBMPV}" AND EXISTS "${KWOKSHING_MPV_STAMP}")
    file(READ "${KWOKSHING_MPV_STAMP}" KWOKSHING_MPV_PREVIOUS_STAMP)
    string(STRIP "${KWOKSHING_MPV_PREVIOUS_STAMP}"
      KWOKSHING_MPV_PREVIOUS_STAMP)
    if(KWOKSHING_MPV_PREVIOUS_STAMP STREQUAL "${KWOKSHING_MPV_SOURCE_STAMP}")
      set(KWOKSHING_MPV_CURRENT TRUE)
      message(STATUS "KwokShing mpv ${KWOKSHING_MPV_SOURCE_KIND} "
        "${KWOKSHING_MPV_SOURCE_ID} is cached.")
    endif()
  endif()
endif()

if(NOT KWOKSHING_MPV_SOURCE_KIND STREQUAL "" AND NOT KWOKSHING_MPV_CURRENT)
  set(KWOKSHING_MPV_ARCHIVE
    "${CMAKE_BINARY_DIR}/mpv-windows-x86_64-${KWOKSHING_MPV_SOURCE_KIND}-${KWOKSHING_MPV_SOURCE_ID}.zip")
  set(KWOKSHING_MPV_DOWNLOAD_OK FALSE)

  if(EXISTS "${KWOKSHING_MPV_ARCHIVE}")
    file(SHA256 "${KWOKSHING_MPV_ARCHIVE}" KWOKSHING_MPV_CACHED_SHA256)
    if(KWOKSHING_MPV_CACHED_SHA256 STREQUAL "${KWOKSHING_MPV_SOURCE_SHA256}")
      set(KWOKSHING_MPV_DOWNLOAD_OK TRUE)
    else()
      file(REMOVE "${KWOKSHING_MPV_ARCHIVE}")
    endif()
  endif()

  if(NOT KWOKSHING_MPV_DOWNLOAD_OK)
    message(STATUS "Downloading KwokShing mpv ${KWOKSHING_MPV_SOURCE_KIND} "
      "${KWOKSHING_MPV_SOURCE_ID} ...")
    file(DOWNLOAD "${KWOKSHING_MPV_SOURCE_URL}" "${KWOKSHING_MPV_ARCHIVE}"
      EXPECTED_HASH SHA256=${KWOKSHING_MPV_SOURCE_SHA256}
      TLS_VERIFY ON SHOW_PROGRESS STATUS KWOKSHING_MPV_DOWNLOAD_STATUS)
    list(GET KWOKSHING_MPV_DOWNLOAD_STATUS 0 KWOKSHING_MPV_DOWNLOAD_CODE)
    if(KWOKSHING_MPV_DOWNLOAD_CODE EQUAL 0)
      set(KWOKSHING_MPV_DOWNLOAD_OK TRUE)
    else()
      list(GET KWOKSHING_MPV_DOWNLOAD_STATUS 1 KWOKSHING_MPV_DOWNLOAD_MESSAGE)
      file(REMOVE "${KWOKSHING_MPV_ARCHIVE}")
      message(WARNING "Failed to download or verify the selected KwokShing mpv "
        "${KWOKSHING_MPV_SOURCE_KIND}: ${KWOKSHING_MPV_DOWNLOAD_MESSAGE}; "
        "retaining the cached mpv runtime.")
    endif()
  endif()

  if(KWOKSHING_MPV_DOWNLOAD_OK)
    set(KWOKSHING_MPV_STAGING
      "${CMAKE_BINARY_DIR}/kwokshing-mpv-staging-${KWOKSHING_MPV_SOURCE_KIND}-${KWOKSHING_MPV_SOURCE_ID}")
    set(KWOKSHING_MPV_STAGED_CACHE "${KWOKSHING_MPV_STAGING}/cache")
    set(KWOKSHING_MPV_STAGED_LIBMPV
      "${KWOKSHING_MPV_STAGED_CACHE}/mpv-win/libmpv-2.dll")
    file(REMOVE_RECURSE "${KWOKSHING_MPV_STAGING}")
    file(MAKE_DIRECTORY "${KWOKSHING_MPV_STAGED_CACHE}")
    set(KWOKSHING_MPV_EXTRACT_RESULT 1)

    if(KWOKSHING_MPV_SOURCE_DOUBLE_ZIP)
      set(KWOKSHING_MPV_OUTER_DIR "${KWOKSHING_MPV_STAGING}/outer")
      set(KWOKSHING_MPV_INNER_ARCHIVE
        "${KWOKSHING_MPV_OUTER_DIR}/mpv-windows-x86_64.zip")
      file(MAKE_DIRECTORY "${KWOKSHING_MPV_OUTER_DIR}")
      execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${KWOKSHING_MPV_ARCHIVE}"
        WORKING_DIRECTORY "${KWOKSHING_MPV_OUTER_DIR}"
        RESULT_VARIABLE KWOKSHING_MPV_OUTER_EXTRACT_RESULT)
      if(KWOKSHING_MPV_OUTER_EXTRACT_RESULT EQUAL 0
          AND EXISTS "${KWOKSHING_MPV_INNER_ARCHIVE}")
        execute_process(
          COMMAND "${CMAKE_COMMAND}" -E tar xf "${KWOKSHING_MPV_INNER_ARCHIVE}"
          WORKING_DIRECTORY "${KWOKSHING_MPV_STAGED_CACHE}"
          RESULT_VARIABLE KWOKSHING_MPV_EXTRACT_RESULT)
      endif()
    else()
      execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${KWOKSHING_MPV_ARCHIVE}"
        WORKING_DIRECTORY "${KWOKSHING_MPV_STAGED_CACHE}"
        RESULT_VARIABLE KWOKSHING_MPV_EXTRACT_RESULT)
    endif()

    if(KWOKSHING_MPV_EXTRACT_RESULT EQUAL 0
        AND EXISTS "${KWOKSHING_MPV_STAGED_LIBMPV}")
      file(WRITE "${KWOKSHING_MPV_STAGED_CACHE}/.source-stamp"
        "${KWOKSHING_MPV_SOURCE_STAMP}")
      set(KWOKSHING_MPV_BACKUP "${CMAKE_BINARY_DIR}/kwokshing_mpv_backup")
      file(REMOVE_RECURSE "${KWOKSHING_MPV_BACKUP}")
      set(KWOKSHING_MPV_CACHE_MOVED FALSE)
      if(EXISTS "${KWOKSHING_MPV_CACHE}")
        execute_process(
          COMMAND "${CMAKE_COMMAND}" -E rename
            "${KWOKSHING_MPV_CACHE}" "${KWOKSHING_MPV_BACKUP}"
          RESULT_VARIABLE KWOKSHING_MPV_BACKUP_RESULT)
        if(KWOKSHING_MPV_BACKUP_RESULT EQUAL 0)
          set(KWOKSHING_MPV_CACHE_MOVED TRUE)
        endif()
      else()
        set(KWOKSHING_MPV_BACKUP_RESULT 0)
      endif()

      if(KWOKSHING_MPV_BACKUP_RESULT EQUAL 0)
        execute_process(
          COMMAND "${CMAKE_COMMAND}" -E rename
            "${KWOKSHING_MPV_STAGED_CACHE}" "${KWOKSHING_MPV_CACHE}"
          RESULT_VARIABLE KWOKSHING_MPV_ACTIVATE_RESULT)
        if(KWOKSHING_MPV_ACTIVATE_RESULT EQUAL 0)
          file(REMOVE_RECURSE "${KWOKSHING_MPV_BACKUP}")
          message(STATUS "Activated KwokShing mpv ${KWOKSHING_MPV_SOURCE_KIND} "
            "${KWOKSHING_MPV_SOURCE_ID}.")
        elseif(KWOKSHING_MPV_CACHE_MOVED)
          execute_process(
            COMMAND "${CMAKE_COMMAND}" -E rename
              "${KWOKSHING_MPV_BACKUP}" "${KWOKSHING_MPV_CACHE}"
            RESULT_VARIABLE KWOKSHING_MPV_RESTORE_RESULT)
          message(WARNING "Failed to activate the staged mpv runtime; "
            "restored the cached runtime.")
        else()
          message(WARNING "Failed to activate the staged mpv runtime.")
        endif()
      else()
        message(WARNING "Could not preserve the cached mpv runtime for replacement; "
          "the existing cache was left unchanged.")
      endif()
    else()
      message(WARNING "The selected KwokShing mpv package did not contain "
        "mpv-win/libmpv-2.dll; retaining the cached mpv runtime.")
    endif()
    file(REMOVE_RECURSE "${KWOKSHING_MPV_STAGING}")
  endif()
endif()

# This install rule follows PLUGIN_BUNDLED_LIBRARIES, so every DLL from mpv-win
# is copied afterward and overrides any same-named DLL bundled by media_kit.
if(EXISTS "${CUSTOM_LIBMPV}")
  file(GLOB KWOKSHING_MPV_DLLS LIST_DIRECTORIES FALSE
    "${KWOKSHING_MPV_RUNTIME}/*.dll")
  install(FILES ${KWOKSHING_MPV_DLLS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  message(STATUS "Using cached KwokShing mpv runtime from ${KWOKSHING_MPV_RUNTIME}.")
else()
  message(WARNING "No verified KwokShing mpv runtime is cached; "
    "using media_kit's bundled libmpv as the final fallback.")
endif()

# === AV3A (AVS3-P3 / Audio Vivid) decoder bridge (Windows x64) ===
# Upstream FFmpeg/libmpv does not decode China's AV3A format. A dedicated
# FFmpeg build decodes AV3A to AAC while stream-copying video; Dart exposes the
# synchronized MPEG-TS output to the existing libmpv over loopback HTTP.
# Keep this artifact pinned: it is third-party software with no license file in
# its release, so downstream distributors must review its terms independently.
option(ENABLE_AV3A_SUPPORT "Bundle the third-party AV3A decoder bridge" ON)
set(AV3A_FFMPEG_URL
  "https://github.com/raddyfiy/av3a_ffmpeg_decoder/releases/download/v1.0/av3a.mpv.7z")
set(AV3A_FFMPEG_SHA256
  "f1c545b528e403b4740d645896b6a08c677e8e3828fbe9aa90e3e3f3444c040f")
set(AV3A_FFMPEG_ARCHIVE "${CMAKE_BINARY_DIR}/av3a-mpv-v1.0.7z")
set(AV3A_FFMPEG_DIR "${CMAKE_BINARY_DIR}/av3a_ffmpeg")
set(AV3A_FFMPEG_EXE "${AV3A_FFMPEG_DIR}/ffmpeg.exe")
set(AV3A_FFMPEG_NOTICE "${AV3A_FFMPEG_DIR}/NOTICE.txt")

if(ENABLE_AV3A_SUPPORT AND NOT EXISTS "${AV3A_FFMPEG_EXE}")
  file(DOWNLOAD "${AV3A_FFMPEG_URL}" "${AV3A_FFMPEG_ARCHIVE}"
    EXPECTED_HASH SHA256=${AV3A_FFMPEG_SHA256}
    TLS_VERIFY ON SHOW_PROGRESS STATUS AV3A_FFMPEG_DOWNLOAD_STATUS)
  list(GET AV3A_FFMPEG_DOWNLOAD_STATUS 0 AV3A_FFMPEG_DOWNLOAD_CODE)
  if(AV3A_FFMPEG_DOWNLOAD_CODE EQUAL 0)
    file(REMOVE_RECURSE "${AV3A_FFMPEG_DIR}")
    file(MAKE_DIRECTORY "${AV3A_FFMPEG_DIR}")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xf "${AV3A_FFMPEG_ARCHIVE}"
      WORKING_DIRECTORY "${AV3A_FFMPEG_DIR}"
      RESULT_VARIABLE AV3A_FFMPEG_EXTRACT_RESULT)
    if(NOT AV3A_FFMPEG_EXTRACT_RESULT EQUAL 0)
      message(WARNING "Failed to extract the AV3A FFmpeg runtime.")
    endif()
  else()
    list(GET AV3A_FFMPEG_DOWNLOAD_STATUS 1 AV3A_FFMPEG_DOWNLOAD_MESSAGE)
    message(WARNING "Failed to download AV3A FFmpeg: ${AV3A_FFMPEG_DOWNLOAD_MESSAGE}")
    file(REMOVE "${AV3A_FFMPEG_ARCHIVE}")
  endif()
endif()

if(ENABLE_AV3A_SUPPORT AND EXISTS "${AV3A_FFMPEG_EXE}")
  file(WRITE "${AV3A_FFMPEG_NOTICE}"
    "AV3A decoder runtime\nSource: ${AV3A_FFMPEG_URL}\nSHA-256: ${AV3A_FFMPEG_SHA256}\nThe upstream release provides no license file. Review redistribution rights before distributing this optional component.\n")
  install(FILES "${AV3A_FFMPEG_EXE}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/av3a_ffmpeg" COMPONENT Runtime)
  install(DIRECTORY "${AV3A_FFMPEG_DIR}/"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/av3a_ffmpeg" COMPONENT Runtime
    FILES_MATCHING PATTERN "*.dll" PATTERN "*.so")
  install(FILES "${AV3A_FFMPEG_NOTICE}"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses/av3a_ffmpeg"
    COMPONENT Runtime)
else()
  message(WARNING "AV3A runtime unavailable; Audio Vivid streams will be silent.")
endif()
