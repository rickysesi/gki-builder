#!/usr/bin/env bash

# Constants
WORKDIR="$(pwd)"
if [ "$KVER" == "6.6" ]; then
  RELEASE="v0.3"
elif [ "$KVER" == "5.10" ]; then
  RELEASE="v0.3"
elif [ "$KVER" == "6.1" ]; then
  RELEASE="v0.1"
fi
KERNEL_NAME="VictoriaVDeFalsa-GKI"
USER="Victor"
HOST="VictoriaVDeFalsa"
TIMEZONE="Asia/Jakarta"
ANYKERNEL_REPO="https://github.com/linastorvaldz/anykernel"
KERNEL_DEFCONFIG="gki_defconfig"
if [ "$KVER" == "6.6" ]; then
  KERNEL_REPO="https://github.com/rickysesi/android_kernel_xiaomi_sm8635"
  ANYKERNEL_BRANCH=""
  KERNEL_BRANCH="6.6.77-capybara-clo-2.3"
elif [ "$KVER" == "6.1" ]; then
  KERNEL_REPO="https://github.com/rickysesi/kernel_xiaomi_peridot"
  ANYKERNEL_BRANCH="android14-6.1"
  KERNEL_BRANCH="peridot-u-oss"

elif [ "$KVER" == "5.10" ]; then
  KERNEL_REPO="https://github.com/ramabondanp/android_kernel_common-5.10.git"
  ANYKERNEL_BRANCH="android12-5.10"
  KERNEL_BRANCH="android12-5.10-staging"
fi
DEFCONFIG_TO_MERGE=""
GKI_RELEASES_REPO="https://github.com/rickysesi/gki-builder/releases/"
#CLANG_URL="https://github.com/linastorvaldz/idk/releases/download/clang-r547379/clang.tgz"
#CLANG_URL="https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b/archive/refs/heads/lineage-20.0.tar.gz"
CLANG_URL="$(./clang.sh slim)"
CLANG_BRANCH=""
AK3_ZIP_NAME="$KERNEL_NAME-REL-KVER-VARIANT-BUILD_DATE.zip"
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

# --- PATCH 500HZ (INSTALLED AT THE BEGINNING) ---
log "Applying 500Hz patch..."
wget -qO Inject_500hz.sh https://raw.githubusercontent.com/Kingfinik98/gki-builder/refs/heads/6.x/inject_ksu/Inject_500hz.sh
bash Inject_500hz.sh
rm Inject_500hz.sh
# --------------------------------------

# --- ADD KSU INJECT SCRIPT ---
log "Injecting custom KSU & SuSFS configs from GitHub..."
export KSU
export KSU_SUSFS
wget -qO inject.sh https://raw.githubusercontent.com/Kingfinik98/gki-builder/refs/heads/6.x/inject_ksu/gki_defconfig.sh
bash inject.sh
rm inject.sh
# --------------------------------------
cd $WORKDIR

# Set Kernel variant
log "Setting Kernel variant..."
case "$KSU" in
  "yes") VARIANT="KSU" ;;
  "no") VARIANT="VNL" ;;
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
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU KernelSU-Next; do
    if [ -d $KSU_PATH ]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [ -f "$KSU_DIR/Kconfig" ] && sed -i '/kernelsu/d' $KSU_DIR/Kconfig
      [ -f "$KSU_DIR/Makefile" ] && sed -i '/kernelsu/d' $KSU_DIR/Makefile

      rm -rf $KSU_PATH
    fi
  done

  install_ksu 'pershoot/KernelSU-Next' 'dev-susfs'
  config --enable CONFIG_KSU

  cd KernelSU-Next
  patch -p1 < $KERNEL_PATCHES/ksu/ksun-add-more-managers-support.patch
  cd $OLDPWD
    # Fix SUSFS Uname Symbol Error for KernelSU Next & All_Manager
    log "Applying fix for undefined SUSFS symbols (KernelSU-Next)..."
    # Disable SUSFS Uname handling block in supercalls.c to use standard kernel spoofing
    # This fixes the linker error caused by missing functions in the current SUSFS patch
    sed -i 's/#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME/#if 0 \/\* CONFIG_KSU_SUSFS_SPOOF_UNAME Disabled to fix build \*\//' drivers/kernelsu/supercalls.c
    log "SUSFS symbol fix applied for KernelSU-Next."
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
  if [ $(echo "$LINUX_VERSION_CODE" | head -c4) -eq 6630 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/namespace.c_fix.patch
    patch -p1 < $KERNEL_PATCHES/susfs/task_mmu.c_fix.patch
  elif [ $(echo "$LINUX_VERSION_CODE" | head -c4) -eq 6658 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/task_mmu.c_fix-k6.6.58.patch
  elif [ $(echo "$LINUX_VERSION_CODE" | head -c2) -eq 61 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/fs_proc_base.c-fix-k6.1.patch
  elif [ $(echo "$LINUX_VERSION_CODE" | head -c3) -eq 510 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/pershoot-susfs-k5.10.patch
  fi
  if [ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]; then
    patch -p1 < $KERNEL_PATCHES/susfs/fix-statfs-crc-mismatch-susfs.patch
  fi
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

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

# =====================================================
# AnyKernel packaging & artifact handling (FINAL)
# =====================================================

# Safety defaults (CI-safe, no unary operator errors)
STATUS="${STATUS:-BETA}"
KSU="${KSU:-no}"
LAST_BUILD="${LAST_BUILD:-false}"

# Resolve VARIANT (SukiSU aware)
case "$KSU" in
  "yes") VARIANT="SukiSU" ;;
  "no")  VARIANT="VNL" ;;
  *)     VARIANT="VNL" ;;
esac

# Append SuSFS flag if enabled
if susfs_included; then
  VARIANT+="+SuSFS"
fi

log "Packaging kernel (STATUS=$STATUS | VARIANT=$VARIANT)"

# -----------------------------------------------------
# Prepare AnyKernel (idempotent, CI-safe)
# -----------------------------------------------------
rm -rf "$WORKDIR/anykernel"

log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 "$ANYKERNEL_REPO" -b "$ANYKERNEL_BRANCH" anykernel \
  || error "Failed to clone AnyKernel"

# -----------------------------------------------------
# Set kernel string
# -----------------------------------------------------
if [[ "$STATUS" == "BETA" ]]; then
  BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
  AK3_ZIP_NAME=${AK3_ZIP_NAME//BUILD_DATE/$BUILD_DATE}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-REL/}

  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${LINUX_VERSION} (${BUILD_DATE}) ${VARIANT}/g" \
    "$WORKDIR/anykernel/anykernel.sh"
else
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-BUILD_DATE/}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}

  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT}/g" \
    "$WORKDIR/anykernel/anykernel.sh"
fi

# -----------------------------------------------------
# Zip AnyKernel
# -----------------------------------------------------
cd "$WORKDIR/anykernel" || error "anykernel directory missing"

log "Zipping AnyKernel package..."
if [[ ! -f "$KERNEL_IMAGE" ]]; then
  error "Kernel Image not found: $KERNEL_IMAGE"
fi

cp "$KERNEL_IMAGE" . || error "Failed to copy kernel image"
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./* || error "Failed to create AnyKernel zip"

cd "$WORKDIR" || exit 1

# -----------------------------------------------------
# Prepare artifacts (ALWAYS)
# -----------------------------------------------------
mkdir -p "$WORKDIR/artifacts"

if [[ -f "$WORKDIR/$AK3_ZIP_NAME" ]]; then
  mv "$WORKDIR/$AK3_ZIP_NAME" "$WORKDIR/artifacts/"
else
  error "Zip file missing after build: $AK3_ZIP_NAME"
fi

# -----------------------------------------------------
# Optional release info
# -----------------------------------------------------
if [[ "$LAST_BUILD" == "true" && "$STATUS" != "BETA" ]]; then
  {
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "VARIANT=$VARIANT"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
  } >> "$WORKDIR/artifacts/info.txt"
fi

# -----------------------------------------------------
# Upload / Notify
# -----------------------------------------------------
if [[ "$STATUS" == "BETA" ]]; then
  upload_file "$WORKDIR/artifacts/$AK3_ZIP_NAME" "$text"
  upload_file "$WORKDIR/build.log"
else
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "$GITHUB_ENV"
  send_msg "✅ Build Succeeded for $VARIANT variant."
fi

log "Build completed successfully."

exit 0
