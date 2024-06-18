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
symbol="#define PNG_LIBPNG_VER_STRING"
version="$(expr "$(grep "$symbol" libpng/png.h)" : ".*$symbol \"\([^\"]*\)\"")"
echo "${version}" > "${stage}/VERSION.txt"

pushd "$PNG_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

            # Setup staging dirs
            mkdir -p "$stage/include/libpng16"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_debug"
            pushd "build_debug"
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=$(cygpath -m $stage) \
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

                cp "libpng16_staticd.lib" "$stage/lib/debug/libpng16d.lib"
            popd

            mkdir -p "build_release"
            pushd "build_release"
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$(cygpath -m $stage) \
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

                cp "libpng16_static.lib" "$stage/lib/release/libpng16.lib"

                cp -a pnglibconf.h "$stage/include/libpng16"
            popd

            cp -a {png.h,pngconf.h} "$stage/include/libpng16"
        ;;

        darwin*)
            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            # Setup staging dirs
            mkdir -p "$stage/include/libpng16"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$C_OPTS_X86" \
                CXXFLAGS="$CXX_OPTS_X86" \
                LDFLAGS="$LINK_OPTS_X86" \
                cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS="$C_OPTS_X86" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_X86" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
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

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$C_OPTS_ARM64" \
                CXXFLAGS="$CXX_OPTS_ARM64" \
                LDFLAGS="$LINK_OPTS_ARM64" \
                cmake .. -G Ninja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS="$C_OPTS_ARM64" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_ARM64" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
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

            # create fat libraries
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
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$opts_c" \
                CXXFLAGS="$opts_cxx" \
                cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$opts_c" \
                    -DCMAKE_CXX_FLAGS="$opts_cxx" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DPNG_SHARED=OFF \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include" \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/libz.a"

                cmake --build . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cmake --install . --config Release
            popd
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/libpng.txt"
popd
