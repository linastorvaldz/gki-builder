#!/usr/bin/env bash

# Constants
WORKDIR="$(pwd)"
if [ "$KVER" == "6.6" ]; then
  RELEASE="v0.3"
elif [ "$KVER" == "5.10" ]; then
  RELEASE="v0.2"
elif [ "$KVER" == "6.1" ]; then
  RELEASE="v0.1"
fi
KERNEL_NAME="qx"
USER="eraselk"
HOST="gacorprjkt"
TIMEZONE="Asia/Makassar"
ANYKERNEL_REPO="https://github.com/linastorvaldz/anykernel"
KERNEL_DEFCONFIG="quartix_defconfig"
if [ "$KVER" == "6.6" ]; then
  KERNEL_REPO="https://github.com/linastorvaldz/kernel-android15-6.6"
  ANYKERNEL_BRANCH="android15-6.6"
  KERNEL_BRANCH="android15-6.6-2025-01"
elif [ "$KVER" == "6.1" ]; then
  KERNEL_REPO="https://github.com/linastorvaldz/kernel-android14-6.1"
  ANYKERNEL_BRANCH="android14-6.1"
  KERNEL_BRANCH="android14-6.1-lts"
elif [ "$KVER" == "5.10" ]; then
  KERNEL_REPO="https://github.com/linastorvaldz/kernel-android12-5.10"
  ANYKERNEL_BRANCH="android12-5.10"
  KERNEL_BRANCH="master-new"
fi
DEFCONFIG_TO_MERGE=""
GKI_RELEASES_REPO="https://github.com/linastorvaldz/quartix-releases"
#CLANG_URL="https://github.com/linastorvaldz/idk/releases/download/clang-r547379/clang.tgz"
CLANG_URL="https://github.com/linastorvaldz/stuffs/releases/download/clang-r416183b/linux-x86-bd96dfe349c962681f0e5388af874c771ef96670-clang-r416183b.tar.gz"
CLANG_BRANCH=""
AK3_ZIP_NAME="AK3-$KERNEL_NAME-REL-KVER-VARIANT-BUILD_DATE.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"

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
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
cd $WORKDIR

# Set Kernel variant
log "Setting Kernel variant..."
case "$KSU" in
  "Next") VARIANT="KSUN" ;;
  "Biasa") VARIANT="KSU" ;;
  "Rissu") VARIANT="RKSU" ;;
  "None") VARIANT="NKSU" ;;
esac
susfs_included && VARIANT+="+SuSFS"

# Replace Placeholder in zip name
AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [ -z "$CLANG_BRANCH" ]; then
  log "🔽 Downloading Clang..."
  wget -qO clang-archive "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.* | *.tgz)
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

  if [ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ] \
    && [ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv $SINGLE_DIR/* $CLANG_DIR/
    rm -rf $SINGLE_DIR
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

# Clone GNU Assembler
log "Cloning GNU Assembler..."
GAS_DIR="$WORKDIR/gas"
git clone --depth=1 -q \
  https://android.googlesource.com/platform/prebuilts/gas/linux-x86 \
  -b main \
  "$GAS_DIR"

export PATH="${CLANG_BIN}:${GAS_DIR}:$PATH"

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd $KSRC

## KernelSU setup
if ksu_included; then
  # Remove existing KernelSU drivers
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU; do
    if [ -d $KSU_PATH ]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [ -f "$KSU_DIR/Kconfig" ] && sed -i '/kernelsu/d' $KSU_DIR/Kconfig
      [ -f "$KSU_DIR/Makefile" ] && sed -i '/kernelsu/d' $KSU_DIR/Makefile

      rm -rf $KSU_PATH
    fi
  done

  # Install kernelsu
  case "$KSU" in
    "Next") install_ksu $(susfs_included && echo 'pershoot/KernelSU-Next dev-susfs' || echo 'pershoot/KernelSU-Next dev-susfs') ;;
    "Biasa") install_ksu tiann/KernelSU main ;;
    "Rissu") install_ksu rsuntk/KernelSU $(susfs_included && echo susfs-rksu-master || echo main) ;;
  esac
  config --enable CONFIG_KSU
  config --disable CONFIG_KSU_MANUAL_SU
fi

# SUSFS
if susfs_included; then
  # Kernel-side
  log "Applying kernel-side susfs patches"
  SUSFS_DIR="$WORKDIR/susfs"
  SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"
  if [ "$KVER" == "6.6" ]; then
    SUSFS_BRANCH=gki-android15-6.6
  elif [ "$KVER" == "6.1" ]; then
    SUSFS_BRANCH=gki-android14-6.1
  elif [ "$KVER" == "5.10" ]; then
    SUSFS_BRANCH=gki-android12-5.10
  fi
  git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b $SUSFS_BRANCH $SUSFS_DIR
  cp -R $SUSFS_PATCHES/fs/* ./fs
  cp -R $SUSFS_PATCHES/include/* ./include
  patch -p1 < $SUSFS_PATCHES/50_add_susfs_in_${SUSFS_BRANCH}.patch || true
  if [ $LINUX_VERSION_CODE -eq 6630 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/namespace.c_fix.patch
    patch -p1 < $KERNEL_PATCHES/susfs/task_mmu.c_fix.patch
  elif [ $LINUX_VERSION_CODE -eq 6658 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/task_mmu.c_fix-k6.6.58.patch
  elif [ $(echo "$LINUX_VERSION_CODE" | head -c2) -eq 61 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/fs_proc_base.c-fix-k6.1.patch
  fi
  if [ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/fix-statfs-crc-mismatch-susfs.patch
  fi
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')

  # KernelSU-side
  if [ "$KSU" == "Next" ] || [ "$KSU" == "Biasa" ]; then
    log "Applying kernelsu-side susfs patches.."

    if false; then
      if [ "$KSU" == "Next" ]; then
        SUSFS_FIX_PATCHES="$PWD/kernel_patches/next/susfs_fix_patches/$SUSFS_VERSION"
        git clone --depth=1 -q https://github.com/WildKernels/kernel_patches $PWD/kernel_patches
        if [ ! -d "$SUSFS_FIX_PATCHES" ]; then
          error "susfs fix patches are not available for susfs $SUSFS_VERSION."
        fi
      fi
    fi

    if [ "$KSU" == "Next" ]; then
      if false; then
        cd KernelSU-Next
      fi
    elif [ "$KSU" == "Biasa" ]; then
      cd KernelSU
    fi

    if [ "$KSU" == "Next" ]; then
      if false; then
        patch -p1 < $SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch || true
      fi
    elif [ "$KSU" == "Biasa" ]; then
      patch -p1 < $SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch
    fi

    if false; then
      if [ "$KSU" == "Next" ]; then
        log "Applying the susfs fix patches..."
        # apply the fix patches
        for p in "$SUSFS_FIX_PATCHES"/*.patch; do
          patch -p1 --forward < $p
        done
        # cleanup .orig / .rej
        find . -type f \( -name '*.orig' -o -name '*.rej' \) -delete
      fi
    fi
    if ! [ "$KSU" == "Next" ]; then
      cd $OLDPWD
    fi
  fi
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

# Apply some kernelsu patches
if [ "$KSU" == "Rissu" ]; then
  cd KernelSU
  patch -p1 < "$KERNEL_PATCHES"/ksu/rksu-add-mambosu-manager-support.patch
  cd "$OLDPWD"
fi

# Manual Hooks
if ksu_manual_hook; then
  #  log "Applying manual hook patch"
  #  if [ "$KSU" == "Rissu" ]; then
  #    patch -p1 --forward < $KERNEL_PATCHES/hooks/manual-hook-v1.6.patch
  #  else
  #    patch -p1 --forward < $KERNEL_PATCHES/hooks/manual-hook-v1.4.patch
  #    patch -p1 --forward < $KERNEL_PATCHES/hooks/reboot-hook.patch
  #  fi
  #  config --enable CONFIG_KSU_MANUAL_HOOK
  #  config --disable CONFIG_KSU_KPROBES_HOOK
  #  config --disable CONFIG_KSU_SYSCALL_HOOK
  #  config --disable CONFIG_KSU_SUSFS_SUS_SU # Conflicts with manual hook
  : "DUMMY"
fi

# Enable KPM Supports for SukiSU
# if [ $KSU == "Suki" ]; then
#   config --enable CONFIG_KPM
# fi

# set localversion
if [ $TODO == "kernel" ]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  if [ $STATUS == "BETA" ]; then
    SUFFIX="$LATEST_COMMIT_HASH"
  else
    SUFFIX="${RELEASE}@${LATEST_COMMIT_HASH}"
  fi
  config --set-str CONFIG_LOCALVERSION "-$KERNEL_NAME/$SUFFIX"
  config --disable CONFIG_LOCALVERSION_AUTO
  sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(date)
export KCFLAGS="-w"
if [ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]; then
  MAKE_ARGS=(
    LLVM=1
    ARCH=arm64
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    -j$(nproc --all)
    O=$OUTDIR
  )
else
  MAKE_ARGS=(
    LLVM=1
    LLVM_IAS=1
    ARCH=arm64
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    -j$(nproc --all)
    O=$OUTDIR
  )
fi

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
if [ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]; then
  KMI_CHECK="$WORKDIR/py/kmi-check-6.x.py"
else
  KMI_CHECK="$WORKDIR/py/kmi-check-5.x.py"
fi

text=$(
  cat << EOF
🐧 *Linux Version*: $LINUX_VERSION
📅 *Build Date*: $KBUILD_BUILD_TIMESTAMP
📛 *KernelSU*: ${KSU}
ඞ *SuSFS*: $(susfs_included && echo "$SUSFS_VERSION" || echo "None")
🔰 *Compiler*: $COMPILER_STRING
EOF
)

## Build GKI
log "Generating config..."
make ${MAKE_ARGS[@]} $KERNEL_DEFCONFIG

if [ "$DEFCONFIG_TO_MERGE" ]; then
  log "Merging configs..."
  if [ -f "scripts/kconfig/merge_config.sh" ]; then
    for config in $DEFCONFIG_TO_MERGE; do
      make ${MAKE_ARGS[@]} scripts/kconfig/merge_config.sh $config
    done
  else
    error "scripts/kconfig/merge_config.sh does not exist in the kernel source"
  fi
  make ${MAKE_ARGS[@]} olddefconfig
fi

# Upload defconfig if we are doing defconfig
if [ $TODO == "defconfig" ]; then
  log "Uploading defconfig..."
  upload_file $OUTDIR/.config
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make ${MAKE_ARGS[@]}

# Check KMI Function symbol
if [ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]; then
  $KMI_CHECK "$KSRC/android/abi_gki_aarch64.stg" "$MODULE_SYMVERS" || true
else
  $KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS" || true
fi

## Post-compiling stuff
cd $WORKDIR

# Patch the kernel Image for KPM Supports
#if [ $KSU == "Suki" ]; then
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
if [ $STATUS == "BETA" ]; then
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
zip -r9 $WORKDIR/$AK3_ZIP_NAME ./*
cd $OLDPWD

if [ $STATUS != "BETA" ]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
  mkdir -p $WORKDIR/artifacts
  mv $WORKDIR/*.zip $WORKDIR/artifacts
fi

if [ $LAST_BUILD == "true" ] && [ $STATUS != "BETA" ]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/raw/gki-android15-6.6/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
  ) >> $WORKDIR/artifacts/info.txt
fi

if [ $STATUS == "BETA" ]; then
  upload_file "$WORKDIR/$AK3_ZIP_NAME" "$text"
  upload_file "$WORKDIR/build.log"
else
  send_msg "✅ Build Succeeded for $VARIANT variant."
fi

exit 0
