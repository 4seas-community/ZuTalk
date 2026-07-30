# build/ — 所有构建产物的唯一出口

本目录存放 **正在使用** 的构建产物。不入 git。运行 `just clean` 或手动 `rm -rf build/dmg build/app` 可全部清理。

## 结构

```
build/
├── README.md     ← 本文件（跟 git）
├── dmg/          ← just dmg 输出
│   └── Zulangue-{version}.dmg   ← 给用户安装这个
└── app/          ← 开发期未打包 app
    └── Zulangue.app              ← 本地直接运行用
```

## 常见操作

| 我要 | 命令 |
|---|---|
| **装最新版测试** | `just release-unsigned` → 双击 `build/dmg/Zulangue-*.dmg` |
| 开发期快速试跑（Debug） | `just dev` → Xcode 启动 Zulangue target |
| 清掉所有构建产物 | `just clean && rm -rf build/dmg build/app` |

## 为什么叫 `build/` 不叫 `dist/`？

之前的 `dist/` 与 `build/` 分开放, Xcode 自己又在 `macos/Zulangue/build/` 生成 186MB 中间文件, 三处并存难以找到真实的安装包。现在统一在根级 `build/`, 子目录明确区分最终产物类型。
