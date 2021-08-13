# Detect if we are running inside Docker
grep docker /proc/1/cgroup >/dev/null && export DOCKER_BUILD=1 || true

# Detect system architecture to know which binaries of AppImage tools
# should be downloaded and used.
case "$(uname -i)" in
  x86_64|amd64)
#    echo "x86-64 system architecture"
    SYSTEM_ARCH="x86_64";;
  i?86)
#    echo "x86 system architecture"
    SYSTEM_ARCH="i686";;
#  arm*)
#    echo "ARM system architecture"
#    SYSTEM_ARCH="";;
  unknown|AuthenticAMD|GenuineIntel)
#         uname -i not answer on debian, then:
    case "$(uname -m)" in
      x86_64|amd64)
#        echo "x86-64 system architecture"
        SYSTEM_ARCH="x86_64";;
      i?86)
#        echo "x86 system architecture"
        SYSTEM_ARCH="i686";;
    esac ;;
  *)
    echo "Unsupported system architecture"
    exit 1;;
esac

# Patch /usr to ././ in ./usr
# to make the contents of usr/ relocateable
# (this requires us to cd ./usr before running the application; AppRun does that)
patch_usr()
{
  find usr/ -type f -executable -exec sed -i -e "s|/usr|././|g" {} \;
}

# Copy the library dependencies of all exectuable files in the current directory
# (it can be beneficial to run this multiple times)
copy_deps()
{
  PWD=$(readlink -f .)
  FILES=$(find . -type f -executable -or -name *.so.* -or -name *.so | sort | uniq )
  for FILE in $FILES ; do
    ldd "${FILE}" | grep "=>" | awk '{print $3}' | xargs -I '{}' echo '{}' >> DEPSFILE
  done
  DEPS=$(cat DEPSFILE | sort | uniq)
  for FILE in $DEPS ; do
    if [ -e $FILE ] && [[ $(readlink -f $FILE)/ != $PWD/* ]] ; then
      cp -v --parents -rfL $FILE ./ || true
    fi
  done
  rm -f DEPSFILE
}

# Move ./lib/ tree to ./usr/lib/
move_lib()
{
  mkdir -p ./usr/lib ./lib && find ./lib/ -exec cp -v --parents -rfL {} ./usr/ \; && rm -rf ./lib
  mkdir -p ./usr/lib ./lib64 && find ./lib64/ -exec cp -v --parents -rfL {} ./usr/ \; && rm -rf ./lib64
}

# Delete blacklisted files
delete_blacklisted()
{
  BLACKLISTED_FILES=$( cat excludelist | sed 's|#.*||g')
  echo $BLACKLISTED_FILES

  local DOT_DIR=$(readlink -f .)
  local TARGET
  for FILE in $BLACKLISTED_FILES ; do
    FILES="$(find . -name "${FILE}" -not -path "./usr/optional/*")"
    for FOUND in $FILES ; do
      TARGET=$(readlink -f "$FOUND")

      # Only delete files from inside the current dir.
      if [[ $TARGET = $DOT_DIR/* ]]; then
        rm -vf "$TARGET"
      fi

      rm -vf "$FOUND"
    done
  done

  # Do not bundle developer stuff
  rm -rf usr/include || true
  rm -rf usr/lib/cmake || true
  rm -rf usr/lib/pkgconfig || true
  find . -name '*.la' | xargs -i rm {}
}

# Echo highest glibc version needed by the executable files in the current directory
glibc_needed()
{
  find . -name *.so -or -name *.so.* -or -type f -executable  -exec strings {} \; | grep ^GLIBC_2 | sed s/GLIBC_//g | sort --version-sort | uniq | tail -n 1
  # find . -name *.so -or -name *.so.* -or -type f -executable  -exec readelf -s '{}' 2>/dev/null \; | sed -n 's/.*@GLIBC_//p'| awk '{print $1}' | sort --version-sort | tail -n 1
}
# Add desktop integration
# Usage: get_desktopintegration name_of_desktop_file_and_exectuable
get_desktopintegration()
{
  # REALBIN=$(grep -o "^Exec=.*" *.desktop | sed -e 's|Exec=||g' | cut -d " " -f 1 | head -n 1)
  # cat_file_from_url https://raw.githubusercontent.com/AppImage/AppImageKit/deprecated/AppImageAssistant/desktopintegration > ./usr/bin/$REALBIN.wrapper
  # chmod a+x ./usr/bin/$REALBIN.wrapper
  echo "The desktopintegration script is deprecated. Please advise users to use https://github.com/AppImage/appimaged instead."
  # sed -i -e "s|^Exec=$REALBIN|Exec=$REALBIN.wrapper|g" $1.desktop
}

# Generate AppImage type 2
# Additional parameters given to this routine will be passed on to appimagetool
#
# If the environment variable NO_GLIBC_VERSION is set, the required glibc version
# will not be added to the AppImage filename
generate_type2_appimage()
{
  # Get the ID of the last successful build on Travis CI
  # ID=$(wget -q https://api.travis-ci.org/repos/AppImage/appimagetool/builds -O - | head -n 1 | sed -e 's|}|\n|g' | grep '"result":0' | head -n 1 | sed -e 's|,|\n|g' | grep '"id"' | cut -d ":" -f 2)
  # Get the transfer.sh URL from the logfile of the last successful build on Travis CI
  # Only Travis knows why build ID and job ID don't match and why the above doesn't give both...
  # URL=$(wget -q "https://s3.amazonaws.com/archive.travis-ci.org/jobs/$((ID+1))/log.txt" -O - | grep "https://transfer.sh/.*/appimagetool" | tail -n 1 | sed -e 's|\r||g')
  # if [ -z "$URL" ] ; then
  #   URL=$(wget -q "https://s3.amazonaws.com/archive.travis-ci.org/jobs/$((ID+2))/log.txt" -O - | grep "https://transfer.sh/.*/appimagetool" | tail -n 1 | sed -e 's|\r||g')
  # fi
  if [ -z "$(which appimagetool)" ] ; then
    cp ../../appimagetool-${SYSTEM_ARCH}.AppImage ./appimagetool
    chmod a+x ./appimagetool
    appimagetool=$(readlink -f appimagetool)
  else
    appimagetool=$(which appimagetool)
  fi
  if [ "$DOCKER_BUILD" ]; then
    appimagetool_tempdir=$(mktemp -d)
    mv appimagetool "$appimagetool_tempdir"
    pushd "$appimagetool_tempdir" &>/dev/null
    ls -al
    ./appimagetool --appimage-extract
    rm appimagetool
    appimagetool=$(readlink -f squashfs-root/AppRun)
    popd &>/dev/null
    _appimagetool_cleanup() { [ -d "$appimagetool_tempdir" ] && rm -r "$appimagetool_tempdir"; }
    trap _appimagetool_cleanup EXIT
  fi

  if [ -z ${NO_GLIBC_VERSION+true} ]; then
    GLIBC_NEEDED=$(glibc_needed)
    VERSION_EXPANDED=$VERSION.glibc$GLIBC_NEEDED
  else
    VERSION_EXPANDED=$VERSION
  fi

  set +x

  GLIBC_NEEDED=$(glibc_needed)
  _APP_DIR="${PWD}/$APP.AppDir/"
  export OWD="${PWD}"
   

  if [ -z "$RECIPE" ] ; then
    VERSION=$VERSION_EXPANDED "$appimagetool" $@ -n -g -v "${_APP_DIR}"
  else
    VERSION=$VERSION_EXPANDED "$appimagetool" $@ -n --bintray-user $BINTRAY_USER --bintray-repo $BINTRAY_REPO -v "${_APP_DIR}"
  fi
  set -x
  mkdir -p ../out/ || true
  mv *.AppImage* ../out/
}

# Find the desktop file and copy it to the AppDir
get_desktop()
{
   find usr/share/applications -iname "*${LOWERAPP}.desktop" -exec cp {} . \; || true
}

fix_desktop() {
    # fix trailing semicolons
    for key in Actions Categories Implements Keywords MimeType NotShowIn OnlyShowIn; do
      sed -i '/'"$key"'.*[^;]$/s/$/;/' $1
    done
}

# Find the icon file and copy it to the AppDir
get_icon()
{
  find ./usr/share/pixmaps/$LOWERAPP.png -exec cp {} . \; 2>/dev/null || true
  find ./usr/share/icons -path *64* -name $LOWERAPP.png -exec cp {} . \; 2>/dev/null || true
  find ./usr/share/icons -path *128* -name $LOWERAPP.png -exec cp {} . \; 2>/dev/null || true
  find ./usr/share/icons -path *512* -name $LOWERAPP.png -exec cp {} . \; 2>/dev/null || true
  find ./usr/share/icons -path *256* -name $LOWERAPP.png -exec cp {} . \; 2>/dev/null || true
  ls -lh $LOWERAPP.png || true
}

# Find out the version
get_version()
{
  THEDEB=$(find ../*.deb -name $LOWERAPP"_*" | head -n 1)
  if [ -z "$THEDEB" ] ; then
    echo "Version could not be determined from the .deb; you need to determine it manually"
  fi
  VERSION=$(echo $THEDEB | cut -d "~" -f 1 | cut -d "_" -f 2 | cut -d "-" -f 1 | sed -e 's|1%3a||g' | sed -e 's|.dfsg||g' )
  echo $VERSION
}

# transfer.sh
transfer() { if [ $# -eq 0 ]; then echo "No arguments specified. Usage:\necho transfer /tmp/test.md\ncat /tmp/test.md | transfer test.md"; return 1; fi
tmpfile=$( mktemp -t transferXXX ); if tty -s; then basefile=$(basename "$1" | sed -e 's/[^a-zA-Z0-9._-]/-/g'); curl --progress-bar --upload-file "$1" "https://transfer.sh/$basefile" >> $tmpfile; else curl --progress-bar --upload-file "-" "https://transfer.sh/$1" >> $tmpfile ; fi; cat $tmpfile; rm -f $tmpfile; }

# Patch binary files; fill with padding if replacement is shorter than original
# http://everydaywithlinux.blogspot.de/2012/11/patch-strings-in-binary-files-with-sed.html
# Example: patch_strings_in_file foo "/usr/local/lib/foo" "/usr/lib/foo"
patch_strings_in_file() {
    local FILE="$1"
    local PATTERN="$2"
    local REPLACEMENT="$3"
    # Find all unique strings in FILE that contain the pattern
    STRINGS=$(strings ${FILE} | grep ${PATTERN} | sort -u -r)
    if [ "${STRINGS}" != "" ] ; then
        echo "File '${FILE}' contain strings with '${PATTERN}' in them:"
        for OLD_STRING in ${STRINGS} ; do
            # Create the new string with a simple bash-replacement
            NEW_STRING=${OLD_STRING//${PATTERN}/${REPLACEMENT}}
            # Create null terminated ASCII HEX representations of the strings
            OLD_STRING_HEX="$(echo -n ${OLD_STRING} | xxd -g 0 -u -ps -c 256)00"
            NEW_STRING_HEX="$(echo -n ${NEW_STRING} | xxd -g 0 -u -ps -c 256)00"
            if [ ${#NEW_STRING_HEX} -le ${#OLD_STRING_HEX} ] ; then
                # Pad the replacement string with null terminations so the
                # length matches the original string
                while [ ${#NEW_STRING_HEX} -lt ${#OLD_STRING_HEX} ] ; do
                    NEW_STRING_HEX="${NEW_STRING_HEX}00"
                done
                # Now, replace every occurrence of OLD_STRING with NEW_STRING
                echo -n "Replacing ${OLD_STRING} with ${NEW_STRING}... "
                hexdump -ve '1/1 "%.2X"' ${FILE} | \
                sed "s/${OLD_STRING_HEX}/${NEW_STRING_HEX}/g" | \
                xxd -r -p > ${FILE}.tmp
                chmod --reference ${FILE} ${FILE}.tmp
                mv ${FILE}.tmp ${FILE}
                echo "Done!"
            else
                echo "New string '${NEW_STRING}' is longer than old" \
                     "string '${OLD_STRING}'. Skipping."
            fi
        done
    fi
}