cmake_minimum_required(VERSION 3.20)
project(NextZip VERSION 1.0.0 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "")
if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Both targets default ON so a clean checkout produces the plugin AND the app;
# turn either off (-DNEXTZIP_BUILD_PLUGIN=OFF / -DNEXTZIP_BUILD_APP=OFF).
option(NEXTZIP_BUILD_PLUGIN "Build the NextZip.dylib Nextpad++ plugin" ON)
option(NEXTZIP_BUILD_APP    "Build the standalone NextZip.app"          ON)

set(SZ "${CMAKE_SOURCE_DIR}/deps/7zip")

# ── 7-Zip client-side SDK support files (mirror Client7z/makefile.gcc) ────────
set(SDK_SOURCES
  ${SZ}/C/Alloc.c
  ${SZ}/CPP/Common/IntToString.cpp ${SZ}/CPP/Common/MyString.cpp
  ${SZ}/CPP/Common/MyVector.cpp    ${SZ}/CPP/Common/NewHandler.cpp
  ${SZ}/CPP/Common/StringConvert.cpp ${SZ}/CPP/Common/StringToInt.cpp
  ${SZ}/CPP/Common/UTFConvert.cpp  ${SZ}/CPP/Common/Wildcard.cpp
  ${SZ}/CPP/Common/MyWindows.cpp
  ${SZ}/CPP/Windows/DLL.cpp        ${SZ}/CPP/Windows/FileDir.cpp
  ${SZ}/CPP/Windows/FileFind.cpp   ${SZ}/CPP/Windows/FileIO.cpp
  ${SZ}/CPP/Windows/FileName.cpp   ${SZ}/CPP/Windows/PropVariant.cpp
  ${SZ}/CPP/Windows/PropVariantConv.cpp ${SZ}/CPP/Windows/TimeUtils.cpp
  ${SZ}/CPP/7zip/Common/FileStreams.cpp
)

# ── Shared, host-agnostic core (engine + UI) — compiled into BOTH targets ─────
# SevenZipEngine.cpp is plain C++; the two .mm files are the host-agnostic UI
# (NextZipController routes everything host-specific through id<NextZipHost>).
set(NEXTZIP_CORE_SOURCES
  src/SevenZipEngine.cpp
  src/NextZipController.mm
  src/NextZipDialogs.mm)

# ARC applies to the shared ObjC++ UI files (used by both targets). Source-file
# properties are directory-scoped, so set once here for both.
set_source_files_properties(src/NextZipController.mm src/NextZipDialogs.mm
  PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# ─────────────────────────────────────────────────────────────────────────────
#  Target 1 — NextZip.dylib (the Nextpad++ plugin)
# ─────────────────────────────────────────────────────────────────────────────
if(NEXTZIP_BUILD_PLUGIN)
  # SHARED (MH_DYLIB), not MODULE (MH_BUNDLE): only a dylib carries a Mach-O
  # current_version, which Plugins Admin reads to show the installed version.
  add_library(NextZip SHARED ${SDK_SOURCES} ${NEXTZIP_CORE_SOURCES} src/NextZipPlugin.mm)

  target_include_directories(NextZip PRIVATE
    ${SZ}/CPP ${SZ} ${CMAKE_SOURCE_DIR}/deps/npp ${CMAKE_SOURCE_DIR}/src)
  target_compile_definitions(NextZip PRIVATE NDEBUG _REENTRANT _FILE_OFFSET_BITS=64 _LARGEFILE_SOURCE)
  target_compile_options(NextZip PRIVATE -Wno-deprecated-declarations -fPIC)
  set_source_files_properties(src/NextZipPlugin.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")

  set_target_properties(NextZip PROPERTIES PREFIX "" SUFFIX ".dylib" OUTPUT_NAME "NextZip")
  target_link_libraries(NextZip "-framework Cocoa" "-ldl")
  # Stamp the version into the dylib's Mach-O current_version (Plugins Admin reads it).
  target_link_options(NextZip PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

  # install: the plugin dylib + the vendored universal 7z.so engine
  set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/NextZip")
  install(TARGETS NextZip DESTINATION "${PLUGIN_INSTALL_DIR}")
  install(FILES "${CMAKE_SOURCE_DIR}/deps/7z.so" DESTINATION "${PLUGIN_INSTALL_DIR}")
  install(FILES "${SZ}/DOC/License.txt" "${SZ}/DOC/unRarLicense.txt"
          DESTINATION "${PLUGIN_INSTALL_DIR}" OPTIONAL)
endif()

# ─────────────────────────────────────────────────────────────────────────────
#  Target 2 — NextZip.app (standalone macOS app, same core)
# ─────────────────────────────────────────────────────────────────────────────
if(NEXTZIP_BUILD_APP)
  set(NEXTZIP_APP_VERSION "1.0.0")

  set(APP_SHELL_SOURCES
    shell-app/main.mm
    shell-app/NextZipAppDelegate.mm
    shell-app/NextZipMainWindowController.mm
    shell-app/NextZipMenuBuilder.mm)
  set_source_files_properties(${APP_SHELL_SOURCES} PROPERTIES COMPILE_FLAGS "-fobjc-arc")

  # Bundle resources into Contents/Resources: app icon (.icns), the Tahoe glass
  # icon (Assets.car, if generated), the 7z.so engine (the app points the engine
  # at it via pathForResource), and the engine licenses.
  set(APP_RESOURCES "")
  foreach(R
      "${CMAKE_SOURCE_DIR}/resources/nzip.icns"
      "${CMAKE_SOURCE_DIR}/resources/Assets.car"
      "${CMAKE_SOURCE_DIR}/deps/7z.so"
      "${SZ}/DOC/License.txt"
      "${SZ}/DOC/unRarLicense.txt")
    if(EXISTS "${R}")
      set_source_files_properties("${R}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
      list(APPEND APP_RESOURCES "${R}")
    endif()
  endforeach()

  add_executable(NextZipApp MACOSX_BUNDLE
    ${SDK_SOURCES} ${NEXTZIP_CORE_SOURCES} ${APP_SHELL_SOURCES} ${APP_RESOURCES})

  target_include_directories(NextZipApp PRIVATE
    ${SZ}/CPP ${SZ} ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/shell-app)
  target_compile_definitions(NextZipApp PRIVATE NDEBUG _REENTRANT _FILE_OFFSET_BITS=64 _LARGEFILE_SOURCE)
  target_compile_options(NextZipApp PRIVATE -Wno-deprecated-declarations)
  target_link_libraries(NextZipApp "-framework Cocoa" "-ldl")

  set_target_properties(NextZipApp PROPERTIES
    OUTPUT_NAME "NextZip"
    MACOSX_BUNDLE_BUNDLE_NAME           "NextZip"
    MACOSX_BUNDLE_GUI_IDENTIFIER        "org.nextpadplusplus.mac.NextZip"
    MACOSX_BUNDLE_BUNDLE_VERSION        "${NEXTZIP_APP_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING  "${NEXTZIP_APP_VERSION}"
    MACOSX_BUNDLE_EXECUTABLE_NAME       "NextZip"
    MACOSX_BUNDLE_ICON_FILE             "nzip.icns"
    MACOSX_BUNDLE_INFO_PLIST            "${CMAKE_SOURCE_DIR}/shell-app/Info.plist.in")

  # Ad-hoc sign so the bundle launches on Apple Silicon (arm64 requires a
  # signature). Sign the nested 7z.so first, then seal the bundle. Release
  # signing (Developer ID + hardened runtime + notarize) is a separate step.
  add_custom_command(TARGET NextZipApp POST_BUILD
    COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:NextZipApp>/Contents/Resources/7z.so"
    COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:NextZipApp>"
    VERBATIM)
endif()
