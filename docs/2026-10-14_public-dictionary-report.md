# 0.1.28：公开默认词库升级

默认朙月拼音接入来源明确的简体公开词库，保留相同方案和学习库标识。输入法的字母选词、数字混输、光标提交通道及个人数据保护继续有效。App/Helper 0.1.28，完整安装包 0.1.20261014.4，适用于 Apple Silicon 与 macOS 13+。

## 词库选择与来源

搜狗官网将默认基础词库区分为内置系统词库和个性化用户词库，其公开细胞词库页面收录网友创建的扩展词库。本次未取得能够确认公开再分发范围的完整搜狗系统词库，不能将网上可下载的第三方词表称为“搜狗官方默认词库”。本版采用雾凇拼音公开字词表，来源为固定版本的 `iDvel/rime-ice`。

- [搜狗基础词库说明](https://pinyin.sogou.com/help.php?list=6&q=4)与[公开细胞词库页面](https://pinyin.sogou.com/dict/)。
- [雾凇拼音固定版本与许可证](https://github.com/iDvel/rime-ice/tree/da1fbe602e38f26db846fa10120ee64c2b0324c0)，GPL-3.0-only。
- [朙月拼音固定方案版本](https://github.com/rime/rime-luna-pinyin/tree/56b934b099dfbeab842320f13aa8b461a6ab3e42)，LGPL-3.0；保留作者与许可，调整词典及简繁过滤器。

| 原始公开词表 | 源记录数 |
| --- | ---: |
| 常用字 8105 | 8,757 |
| base 基础词表 | 543,118 |
| ext 扩展词表 | 339,186 |
| tencent 扩展词表 | 981,543 |
| others 杂项 | 905 |
| 合计 | 1,873,509 |

源记录包括多音及重复读音，不等于去重后的词数。五张词表保持公开上游的原始字节和词频，未混入本机词条；原始注释内的各数据来源与校订声明保留。每文件哈希与打包映射在 `enhanced-squirrel/resources/PublicPinyin/UPSTREAM.json`。

## 集成与数据保护

P-1：公开固定提交 → 哈希核验 → `squirrel_public_pinyin/` 命名空间 → 默认朙月拼音的翻译器 → 真实 Rime 候选与提交（E-1/F-1）。继续使用 `schema_id: luna_pinyin` 和 `user_dict: luna_pinyin`。安装只更新程序，不覆盖个人词库、学习数据和设置；用户自定义方案或显式的词典覆盖继续生效。

P-2：同一公开源码 → 新建空白数据目录预编译 → 只复制公开词表 table/prism/reverse 三个文件 → 哈希及源码绑定 → 签名 → Installer 实际解包核验（E-2/F-2）。预编译过程不读取任何系统或本机用户 Rime 数据，不复制测试目录的学习库、状态文件或日志。包内保留公开原始词表，便于后续重新构建。

`tools/check_public_source.py` 仍拒绝任意未声明词典、个人目录、学习库、设置、录音、凭据与私钥；大文件豁免仅针对明确声明且哈希核验的公开词表。包内资源另用 `verify_bundle` 精确核对；增加公开词库并不取消个人数据排除规则。

## Evidence 与结果

| Evidence | Finding | 复验路径与结果 |
| --- | --- | --- |
| E-1：真实 Rime、隔离用户目录 | F-1：默认方案已实际使用新词库，而非仅带入未引用文件 | 31 项检查通过；含词典配置、学习库标识、简体/繁体、空格展开、字母上屏、全部数字在隐藏/展开时正常输入及混合字符串 |
| E-2：实际构建与签名前预编译 | F-2：公开预编译数据与源码绑定 | 包内 `PublicPinyin-PREBUILT.json` 记录固定来源与三项编译文件哈希；新建用户目录可以部署及使用全部六个默认方案 |
| E-3：相同固定 40 个公开查询 | F-3：固定样本首屏命中略有增加，不能代表整体质量 | 原默认词库 38/40，新词库 39/40；“智能体”由首屏未命中变为首选，“自主开模”在两版都未命中 |
| E-4：发布边界负对照 | F-4：公开目录也不能夹带个人词典 | 11 项边界测试通过，包含篡改公开词表、加入个人词典、暂存区留有秘密、签名私钥和二进制等负对照 |

预编译后的新建目录部署单轮约 6.9 秒；同一脚本未预编译的开发版本约 11.7 秒。包含其他五个默认方案的部署，且非独立重复性能基准；不将它解释为实际打字延迟或整机 CPU 提升。公开词库扩大后文件和映射规模增加，不能承诺总内存低于旧小词库；运行时可复用编译结果，没有在线词库查询。

复验入口（需要已构建的 App；路径替换为自己的绝对路径）：

```bash
python3 tools/run_public_pinyin_probe.py --shared /path/to/SquirrelEnhancedDev.app/Contents/SharedSupport --library /path/to/SquirrelEnhancedDev.app/Contents/Frameworks/librime.1.dylib
python3 tests/test_public_source.py
python3 tools/check_public_source.py
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

所有原始报告保留在被忽略的 `evidence/`，不公开本机路径和诊断日志。本轮没有采音、读取 API Key 或调用云识别。候选位置修复及之前的核心/语音回归见[定位与源码复查报告](2026-10-14_fix-candidate-position-report.md)。

## 使用范围

默认朙月拼音直接使用本次公开词库；如现有用户选择自定义方案，或其补丁明确指定其他词库，不会自动更换那些个人配置。新电脑需要自行填写语音凭据和授权。首次安装仍需在系统「隐私与安全」中允许；本机证书签名不能代替 Apple Developer ID 签名与公证。具体步骤见[安装说明](INSTALLATION.md)。

E-1/E-3 最终原始报告 SHA-256：`ce2b83b81d7a55e81d346609e92c33222beb82d39a1021cc469ffc6288c95658`。
