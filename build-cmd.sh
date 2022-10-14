#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

PNG_SOURCE_DIR="libpng"

if [ -z "$AUTOBUILD" ] ; then 
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

stage="$(pwd)/stage"

# load autobuild-provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

[ -f "$stage"/packages/include/zlib/zlib.h ] || \
{ echo "Run 'autobuild install' first." 1>&2 ; exit 1; }

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/{debug,release}/lib*.so*.disable; do 
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# Unlike grep, expr matches the specified pattern against a string also
# specified on its command line. So our first use of expr to obtain the
# version number went like this:
# expr "$(<libpng/png.h)" ...
# In other words, dump the entirety of png.h into expr's command line and
# search that. Unfortunately, png.h is long enough that on some (Linux!)
# platforms it's too long for the OS to pass. Now we use grep to find the
# right line, and expr to extract just the version number. Because of that, we
# state the relevant symbol name twice. Preface it with ".*" because expr
# implicitly anchors its search to the start of the input string.
symbol="PNG_LIBPNG_VER_STRING"
version="$(expr "$(grep "$symbol" libpng/png.h)" : ".*$symbol \"\([^\"]*\)\"")"
echo "${version}" > "${stage}/VERSION.txt"

pushd "$PNG_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

            mkdir -p "$stage/include/libpng16"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_debug"
            pushd "build_debug"
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_INSTALL_PREFIX=$(cygpath -m $stage) \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="$(cygpath -m $stage)/packages/include/zlib" \
                    -DZLIB_LIBRARIES="$(cygpath -m $stage)/packages/lib/debug/zlibd.lib"
            
                cmake --build . --config Debug --clean-first

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi

                cp "Debug/libpng16_staticd.lib" "$stage/lib/debug/libpng16d.lib"
            popd

            mkdir -p "build_release"
            pushd "build_release"
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_INSTALL_PREFIX=$(cygpath -m $stage) \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="$(cygpath -m $stage)/packages/include/zlib" \
                    -DZLIB_LIBRARIES="$(cygpath -m $stage)/packages/lib/release/zlib.lib"
            
                cmake --build . --config Release --clean-first

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cp "Release/libpng16_static.lib" "$stage/lib/release/libpng16.lib"

                cp -a pnglibconf.h "$stage/include/libpng16"
            popd

            cp -a {png.h,pngconf.h} "$stage/include/libpng16"
        ;;

        darwin*)
            # Setup osx sdk platform
            SDKNAME="macosx"
            export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)

            # Deploy Targets
            X86_DEPLOY=10.15
            ARM64_DEPLOY=11.0

            # Setup build flags
            ARCH_FLAGS_X86="-arch x86_64 -mmacosx-version-min=${X86_DEPLOY} -isysroot ${SDKROOT} -msse4.2"
            ARCH_FLAGS_ARM64="-arch arm64 -mmacosx-version-min=${ARM64_DEPLOY} -isysroot ${SDKROOT}"
            DEBUG_COMMON_FLAGS="-O0 -g -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="-O3 -g -fPIC -DPIC -fstack-protector-strong"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"
            DEBUG_LDFLAGS="-Wl,-headerpad_max_install_names"
            RELEASE_LDFLAGS="-Wl,-headerpad_max_install_names"

            # x86 Deploy Target
            export MACOSX_DEPLOYMENT_TARGET=${X86_DEPLOY}

            mkdir -p "build_debug_x86"
            pushd "build_debug_x86"
                CFLAGS="$ARCH_FLAGS_X86 $DEBUG_CFLAGS" \
                CXXFLAGS="$ARCH_FLAGS_X86 $DEBUG_CXXFLAGS" \
                CPPFLAGS="$ARCH_FLAGS_X86 $DEBUG_CPPFLAGS" \
                LDFLAGS="$ARCH_FLAGS_X86 $DEBUG_LDFLAGS" \
                cmake .. -GXcode -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$ARCH_FLAGS_X86 $DEBUG_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$ARCH_FLAGS_X86 $DEBUG_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="0" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_X86_VECTOR_INSTRUCTIONS=sse4.2 \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/debug_x86" \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/debug/libz.a"

                cmake --build . --config Debug
                cmake --install . --config Debug

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi
            popd

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS" \
                CXXFLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS" \
                CPPFLAGS="$ARCH_FLAGS_X86 $RELEASE_CPPFLAGS" \
                LDFLAGS="$ARCH_FLAGS_X86 $RELEASE_LDFLAGS" \
                cmake .. -GXcode -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="3" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_X86_VECTOR_INSTRUCTIONS=sse4.2 \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_x86" \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi
            popd

            # ARM64 Deploy Target
            export MACOSX_DEPLOYMENT_TARGET=${ARM64_DEPLOY}

            mkdir -p "build_debug_arm64"
            pushd "build_debug_arm64"
                CFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS" \
                CXXFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CXXFLAGS" \
                CPPFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CPPFLAGS" \
                LDFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_LDFLAGS" \
                cmake .. -GXcode -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="0" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/debug_arm64" \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_ARM_NEON=on \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/debug/libz.a"

                cmake --build . --config Debug
                cmake --install . --config Debug

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi
            popd

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS" \
                CXXFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CXXFLAGS" \
                CPPFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CPPFLAGS" \
                LDFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_LDFLAGS" \
                cmake .. -GXcode -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="3" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_arm64" \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_ARM_NEON=on \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi
            popd

            # create staging dir structure
            mkdir -p "$stage/include/libpng16"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            # create fat libraries
            lipo -create ${stage}/debug_x86/lib/libpng16d.a ${stage}/debug_arm64/lib/libpng16d.a -output ${stage}/lib/debug/libpng16d.a
            lipo -create ${stage}/release_x86/lib/libpng16.a ${stage}/release_arm64/lib/libpng16.a -output ${stage}/lib/release/libpng16.a

            # copy headers
            mv $stage/release_x86/include/libpng16/* $stage/include/libpng16
        ;;

        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
			DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
			RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
			DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
			RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
			RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
			RELEASE_CPPFLAGS="-DPIC"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Force static linkage to libz by moving .sos out of the way
            # (Libz is only packaging statics right now but keep this working.)
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/{debug,release}/libz.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            # 1.16 INSTALL claims ZLIBINC and ZLIBLIB env vars are active but this is not so.
            # If you fail to pick up the correct version of zlib (from packages), the build
            # will find the system's version and generate the wrong PNG_ZLIB_VERNUM definition
            # in the build.  Mostly you won't notice until certain things try to run.  So
            # check the generated pnglibconf.h when doing development and confirm it's correct.
            #
            # The sequence below has the effect of:
            # * Producing only static libraries.
            # * Builds all bin/* targets with static libraries.

            # Fix up path for pkgconfig
            if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
                fix_pkgconfig_prefix "$stage/packages"
            fi

            OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

            # force regenerate autoconf
            autoreconf -fvi

            # debug configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            # build the debug version and link against the debug zlib
            CFLAGS="$DEBUG_CFLAGS" \
                CXXFLAGS="$DEBUG_CXXFLAGS" \
                CPPFLAGS="${CPPFLAGS:-} ${DEBUG_CPPFLAGS} -I$stage/packages/include/zlib" \
                LDFLAGS="-L$stage/packages/lib/debug" \
                ./configure --enable-shared=no --with-pic --enable-hardware-optimizations=yes --enable-intel-sse=yes \
                    --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug"
            make
            make install DESTDIR="$stage"

            # conditionally run unit tests - Disabled due to weird linux failures
            #if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #    make test
            #fi

            # clean the debug build artifacts
            make distclean

            # release configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            # build the release version and link against the release zlib
            CFLAGS="$RELEASE_CFLAGS" \
                CXXFLAGS="$RELEASE_CXXFLAGS" \
                CPPFLAGS="${CPPFLAGS:-} ${RELEASE_CPPFLAGS} -I$stage/packages/include/zlib" \
                LDFLAGS="-L$stage/packages/lib/release" \
                ./configure --enable-shared=no --with-pic --enable-hardware-optimizations=yes --enable-intel-sse=yes \
                    --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release"
            make
            make install DESTDIR="$stage"

            # conditionally run unit tests
            #if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #    make test
            #fi

            # clean the release build artifacts
            make distclean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/libpng.txt"
popd
