# ZuTalk logo assets

The product name is **ZuTalk**. The lettering inside the primary logo should
read **ZuTalk**.

> **待重绘 —— 改名尚未落到画上。** 下列 PNG 里的字样仍是旧名 `ZuLangue`,
> 那是画进像素里的,改名脚本碰不到它:
>
> - `ZuTalkAppIcon.png`(1024 px 母版)
> - `AppIcon.appiconset/zutalk-icon-{128,256,512}-{1x,2x}.png`
>
> 不带字的那批不受影响 —— `ZuTalkAppIconCompact.png` 与 16–64 px 的槽位
> 只有笔刷环,`zutalk-mark.svg` 是纯形状。所以现在的状态是:菜单栏和小尺寸
> 图标已经是干净的,唯独 Dock、访达、关于窗口这些用大图标的地方还写着旧名。
> 重新导出这几张之后删掉本段。

## Runtime variants

- `ZuTalkAppIcon.png` is the canonical 1024 px full app icon. It keeps the
  complete `ZuTalk` lettering and is used for the 128–1024 px AppIcon slots.
- `ZuTalkAppIconCompact.png` is the canonical 1024 px optical-small variant.
  It removes lettering and uses a heavier brush ring for the 16–64 px AppIcon
  slots.
- `ZuTalkMark.imageset/zutalk-mark.svg` is the transparent monochrome
  template mark used by the 18 pt menu-bar item and the 24 pt sidebar brand.

Do not mechanically shrink the full wordmark into small icon slots. Keep the
AppIcon PNGs opaque and sRGB, and keep the interface mark transparent,
monochrome, template-rendered, and vector-preserved.
