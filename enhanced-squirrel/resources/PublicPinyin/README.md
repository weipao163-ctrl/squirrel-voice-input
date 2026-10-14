# 公开增强拼音词库

默认 `luna_pinyin` 方案使用雾凇拼音的常用字、基础、扩展、腾讯扩展及杂项词库；共 1,873,509 条源记录，含多音与重复读音，并非去重词数。来源是 `iDvel/rime-ice` 公开仓库的固定提交 `da1fbe602e38f26db846fa10120ee64c2b0324c0`，五张源词表保持原始字节和词频。项目发布的 GPL-3.0-only 许可、原始来源注释及每文件 SHA-256 一并保留。

这不是搜狗的默认系统词库。搜狗官网区分内置系统词库和个性化用户词库，公开页面提供网友创建的细胞词库；本次没有取得可公开再分发的完整默认系统词库，故采用可核验的公开 Rime 词库来改善日常输入。

- [搜狗对系统/用户词库的说明](https://pinyin.sogou.com/help.php?list=6&q=4)
- [搜狗细胞词库下载页](https://pinyin.sogou.com/dict/)
- [雾凇拼音词库与许可证](https://github.com/iDvel/rime-ice/tree/da1fbe602e38f26db846fa10120ee64c2b0324c0)

`UPSTREAM.json` 记录来源、许可、原始哈希、打包映射与源记录数。`dictionaries/` 仅含下载自该固定公开提交的五张词表；不读取或合并安装机器的任何个人词库、学习记录、短语、Key 或设置。导入命名空间为 `squirrel_public_pinyin/`，与用户的 `cn_dicts/` 分开。

朙月拼音方案来自 `rime/rime-luna-pinyin` 的固定提交 `56b934b099dfbeab842320f13aa8b461a6ab3e42`。保留其作者与 LGPL 许可，修改默认 `translator/dictionary`、明确 `user_dict: luna_pinyin`，并适配简体源词表的繁体转换。保留同一方案与学习库标识，不改用户自定义方案或用户词库；如用户补丁显式指定了另一套词库，该补丁继续生效。

构建调用 `tools/bundle_public_pinyin.py` 验证全部哈希后复制声明文件，并用 `tools/prebuild_public_pinyin.py` 在新建隔离目录中预编译公开词表。只复制该词表的 table/prism/reverse 三个产物，附 `PublicPinyin-PREBUILT.json` 来源绑定；不复制生成目录里的学习库、日志或状态文件。安装包保留可再次构建的公开源词表，构建过程不读取本机 Rime 用户目录。
