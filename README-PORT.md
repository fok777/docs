# docs — SukiSU + SUSFS v2.3.0

- **底包**: `Prslc-Team/kernel_xiaomi_sm8250` (main, 4.19.325, sm8250)
- **KSU**: `xiziya/SukiSU_Non-GKI@builtin`（SukiSU-Ultra builtin 的 Non-GKI 移植）
- **SUSFS**: v2.3.0（官方补丁 + inline hook 脚本）

## 构建

Actions → **Build Kernel** → Run workflow，默认值即可：

| 项 | 默认 |
|---|---|
| device | `alioth` |
| system | `miui` |
| KSU | `sukisu` |

## 脚本与流程的分工

一开始把 Fraud 17 的 `build_kernel.sh` 整套接过来用，方向是错的 ——
那套脚本是照着 Fraud 自己的源码写的，跟 Prslc 对不上。现在改成：

**骨架用 Prslc 原版脚本**（config 注入、MIUI 的 DTS sed 全集、AnyKernel3 liyafe1997、12 机型），
**流程层按 Fraud 17 升级**（与源码耦合低，可以安全换）：

| 项 | Prslc 原版 | 现在 |
|---|---|---|
| 工具链 | proton-clang（已停更）+ `CLANG_TRIPLE` | ZyC-Clang 16 + `LLVM=1 LLVM_IAS=1` |
| Actions | checkout@**v4** / cache@**v4** / upload@**v4** | **v7** / **v6** / **v7** |
| 配置收尾 | 无 | `olddefconfig`（否则 syncconfig 追问到 EOF） |
| workflow / build.sh | 两份重复逻辑 | workflow 只备环境，构建全交给 `build_kernel.sh` |

### alioth 特判（MIUI 构建时生效）

来自 Fraud 17，两处都保留：

```bash
sed -E -i "s/^(SUBLEVEL...)/\1157/" Makefile      # 版本伪装 4.19.157
KBUILD_BUILD_USER="builder"
KBUILD_BUILD_HOST="pangu-build-component-vendor-727090-8pdx4-w2b4x-lb74b"
KBUILD_BUILD_TIMESTAMP="Wed Oct 29 11:41:46 UTC 2025"
```

## 小米配置用 Prslc 的，不用 Fraud 的

millet（小米冻结框架）两边是**不同代源码**：

| | Prslc | Fraud 17 |
|---|---|---|
| 路径 | `drivers/xiaomi/` | `drivers/mihw/millet/` |
| Kconfig | `MILLET` **单开关** | `MILLET_{CGROUP,SIG,BINDER,PKG,BINDER_GKI,CORE,HS}` **7 子项** |

Fraud 注入的 7 个 `MILLET_*` 在 Prslc 源码里**一个都不存在**，照抄是空转
（`scripts/config` 对不存在的项不报错）。`REKERNEL` 同理 —— Prslc 完全没有这个模块。

所以 MIUI 配置段以 Prslc 为准。

## SUSFS 落地步骤

```
Bin/clean_hook.sh                        # 1. 清掉出厂的旧代 KSU 钩子
Patches/Patch/susfs_patch_to_4.19.patch  # 2. SUSFS v2.3.0 内核侧
Patches/susfs_inline_hook_patches.sh     # 3. KSU 钩子(v2.3.00+)
```

第 1 步不可省略：`susfs_inline_hook_patches.sh` 开头会 `grep -q "ksu_handle"`，
**文件里已有 `ksu_handle` 就跳过**。Prslc 出厂自带 7 个旧代钩子，不清掉脚本会全部跳过。

### 手工补的一处

`ksu_handle_setresuid`（`kernel/sys.c`）官方补丁不带 —— 脚本靠 `drivers/kernelsu/`
已存在才安装，而 KSU 源码是构建时才 clone 的，跑到那儿目录还不存在。
按 Fraud 17 的写法补进 `kernel/sys.c`。

### selinuxfs 去 static

`static_export_check.mk` 要求 `sel_handle_status_ops` 非 static，否则报
"You should integrate ReSukiSU"。已在 `security/selinux/selinuxfs.c` 去掉。

## 为什么用 xiziya 而不是 SukiSU-Ultra 官方

`kernel/non_gki/` 目录只有 xiziya 的 `builtin` 分支有，官方 `builtin`/`main`/`dev`
**全都没有**。我们是 4.19，官方分支的 SELinux hide 代码压根不会编译。

xiziya 的自述：基于 SukiSU Ultra `builtin` 提交
`b20dee702035af09cb2ecb5f35443bbc1747f3e6` 的增量兼容移植，兼容代码只在 `< 5.10` 时编译。

构建时会打印：

```
[+] Integration mode: Non-GKI SELinux compatibility layer (< 5.10).
CC  drivers/kernelsu/non_gki/selinux_hide.o
CC  drivers/kernelsu/non_gki/rules.o
CC  drivers/kernelsu/non_gki/sepolicy.o
CC  drivers/kernelsu/non_gki/symbol_resolver.o
CC  drivers/kernelsu/non_gki/patch_memory_arm64.o
```

这 5 个 .o 编出来 = 4.19 的 SELinux hide 真的生效了。

## 踩过的坑

1. **Prslc 的 `.gitignore` 有一行 `.*`** — `git add -A` 会跳过整个 `.github`，
   导入时 workflow 全丢。提交 `.github` 必须 `git add -f`。
2. **KSU_SUSFS depends on THREAD_INFO_IN_TASK** — 不开 THREAD_INFO_IN_TASK，
   Kconfig 会静默丢掉 KSU_SUSFS，编出"看着成功、实则没 SUSFS"的内核。
3. **`KSU_ENABLE` 判定漏了 `resukisu`** — Prslc 原版的判定只列了 rksu/sukisu-kpm/sukisu，
   选 resukisu 时 `KSU_ENABLE=0`，配置阶段走 `-d KSU`，编出来没有 root。已补。
4. **`cmd | tee` 吞掉退出码** — 没开 `pipefail` 时 `./build.sh | tee log` 的退出码是 tee 的
   （恒为 0），编译失败也被判成功。已加 `set -o pipefail`。
5. **Prslc 不生成 `arch/arm64/boot/dtb`** — Fraud 的底包自带这个产物，脚本里没生成步骤，
   照抄会 `cp: cannot stat`。
