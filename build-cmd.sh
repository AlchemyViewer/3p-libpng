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
                    -DPNG_SHARED=ON -DPNG_HARDWARE_OPTIMIZATIONS=ON -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIR="$(cygpath -m $stage)/packages/include/zlib" -DZLIB_LIBRARY="$(cygpath -m $stage)/packages/lib/debug/zlibd.lib"
            
                cmake --build . --config Debug --clean-first

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi

                cp "Debug/libpng16_staticd.lib" "$stage/lib/debug/libpngd.lib"
            popd

            mkdir -p "build_release"
            pushd "build_release"
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_INSTALL_PREFIX=$(cygpath -m $stage) \
                    -DPNG_SHARED=ON -DPNG_HARDWARE_OPTIMIZATIONS=ON -DPNG_BUILD_ZLIB=ON \
                    -DZLIB_INCLUDE_DIR="$(cygpath -m $stage)/packages/include/zlib" -DZLIB_LIBRARY="$(cygpath -m $stage)/packages/lib/release/zlib.lib"
            
                cmake --build . --config Release --clean-first

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cp "Release/libpng16_static.lib" "$stage/lib/release/libpng.lib"

                cp -a pnglibconf.h "$stage/include/libpng16"
            popd

            cp -a {png.h,pngconf.h} "$stage/include/libpng16"
        ;;

        darwin*)
            opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"
            export CC=clang++

            # Install name for dylibs (if we wanted to build them).
            # The outline of a dylib build is here disabled by '#dylib#' 
            # comments.  The basics:  'configure' won't tolerate an
            # '-install_name' option in LDFLAGS so we have to use the
            # 'install_name_tool' to modify the dylibs after-the-fact.
            # This means that executables and test programs are built
            # with a non-relative path which isn't ideal.
            #
            # Dylib builds should also have "-Wl,-headerpad_max_install_names"
            # options to give the 'install_name_tool' space to work.
            #
            target_name="libpng16.16.dylib"
            install_name="@executable_path/../Resources/${target_name}"

            # Force libz static linkage by moving .dylibs out of the way
            # (Libz is currently packaging only statics but keep this alive...)
            trap restore_dylibs EXIT
            for dylib in "$stage"/packages/lib/{debug,release}/libz*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # See "linux" section for goals/challenges here...

            CFLAGS="$opts" \
                CXXFLAGS="$opts" \
                CPPFLAGS="${CPPFLAGS:-} -I$stage/packages/include/zlib" \
                LDFLAGS="-L$stage/packages/lib/release" \
                ./configure --prefix="$stage" --libdir="$stage/lib/release" \
                            --with-zlib-prefix="$stage/packages" --enable-shared=no --with-pic
            make
            make install
            #dylib# install_name_tool -id "${install_name}" "${stage}/lib/release/${target_name}"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #dylib# mkdir -p ./Resources/
                #dylib# ln -sf "${stage}"/lib/release/*.dylib ./Resources/

                make test
                #dylib# Modify the unit test binaries after-the-fact to point
                #dylib# to the expected path then run the tests again.
                #dylib# 
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngtest
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngstest
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngunknown
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngvalid
                #dylib# make test

                #dylib# rm -rf ./Resources/
            fi

            # clean the build artifacts
            make distclean
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

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

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
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            # clean the release build artifacts
            make distclean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/libpng.txt"
popd
