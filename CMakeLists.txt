cmake_minimum_required(VERSION 3.20)
project(NextZip LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "")
if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()

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

set(PLUGIN_SOURCES
  src/SevenZipEngine.cpp
  src/NextZipPlugin.mm
  src/NextZipController.mm
  src/NextZipDialogs.mm
)

add_library(NextZip MODULE ${SDK_SOURCES} ${PLUGIN_SOURCES})

target_include_directories(NextZip PRIVATE
  ${SZ}/CPP ${SZ} ${CMAKE_SOURCE_DIR}/deps/npp ${CMAKE_SOURCE_DIR}/src)

target_compile_definitions(NextZip PRIVATE NDEBUG _REENTRANT _FILE_OFFSET_BITS=64 _LARGEFILE_SOURCE)
target_compile_options(NextZip PRIVATE -Wno-deprecated-declarations -fPIC)
# ARC only for the ObjC++ UI files; the SDK/engine are plain C/C++.
set_source_files_properties(src/NextZipPlugin.mm src/NextZipController.mm src/NextZipDialogs.mm
  PROPERTIES COMPILE_FLAGS "-fobjc-arc")

set_target_properties(NextZip PROPERTIES PREFIX "" SUFFIX ".dylib" OUTPUT_NAME "NextZip")
target_link_libraries(NextZip "-framework Cocoa" "-ldl")

# ── install: the plugin dylib + the vendored universal 7z.so engine ──────────
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/NextZip")
install(TARGETS NextZip DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/deps/7z.so" DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${SZ}/DOC/License.txt" "${SZ}/DOC/unRarLicense.txt"
        DESTINATION "${PLUGIN_INSTALL_DIR}" OPTIONAL)
