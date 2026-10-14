# 上游与许可证

本项目是 Squirrel 的修改版本，保留其原作者声明和许可。仓库根 LICENSE 为上游 GPL-3.0；独立 MIT / LGPL / BSD 文件继续按自身许可提供，不能把整个衍生输入法统一宣称为 MIT。

| 组件 / 文件范围 | 来源与许可 |
| --- | --- |
| Squirrel 前端、原资源与工程 | [rime/squirrel](https://github.com/rime/squirrel)，基线提交 `0cd71a6130a5866b0ae6ba0494929ebdc8211194`；GPL-3.0，见 `enhanced-squirrel/LICENSE.txt` |
| 独立增强模块 | `enhanced-squirrel/Enhancements/LICENSE`，MIT |
| Lua 选词、增量配置、项目工具和测试的原 MIT 部分 | `lua/LICENSE`、`config/LICENSE`、`tools/LICENSE`、`tests/LICENSE`；第三方派生内容按原许可 |
| librime API / 键定义头文件 | [rime/librime](https://github.com/rime/librime)，BSD 3-Clause；见 `enhanced-squirrel/librime/LICENSE` 与各头文件原声明 |
| X11 键定义头文件 | 各文件内保留原 X.Org / X Consortium 声明 |
| Plum 配方工具 | [rime/plum](https://github.com/rime/plum)，LGPL-3.0；见 `enhanced-squirrel/plum/LICENSE`，GPL 完整文本亦在根 LICENSE |
| 默认 Quick5 资源 | [rime/rime-quick](https://github.com/rime/rime-quick)，提交 `5dcdb9e353d314239e9c8cddc0f42d52da4837bb`；LGPL-3.0，LICENSE / AUTHORS / GPL-3.0.txt / UPSTREAM.json 保留在资源目录 |
| 公开增强拼音词库 | [iDvel/rime-ice](https://github.com/iDvel/rime-ice/tree/da1fbe602e38f26db846fa10120ee64c2b0324c0)，提交 `da1fbe602e38f26db846fa10120ee64c2b0324c0`；GPL-3.0-only，五张原始公开词表、来源注释、LICENSE 与 UPSTREAM.json 见 `resources/PublicPinyin`。腾讯词表原始数据来自 Tencent AI Lab；保留文件内原始来源及校订声明 |
| 公开词库的朙月拼音方案 | [rime/rime-luna-pinyin](https://github.com/rime/rime-luna-pinyin/tree/56b934b099dfbeab842320f13aa8b461a6ab3e42)，提交 `56b934b099dfbeab842320f13aa8b461a6ab3e42`；LGPL-3.0，修改默认词典与简繁过滤器，LICENSE / AUTHORS 保留 |
| Sparkle 构建依赖 | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) 2.6.2；许可见 `enhanced-squirrel/third-party/Sparkle-LICENSE.txt` |

Git 代码区不包含第三方预编译运行库。Releases 的安装包包含运行所需的 librime、插件、OpenCC、Sparkle 与公开默认词库，程序的 Resources/Licenses 和 SharedSupport 目录保留对应许可证与作者声明。构建时使用的签名工具不随安装包分发。开发者再次分发构建产物时须保留对应声明并检查其来源。

公共默认外观沿用原配色作者声明；这些上游署名不是本机用户信息。千问、豆包及平台名称用于说明可配置的服务接口，不表示官方授权或背书。
