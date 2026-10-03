#!/bin/bash

# This build script references and adapts logic from:
# - [scripts/build_kernel] by UtsavBalar1231
# - [build.sh] by liyafe1997
# - [.github/workflows/Build_Kernel.yml] by yspbwx2010
# Many thanks to their authors for the inspiration.

set -e

TOOLCHAIN_PATH=${TOOLCHAIN_PATH:-$HOME/zyc-clang/bin}
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided. Check the README (Build section)."
    exit 1
fi

if [ ! -d "$TOOLCHAIN_PATH" ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

# LLVM=1 时由 clang/lld 承担链接,不需要 GNU 交叉 binutils。
for cmd in clang; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[$cmd] does not exist, please check your environment."
        exit 1
    fi
done

if [ -d KernelSU ]; then
    echo "[-] clean KernelSU..."
    bash KernelSU/kernel/setup.sh --cleanup
fi

# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"

# LLVM=1 / LLVM_IAS=1 走 clang 整套工具链(clang 负责汇编,不用 GNU as)。
# 这是 Fraud 17 的写法;Prslc 原版的 CC=clang + CLANG_TRIPLE 是老式配法,
# 配合新版 clang 容易在汇编阶段出问题。
# 必须用数组:写成字符串后 `make "${MAKE_ARGS[@]}"` 会做 word splitting,
# "CC=ccache clang" 被拆成 CC=ccache 和 clang,后者变成 target ——
# 报 "target 'clang' given more than once in the same rule"。
MAKE_ARGS=(
    ARCH=arm64
    SUBARCH=arm64
    O=out
    LLVM=1
    LLVM_IAS=1
    CC="ccache clang"
    HOSTCC="ccache clang"
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)

if [ "$1" == "j1" ]; then
    make "${MAKE_ARGS[@]}" -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make "${MAKE_ARGS[@]}" -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Available defconfigs, please choose one target from below:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi

echo "[clang --version]:"
clang --version

# Initialize variables
KERNEL_SRC=$(pwd)
KPM_ENABLE=0
KSU_VERSION=$2
TARGET_SYSTEM=$3

echo "TARGET_DEVICE: $TARGET_DEVICE"
KSU_ENABLE=$([[ "$KSU_VERSION" == "rksu" || "$KSU_VERSION" == "sukisu-kpm" || "$KSU_VERSION" == "sukisu" || "$KSU_VERSION" == "resukisu" ]] && echo 1 || echo 0)

# KernelSU setup
case "$KSU_VERSION" in
    rksu)
        KSU_ZIP_STR=RKSU
        echo "RKSU is enabled"
        curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s main
        ;;
    sukisu)
        KSU_ZIP_STR=SukiSU-SuSFS
        echo "SukiSU is enabled"
        curl -LSs https://raw.githubusercontent.com/xiziya/SukiSU_Non-GKI/builtin/kernel/setup.sh | sh
        ;;
    sukisu-kpm)
        KPM_ENABLE=1
        KSU_ZIP_STR=SukiSU-KPM
        echo "SukiSU & KPM is enabled"
        curl -LSs https://raw.githubusercontent.com/xiziya/SukiSU_Non-GKI/builtin/kernel/setup.sh | sh
        ;;
    resukisu)
        KSU_ZIP_STR=ReSukiSU-SuSFS
        echo "ReSukiSU is enabled"
        curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
        ;;
    *)
        KSU_ZIP_STR=NoKernelSU
        echo "KSU is disabled"
        ;;
esac

echo "Cleaning..."
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/liyafe1997/AnyKernel3)"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

Build_AOSP() {
    echo "Building for AOSP......"
    make "${MAKE_ARGS[@]}" ${TARGET_DEVICE}_defconfig
    SET_CONFIG
    make "${MAKE_ARGS[@]}" -j$(nproc)
    Image_Repack
    echo "Build for AOSP finished."
}

Build_MIUI(){
    echo "Clearning [out/] and build for MIUI....."
    rm -rf out/

    dts_source=arch/arm64/boot/dts/vendor/qcom

    # Backup dts
    cp -a ${dts_source} .dts.bak

    # Correct panel dimensions on MIUI builds
    sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
    sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
    sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
    sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
    sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

    # Enable back mi smartfps while disabling qsync min refresh-rate
    sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
    sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
    sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
    sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

    # Enable back refresh rates supported on MIUI
    sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
    sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
    sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
    sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

    # Enable back brightness control from dtsi
    sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

    # alioth 特判:伪装构建身份与内核版本(来自 Fraud 17)
    if [ "$TARGET_DEVICE" = "alioth" ]; then
        echo "[*] alioth: applying build identity & version spoof..."
        sed -E -i "s/^(SUBLEVEL[[:space:]]*=[[:space:]]*).*/\\1157/" Makefile || true
        export KBUILD_BUILD_USER="builder"
        export KBUILD_BUILD_HOST="pangu-build-component-vendor-727090-8pdx4-w2b4x-lb74b"
        export KBUILD_BUILD_TIMESTAMP="Wed Oct 29 11:41:46 UTC 2025"
        export KBUILD_BUILD_VERSION=1
    fi

    make "${MAKE_ARGS[@]}" ${TARGET_DEVICE}_defconfig

    SET_CONFIG MIUI

    make "${MAKE_ARGS[@]}" -j$(nproc)

    Image_Repack MIUI
}

SET_CONFIG() {
    if [ "$1" == "MIUI" ]; then
        scripts/config --file out/.config \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -d DEBUG_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e MILLET \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -d LOCALVERSION_AUTO \
            -e SF_BINDER \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -d MODULE_SIG_SHA512 \
            -d MODULE_SIG_HASH \
            -e MI_FRAGMENTION \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM
    fi

    if [ "$KSU_ENABLE" -eq 1 ]; then
        # THREAD_INFO_IN_TASK 必须开:KSU_SUSFS 依赖它,
        # 不开的话 Kconfig 会静默丢掉 KSU_SUSFS,编出一个"看着成功、实则没 SUSFS"的内核。
        scripts/config --file out/.config \
            -e KSU \
            -e THREAD_INFO_IN_TASK \
            -e KSU_SUSFS
    else
        scripts/config --file out/.config \
            -d KSU \
            -d KSU_SUSFS
    fi

    # Config KPM
    if [ "$KPM_ENABLE" -eq 1 ]; then
        scripts/config --file out/.config \
            -e KPM \
            -e KALLSYMS \
            -e KALLSYMS_ALL
    fi

    # 收尾:让新注入的符号真正落盘。
    # CI 里若直接 make,syncconfig 会对新符号追问到 EOF,KSU/KSU_SUSFS 会被静默丢掉。
    make "${MAKE_ARGS[@]}" olddefconfig
}

Image_Repack() {
    if [ -f "out/arch/arm64/boot/Image" ]; then
        echo "The file [out/arch/arm64/boot/Image] exists. Build successfully."
    else
        echo "The file [out/arch/arm64/boot/Image] does not exist. Seems build failed."
        exit 1
    fi

    # KPM Patch
    if [[ "$KPM_ENABLE" -eq 1 && "$KSU_VERSION" == "sukisu-ultra" ]]; then
        Patch_KPM
    fi

    echo "Generating [out/arch/arm64/boot/dtb]......"
    find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

    # Restore modified dts
    if [ "$1" == "MIUI" ]; then
        rm -rf ${dts_source}
        mv .dts.bak ${dts_source}
    fi

    rm -rf anykernel/kernels/
    mkdir -p anykernel/kernels/
    cp out/arch/arm64/boot/Image anykernel/kernels/
    cp out/arch/arm64/boot/dtb anykernel/kernels/
    cd anykernel

    if [ "$1" == "MIUI" ]; then
        ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
    else
        ZIP_FILENAME=Kernel_AOSP_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
    fi

    zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
    mv $ZIP_FILENAME ../
    cd ..
    echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
}

Patch_KPM() {
    cd out/arch/arm64/boot
    curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU_patch/refs/heads/main/kpm/patch_linux" -o patch
    chmod +x patch
    ./patch

    if [ $? -eq 0 ]; then
        rm -f Image
        mv oImage Image
        echo "Image file repair complete"
    else
        echo "KPM Patch Failed, Use Original Image"
    fi

    cd $KERNEL_SRC
}

if [ "$TARGET_SYSTEM" == "aosp" ]; then
    Build_AOSP
elif [ "$TARGET_SYSTEM" == "miui" ]; then
    Build_MIUI
else
    Build_AOSP
    Build_MIUI
fi
