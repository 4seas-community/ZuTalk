# vt-mirror 代码出处

本 crate 不是原创设计,而是把「应用状态 ↔ Loro CRDT」同步引擎从
TypeScript 移植到 Rust。移植策略:**先照译测试,再照译实现**,测试就是
上游行为的规格书。

## 血统

- **上游**:[loro-dev/loro-mirror](https://github.com/loro-dev/loro-mirror),
  MIT License, Copyright (c) 2024 Loro。
- **直接蓝本**:[macro-inc/macro](https://github.com/macro-inc/macro) 仓库
  内嵌的 `packages/loro-mirror`(`@loro-mirror/core` 0.1.0)——它派生自
  上游的早期版本并带有 macro 的修改;macro 仓库整体按
  GNU AGPL-3.0 授权,其 `THIRD_PARTY_LICENSES.md` 保留了上游 MIT 声明。

因此本 crate 按 **AGPL-3.0-or-later** 声明(两个血统中较严格者),
并保留上游 MIT 归属。采纳 AGPL 为项目决定,记录于
docs/architecture/document-schema-decision.md。

## 文件对应表

| 本 crate | 蓝本(macro 内嵌 loro-mirror) |
|---|---|
| `src/lis.rs` | `src/core/diff.ts` 的 `longestIncreasingSubsequence` |
| `src/value.rs` | `src/core/utils.ts` 的 isObject/deepEqual/getPathValue/setPathValue;测试照译 `tests/core/utils.test.ts` |
| `src/schema.rs` | `src/schema/{index,types,validators}.ts`;测试为 validators.ts 的逐分支规格(蓝本无专属测试),两处怪癖照抄并以测试钉死 |
| `src/change.rs` | `src/core/mirror.ts` 的 `Change` / `InferContainerOptions` 类型 |
| `src/utils.rs` | `src/core/utils.ts` 余下的容器工具;测试为逐分支规格,怪癖 3(MovableList 升级落空)照抄钉死 |
| `src/diff.rs` | `src/core/diff.ts` 余下全部(diffContainer/diffText/diffMap/diffList/diffListWithIdSelector/diffMovableList);怪癖 4(useContainer 恒真)、5(diffMap 假值旧值重插)照抄钉死;两处 `===` 引用相等以 deep_equal 替代(输出等价,模块注释有论证) |
| `src/mirror.rs` | `src/core/mirror.ts` 全部(Mirror 本体、容器注册表、事件订阅、changes 应用);state.ts 的 createStore 门面并入本类型,immer reducer 不移植;怪癖 6(updateMapEntry 插容器后纯值盖写)照抄钉死;awaitMirrorSync 微任务 hack、订阅表泄漏、handler 参与 deepEqual 三处按模块注释declared 偏离 |
| `tests/`(逐模块) | `tests/core/*.test.ts` 照译 |

后续移植按此表续记,一行一个模块;没登记的文件不存在于蓝本,属自研。
