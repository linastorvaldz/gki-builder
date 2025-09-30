#!/usr/bin/env bash
set -e

# Constants
WORKDIR="$(pwd)"
RELEASE="v0.1"
KERNEL_NAME="QuartiX"
USER="eraselk"
HOST="gacorprjkt"
TIMEZONE="Asia/Makassar"
ANYKERNEL_REPO="https://github.com/linastorvaldz/anykernel"
ANYKERNEL_BRANCH="android15-6.6"
KERNEL_REPO="https://github.com/linastorvaldz/kernel_common"
KERNEL_BRANCH="android15-6.6-lts"
KERNEL_DEFCONFIG="gki_defconfig"
GKI_RELEASES_REPO="https://github.com/linastorvaldz/quartix-releases"
CLANG_URL="https://github.com/linastorvaldz/idk/releases/download/clang-r510928/clang.tar.gz"
CLANG_BRANCH=""
AK3_ZIP_NAME="AK3-$KERNEL_NAME-REL-KVER-VARIANT-BUILD_DATE.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"

# Handle error
exec > >(tee $WORKDIR/build.log) 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

# Import functions
source $WORKDIR/functions.sh

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

# Clone kernel source
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC

cd $KSRC
LINUX_VERSION=$(make kernelversion)
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
cd $WORKDIR

# Set Kernel variant
log "Setting Kernel variant..."
case "$KSU" in
  "Next") VARIANT="KSUN" ;;
  "Suki") VARIANT="SUKISU" ;;
  "None") VARIANT="NKSU" ;;
esac
susfs_included && VARIANT+="+SuSFS"

# Replace Placeholder in zip name
AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  wget -qO clang-archive "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.*)
      tar -xf clang-archive -C "$CLANG_DIR"
      ;;
    *.7z)
      7z x clang-archive -o${CLANG_DIR}/ -bd -y > /dev/null
      ;;
    *)
      error "Unsupported file format"
      ;;
  esac
  rm clang-archive

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv $SINGLE_DIR/* $CLANG_DIR/
    rm -rf $SINGLE_DIR
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

# Clone GCC
log "Cloning GCC..."
GCC_DIR="$WORKDIR/gcc"
GCC_BIN="${GCC_DIR}/bin"
git clone --depth=1 -q \
  https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
  $GCC_DIR

# Clone Rust
log "Cloning Rust...."
RUST_DIR="$WORKDIR/rust"
RUST_BIN="${RUST_DIR}/linux-x86/1.73.0b/bin"
git clone --depth=1 -q \
  https://android.googlesource.com/platform/prebuilts/rust \
  -b main-kernel-build-2024 \
  $RUST_DIR

# Clone kernel build tools
log "Cloning Kbuild tools..."
KBUILD_TOOLS_DIR="$WORKDIR/kbuild-tools"
KBUILD_TOOLS_BIN="${KBUILD_TOOLS_DIR}/linux-x86/bin"
git clone --depth=1 -q \
  https://android.googlesource.com/kernel/prebuilts/build-tools \
  -b main-kernel-build-2024 \
  $KBUILD_TOOLS_DIR

export PATH="${CLANG_BIN}:${GCC_BIN}:${RUST_BIN}:${KBUILD_TOOLS_BIN}:$PATH"

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd $KSRC

## KernelSU setup
if ksu_included; then
  # Remove existing KernelSU drivers
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU; do
    if [[ -d $KSU_PATH ]]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [[ -f "$KSU_DIR/Kconfig" ]] && sed -i '/kernelsu/d' $KSU_DIR/Kconfig
      [[ -f "$KSU_DIR/Makefile" ]] && sed -i '/kernelsu/d' $KSU_DIR/Makefile

      rm -rf $KSU_PATH
    fi
  done

  # Install kernelsu
  case "$KSU" in
    "Next") install_ksu $(susfs_included && echo "GoRhanHee/KernelSU-Next" || echo "KernelSU-Next/KernelSU-Next") $(susfs_included && echo "next-susfs-experimental" || echo "next") ;;
    "Suki") install_ksu SukiSU-Ultra/SukiSU-Ultra $(if susfs_included; then echo "susfs-main"; elif ksu_manual_hook; then echo "nongki"; else echo "main"; fi) ;;
  esac
  config --enable CONFIG_KSU
fi

# SUSFS
if susfs_included; then
  # Kernel-side
  log "Applying kernel-side susfs patches"
  SUSFS_DIR="$WORKDIR/susfs"
  SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"
  SUSFS_BRANCH=gki-android15-6.6
  git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b $SUSFS_BRANCH $SUSFS_DIR
  cp -R $SUSFS_PATCHES/fs/* ./fs
  cp -R $SUSFS_PATCHES/include/* ./include
  patch -p1 < $SUSFS_PATCHES/50_add_susfs_in_gki-android15-6.6.patch
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

# KSU Manual Hooks
if ksu_manual_hook; then
  log "Applying manual hook patch"
  #  if [[ "$KSU" == "Next" ]]; then
  #    log "Using manual-hook v1.5"
  #    patch -p1 --forward --fuzz=3 < $WORKDIR/kernel-patches/manual-hook-v1.5.patch
  #  else
  #    log "Using manual-hook v1.4"
  patch -p1 --forward < $WORKDIR/kernel-patches/manual-hook-v1.4.patch
  #  fi
  config --enable CONFIG_KSU_MANUAL_HOOK
  config --disable CONFIG_KSU_KPROBES_HOOK
  config --disable CONFIG_KSU_SUSFS_SUS_SU # Conflicts with manual hook
fi

# Enable KPM Supports for SukiSU
# if [[ $KSU == "Suki" ]]; then
#   config --enable CONFIG_KPM
# fi

# set localversion
if [[ $TODO == "kernel" ]]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  if [[ $STATUS == "BETA" ]]; then
    SUFFIX="$LATEST_COMMIT_HASH"
  else
    SUFFIX="${RELEASE}-${LATEST_COMMIT_HASH}"
  fi
  config --set-str CONFIG_LOCALVERSION "-$KERNEL_NAME-$SUFFIX"
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(date)
MAKE_ARGS=(
  LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-android-
  -j$(nproc --all)
  O=$OUTDIR
  RUSTC=rustc
  PAHOLE=pahole
  LD=ld.lld HOSTLD=ld.lld
)
KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"

text=$(
  cat << EOF
*$KERNEL_NAME CI*
🐧 *Linux Version*: $LINUX_VERSION
📅 *Build Date*: $KBUILD_BUILD_TIMESTAMP
📛 *KernelSU*: ${KSU}
ඞ *SuSFS*: $(susfs_included && echo "$SUSFS_VERSION" || echo "None")
🔰 *Compiler*: $COMPILER_STRING
EOF
)
MESSAGE_ID=$(send_msg "$text" 2>&1 | jq -r .result.message_id)

## Build GKI
log "Generating config..."
make ${MAKE_ARGS[@]} $KERNEL_DEFCONFIG

# Upload defconfig if we are doing defconfig
if [[ $TODO == "defconfig" ]]; then
  log "Uploading defconfig..."
  upload_file $OUTDIR/.config
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make ${MAKE_ARGS[@]} Image modules

log "Installing the kernel modules..."
make ${MAKE_ARGS[@]} \
  INSTALL_MOD_PATH=./out_modules \
  INSTALL_MOD_STRIP=1 \
  modules_install

## Build system dlkm image
log "Building system dlkm image..."
KERNEL_MODULES_DIR="$(realpath $OUTDIR/out_modules/lib/modules/*)"
KERNEL_MODULES_LIST=$(find "$KERNEL_MODULES_DIR" -type f -name '*.ko' | grep -viE 'kunit|test')
MISSING=""
shopt -s nullglob
for idunno in $(echo $WORKDIR/system_dlkm/system_dlkm/lib/modules/modules.*); do
  idunno=$(basename "$idunno")
  if [ -f "$KERNEL_MODULES_DIR/$idunno" ]; then
    cp $KERNEL_MODULES_DIR/$idunno $WORKDIR/system_dlkm/system_dlkm/lib/modules
  else
    MISSING+="$idunno "
  fi
done
shopt -u nullglob

if [[ "$MISSING" ]]; then
  for oke in $MISSING; do
    case "$oke" in
      modules.load)
        generate_modules_load "$KERNEL_MODULES_DIR/modules.dep" "$WORKDIR/system_dlkm/system_dlkm/lib/modules/modules.load"
        ;;
      *) error "File $oke is not found." ;;
    esac
  done
fi

# Copy the kernel modules
cp $KERNEL_MODULES_LIST $WORKDIR/system_dlkm/system_dlkm/lib/modules

# Generate fs configs
for f in $WORKDIR/system_dlkm/system_dlkm/lib/modules/*; do
  echo "system_dlkm/lib/modules/$(basename $f) 0 0 0644" \
    >> $WORKDIR/system_dlkm/config/system_dlkm_fs_config
done

# Generate file contexts
for f in $WORKDIR/system_dlkm/system_dlkm/lib/modules/*; do
  echo "/system_dlkm/lib/modules/$(basename "$f" | sed 's|\.ko$|\\.ko|') u:object_r:system_dlkm_file:s0" \
    >> $WORKDIR/system_dlkm/config/system_dlkm_file_contexts
done

# We need to rewrite the modules.dep
rewrite_modules_dep "$WORKDIR/system_dlkm/system_dlkm/lib/modules/modules.dep"

# Build the actual image
mkfs_erofs "$WORKDIR/system_dlkm/system_dlkm" "$WORKDIR/system_dlkm.img"

# Check KMI Function symbol
# $KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS"

## Post-compiling stuff
cd $WORKDIR

# Patch the kernel Image for KPM Supports
#if [[ $KSU == "Suki" ]]; then
#  tempdir=$(mktemp -d) && cd $tempdir
#
#  # Setup patching tool
#  LATEST_SUKISU_PATCH=$(curl -s "https://api.github.com/repos/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest" | grep "browser_download_url" | grep "patch_linux" | cut -d '"' -f 4)
#  curl -Ls "$LATEST_SUKISU_PATCH" -o patch_linux
#  chmod a+x ./patch_linux
#
#  # Patch the kernel image
#  cp $KERNEL_IMAGE ./Image
#  sudo ./patch_linux
#  mv oImage Image
#  KERNEL_IMAGE=$(pwd)/Image
#
#  cd -
#fi

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Set kernel string in anykernel
if [[ $STATUS == "BETA" ]]; then
  BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
  AK3_ZIP_NAME=${AK3_ZIP_NAME//BUILD_DATE/$BUILD_DATE}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-REL/}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${LINUX_VERSION} (${BUILD_DATE}) ${VARIANT}/g" \
    $WORKDIR/anykernel/anykernel.sh
else
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-BUILD_DATE/}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT}/g" \
    $WORKDIR/anykernel/anykernel.sh
fi

# Zip the anykernel
cd anykernel
log "Zipping anykernel..."
cp $KERNEL_IMAGE .
cp "$WORKDIR/system_dlkm.img" .
zip -r9 $WORKDIR/$AK3_ZIP_NAME ./*
cd $OLDPWD

# Zip the kernel image
mkdir kernel-image && cd kernel-image
log "Zipping kernel image.."
cp $KERNEL_IMAGE .
KERNEL_IMAGE_ZIP_NAME=${AK3_ZIP_NAME//AK3/KIMG}
zip -r9 $WORKDIR/$KERNEL_IMAGE_ZIP_NAME ./*
cd $OLDPWD

# Zip the system dlkm image
if [[ $STATUS == "BETA" ]]; then
  SYSTEM_DLKM_IMAGE_ZIP_NAME=${AK3_ZIP_NAME//AK3/SYSDLKM}
  mkdir system-dlkm-image && cd system-dlkm-image
  log "Zipping system dlkm image..."
  cp "$WORKDIR/system_dlkm.img" .
  zip -r9 "$WORKDIR/$SYSTEM_DLKM_IMAGE_ZIP_NAME" ./*
  cd "$OLDPWD"
fi

# Compress the kernel modules
# KERNEL_MODULES_ARCHIVE_NAME=${AK3_ZIP_NAME//AK3/KMOD}
# KERNEL_MODULES_ARCHIVE_NAME=${KERNEL_MODULES_ARCHIVE_NAME//.zip/.tar.gz}
# mkdir kernel-modules && cd kernel-modules
# log "Compressing kernel modules..."
# cp -R $KERNEL_MODULES .
# tar -czf "$WORKDIR/$KERNEL_MODULES_ARCHIVE_NAME" ./*
# cd $OLDPWD

if [[ $BUILD_BOOTIMG == "true" ]]; then
  AOSP_MIRROR=https://android.googlesource.com
  AOSP_BRANCH=main-kernel-build-2024
  log "Cloning build tools..."
  git clone -q --depth=1 $AOSP_MIRROR/kernel/prebuilts/build-tools -b $AOSP_BRANCH build-tools
  log "Cloning mkbootimg..."
  git clone -q --depth=1 $AOSP_MIRROR/platform/system/tools/mkbootimg -b $AOSP_BRANCH mkbootimg

  AVBTOOL="$WORKDIR/build-tools/linux-x86/bin/avbtool"
  MKBOOTIMG="$WORKDIR/mkbootimg/mkbootimg.py"
  UNPACK_BOOTIMG="$WORKDIR/mkbootimg/unpack_bootimg.py"
  BOOT_SIGN_KEY_PATH="$WORKDIR/key/key.pem"
  BOOTIMG_NAME="${AK3_ZIP_NAME%.zip}-boot-dummy1.img"

  generate_bootimg() {
    local kernel="$1"
    local output="$2"

    # Create boot image
    log "Creating $output"
    $MKBOOTIMG --header_version 4 \
      --kernel "$kernel" \
      --output "$output" \
      --ramdisk out/ramdisk \
      --os_version 15.0.0 \
      --os_patch_level "2099-12"

    sleep 0.5

    # Sign the boot image
    log "Signing $output"
    $AVBTOOL add_hash_footer \
      --partition_name boot \
      --partition_size $((64 * 1024 * 1024)) \
      --image "$output" \
      --algorithm SHA256_RSA2048 \
      --key $BOOT_SIGN_KEY_PATH
  }

  tempdir=$(mktemp -d) && cd $tempdir
  cp $KERNEL_IMAGE .
  gzip -n -f -9 -c Image > Image.gz
  lz4 -l -12 --favor-decSpeed Image Image.lz4

  log "Downloading ramdisk..."
  wget -qO gki.zip https://dl.google.com/android/gki/gki-certified-boot-android15-6.6-2025-05_r2.zip
  unzip -q gki.zip && rm gki.zip
  $UNPACK_BOOTIMG --boot_img=boot-6.6.img && rm boot-6.6.img

  for format in raw lz4 gz; do
    kernel="./Image"
    [[ $format != "raw" ]] && kernel+=".$format"

    _output="${BOOTIMG_NAME/dummy1/$format}"
    generate_bootimg "$kernel" "$_output"

    mv "$_output" $WORKDIR
  done
  cd $WORKDIR
fi

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
  mkdir -p $WORKDIR/artifacts
  mv $WORKDIR/*.zip $WORKDIR/*.img $WORKDIR/artifacts
fi

if [[ $LAST_BUILD == "true" && $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/raw/gki-android15-6.6/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
  ) >> $WORKDIR/artifacts/info.txt
fi

if [[ $STATUS == "BETA" ]]; then
  reply_file "$MESSAGE_ID" "$WORKDIR/$AK3_ZIP_NAME"
  reply_file "$MESSAGE_ID" "$WORKDIR/$KERNEL_IMAGE_ZIP_NAME"
  # reply_file "$MESSAGE_ID" "$WORKDIR/$KERNEL_MODULES_ARCHIVE_NAME"
  reply_file "$MESSAGE_ID" "$WORKDIR/$SYSTEM_DLKM_IMAGE_ZIP_NAME"
  reply_file "$MESSAGE_ID" "$WORKDIR/build.log"
else
  reply_msg "$MESSAGE_ID" "✅ Build Succeeded"
fi

exit 0
