#!/bin/zsh
# Downloads pinned mGBA and melonDS DS sources without their ROM/save test folders, then builds them into BuiltCores/.
# Needs: brew install cmake ninja. Delete the relevant cores/ subfolder before changing a pinned revision.
set -e
cd "$(dirname "$0")"
B=cores/build

fetch_core() {
  local name=$1 repo=$2 commit=$3
  if [[ ! -f "cores/$name/CMakeLists.txt" ]]; then
    echo "Downloading $name source without test ROMs or saves"
    mkdir -p "cores/$name"
    curl -fL "https://github.com/$repo/archive/$commit.tar.gz" -o "cores/$name.tar.gz"
    tar -xzf "cores/$name.tar.gz" -C "cores/$name" --strip-components=1 \
      --exclude='mgba-*/cinema' --exclude='mgba-*/cinema/*' \
      --exclude='melonds-ds-*/test' --exclude='melonds-ds-*/test/*'
    rm "cores/$name.tar.gz"
  fi
}

fetch_core mgba mgba-emu/mgba 649314925ab32193bbf65a52ef9fae87fbaccb47
fetch_core melonds-ds JesseTG/melonds-ds f394adbacb5722ee97c1b37c8064da9a25818310

cmake -S cores/mgba -B $B/mgba -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$PWD=." -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$PWD=." \
  -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF \
  -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DUSE_EPOXY=OFF -DUSE_FFMPEG=OFF -DUSE_EDITLINE=OFF \
  -DUSE_DISCORD_RPC=OFF -DUSE_LUA=OFF -DUSE_ELF=OFF -DUSE_SQLITE3=OFF -DUSE_LIBZIP=OFF -DUSE_MINIZIP=OFF \
  -DUSE_PNG=OFF -DUSE_ZLIB=OFF -DUSE_LZMA=OFF
ninja -C $B/mgba mgba_libretro
cmake -S cores/melonds-ds -B $B/melonds -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$PWD=." -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$PWD=." -DENABLE_OPENGL=OFF
ninja -C $B/melonds
mkdir -p BuiltCores
# Kept outside the synced MenuBarEmulator/ folder, or Xcode links them into the app instead of copying them.
cp $B/mgba/mgba_libretro.dylib BuiltCores/mgba.libretro
cp $B/melonds/src/libretro/melondsds_libretro.dylib BuiltCores/melondsds.libretro
echo "Cores copied to BuiltCores/"
