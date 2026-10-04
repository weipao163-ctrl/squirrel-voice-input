# 原生输入法工程

当前代码基于 Squirrel 的 GPL-3.0 工程，增强模块保留其 MIT 许可证。公共说明、构建、隐私和验证范围从 [仓库 README](../README.md) 进入。

使用 `../scripts/prepare-dependencies.sh` 准备公开依赖，再运行 `ENHANCEMENT_LOCAL_SIGNING=1 bash scripts/build-clt.sh`。构建不安装或切换输入法；安装需单独使用 `scripts/install-dev.sh`。不要提交生成的 `build/`、私钥或用户数据。
