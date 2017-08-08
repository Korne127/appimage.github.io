#!/bin/bash

git checkout master

URL=$(cat $1 | head -n 1)
echo $URL

INPUTBASENAME=$(basename $1)

# Check if $URL starts with "http", otherwise exit
if [ ${URL:0:4} != http ] ; then
  echo "No http link detected in $1"
  exit 1
fi

# If $URL begins with https://api.github.com, then treat it specially
# This allows us to have generic URLs rather than URLs to specific releases
if [ ${URL:0:22} == https://api.github.com ] ; then
  echo "GitHub API URL detected"
  URL=$(wget -q "$URL" -O - | grep browser_download_url | grep -i AppImage | head -n 1 | cut -d '"' -f 4) # TODO: Handle more than one AppImage per release
  echo "URL from GitHub API: $URL"
fi

# Download the file if it is not already there
# This may get replaced by mounting the file with fuse httpfs
# if we find an implementation that supports https
FILENAME=$(basename $URL | cut -d '?' -f 1)
echo $FILENAME
if [ ! -e $FILENAME ] ; then
  wget -c "$URL"
fi

# Check the type of the AppImage
TYPE=""
MAGIC=$(dd if="$FILENAME" bs=1 skip=7 count=4)
if [ $MAGIC == $(echo -ne "\x41\x49\x02") ] ; then
  echo "AppImage type 2 detected"
  TYPE=2
elif [ $MAGIC == $(echo -ne "\x41\x49\x01") ] ; then
  echo "AppImage type 1 detected"
  TYPE=1
else
  echo "Unknown file detected"
  exit 1
fi

# Get lint (consider moving it to this repository at some point)
if [ ! -f appdir-lint.sh ] ; then
  wget -c -q https://raw.githubusercontent.com/AppImage/AppImages/master/appdir-lint.sh https://raw.githubusercontent.com/AppImage/AppImages/master/excludelist
fi
  
# If we have a type 2 AppImage, then mount it using appimagetool (not using itself for security reasons)
if [ $TYPE -eq 2 ] ; then
  if [ ! -e appimagetool-x86_64.AppImage ] ; then
    wget -c -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x appimagetool*
  fi
  # if [ -d squashfs-root ] ; then rm -rf squashfs-root/ ; fi
  TARGET_APPIMAGE="$FILENAME" ./appimagetool* --appimage-mount &
  PID=$!
  sleep 1
  mount | grep tmp | tail -n 1
  APPDIR=$(mount | grep tmp | tail -n 1 | cut -d " " -f 3)
  echo $APPDIR
  bash appdir-lint.sh "$APPDIR"
  # later # kill $PID # fuse
  # https://github.com/AppImage/AppImageSpec/blob/master/draft.md#updateinformation
  UPDATE_INFORMATION=$(TARGET_APPIMAGE="$FILENAME" ./appimagetool* --appimage-updateinformation) || echo "Could not get update information from the AppImage"
fi

# If we have a type 1 AppImage, then loop-mount it (not using itself for security reasons)
if [ $TYPE -eq 1 ] ; then
  # if [ -d squashfs-root ] ; then rm -rf squashfs-root/ ; fi
  sudo mount "$FILENAME" -o ro,loop /mnt
  APPDIR=/mnt
  echo $APPDIR
  bash appdir-lint.sh "$APPDIR"  
  # https://github.com/AppImage/AppImageSpec/blob/master/draft.md#updateinformation
  UPDATE_INFORMATION=$(dd if="${APPIMAGE}" bs=1 skip=33651 count=512 2>/dev/null) || echo "Could not get update information from the AppImage"
  # later # sudo umount -l /mnt
fi


echo "==========================================="

# TODO: If everything succeeded until here, then download Firejail aith Xpra and run the application in it
# and take screenshots if we don't have them already from AppStream

# LD_DEBUG=libs "$APPDIR/AppRun" & # Getting "Desktop file is missing. Please run /mnt/AppRun from within an AppImage." with wire-2.15.2751-x86_64.AppImage
# chmod +x "$FILENAME"
wet -c https://sourceforge.net/projects/firejail/files/firejail/firejail_0.9_1_amd64.deb/download -O firejail_0.9_1_amd64.deb
sudo dpkg -i firejail_0.9_1_amd64.deb

firejail --x11=xpra --appimage ./"$FILENAME" &
APID=$!
sleep 5
kill $APID && echo "SUCCESS" || exit 1


echo "==========================================="

# TODO: If everything succeeded until here, then put together a "database file" and display it

mkdir -p database/$INPUTBASENAME
cp "$APPDIR"/*.desktop database/$INPUTBASENAME/
DATAFILE=$(readlink -f database/$INPUTBASENAME/*.desktop)

echo "" >> "$DATAFILE"
echo "[AppImageHub]" >> "$DATAFILE"

if [ ! -x $UPDATE_INFORMATION] ; then
  echo "UpdateInformation=${UPDATE_INFORMATION}" >> "$DATAFILE"
else
  echo "UpdateInformation=false" >> "$DATAFILE"
  echo "# Dear upstream developer, please add update information to your AppImage" >> "$DATAFILE"
  echo "# so that users can easily update the AppImage" >> "$DATAFILE"
fi

echo "==========================================="
find database/ -type f -exec cat {} \;

# TODO: If there is an AppStream file, then extract data like screenshhot URLs from it

# If this is not a PR, then git add the "database file" and git commit with "[ci skip]" and git push
# https://gist.github.com/willprice/e07efd73fb7f13f917ea
git config --global user.email "travis@travis-ci.org"
git config --global user.name "Travis CI"
( cd database/ ; git add . || true ) # Recursively add everything in this directory
git commit -F- <<EOF || true # Always succeeed (even if there was nothing to add)
Add automatically parsed data ($TRAVIS_BUILD_NUMBER)
[ci skip]
EOF
git remote add deploy https://${GITHUB_TOKEN}@github.com/$TRAVIS_REPO_SLUG.git > /dev/null 2>&1
git push --set-upstream deploy

# TODO: If this is not a PR, then convert the "database files" into whatever output formats we need to support
# e.g., OCS for knsrc/Discover
# e.g., JSON for something Jekyll-based like https://quassy.github.io/elementary-apps/
# and trigger a deployment of the static website

if [ $TYPE -eq 2 ] ; then
  kill $PID # fuse
fi
if [ $TYPE -eq 1 ] ; then
  sudo umount -l /mnt
fi
