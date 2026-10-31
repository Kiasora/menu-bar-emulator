#!/bin/zsh
# Downloads pinned emulator core sources (mGBA, melonDS DS, FCEUmm, bsnes, Gearsystem, clownmdemu) without their ROM/save test folders, then builds them into BuiltCores/.
# Needs: brew install cmake ninja. Delete the relevant cores/ subfolder before changing a pinned revision.
set -e
cd "$(dirname "$0")"
B=cores/build

fetch_core() {
  local name=$1 repo=$2 commit=$3
  if [[ -z "$(ls -A cores/$name 2>/dev/null)" ]]; then
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
fetch_core fceumm libretro/libretro-fceumm ac0d00a7fc01166f84c7bac01d1084ebfd2b865e
fetch_core bsnes libretro/bsnes 63ee22f7af8f5d1ada295c2c98fd7bf261fa62a7
fetch_core gearsystem drhelius/Gearsystem 40b8eebab53007c976eb29755b1ef7925140c37f
# clownmdemu keeps its emulator in git submodules, which GitHub's tarballs leave out.
if [[ -z "$(ls -A cores/clownmdemu 2>/dev/null)" ]]; then
  git clone -q https://github.com/Clownacy/clownmdemu-libretro cores/clownmdemu
  git -C cores/clownmdemu checkout -q d43c2708b0a31c285ce16724b6c4a2e92af07346
  git -C cores/clownmdemu submodule update -q --init --recursive
fi

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
J=$(sysctl -n hw.ncpu)
make -C cores/fceumm -f Makefile.libretro -j$J platform=osx arch=arm64
make -C cores/bsnes/bsnes -j$J target=libretro binary=library platform=macos local=false
make -C cores/gearsystem/platforms/libretro -j$J platform=osx arch=arm64
cmake -S cores/clownmdemu -B $B/clownmdemu -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
ninja -C $B/clownmdemu
mkdir -p BuiltCores
# Kept outside the synced MenuBarEmulator/ folder, or Xcode links them into the app instead of copying them.
cp $B/mgba/mgba_libretro.dylib BuiltCores/mgba.libretro
cp $B/melonds/src/libretro/melondsds_libretro.dylib BuiltCores/melondsds.libretro
cp cores/fceumm/fceumm_libretro.dylib BuiltCores/fceumm.libretro
cp cores/bsnes/bsnes/out/bsnes_libretro.dylib BuiltCores/bsnes.libretro
cp cores/gearsystem/platforms/libretro/gearsystem_libretro.dylib BuiltCores/gearsystem.libretro
cp $B/clownmdemu/clownmdemu_libretro.dylib BuiltCores/clownmdemu.libretro
echo "Cores copied to BuiltCores/"
