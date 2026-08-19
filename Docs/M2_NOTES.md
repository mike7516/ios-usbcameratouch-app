# M2 — 觸摸控相機（協定對齊 `'TC'`）

> 協定依 SPEC §12（收斂到 8808 已實作的 `'TC'`）。M1 的投屏路徑不變；本階段只加反向通道解析與相機控制。

## 新增／改動
| 檔案 | 內容 |
|---|---|
| `Reverse/ReverseChannelParser.swift` | 解析 `'TC'` 觸控封包 + ACK 區分（magic `0x54 0x43` 掃描＋count/長度結構驗證），處理半包/黏包 |
| `Reverse/TouchController.swift` | 640×1136 → POI 換算、`tip_switch` 序列推 tap、對焦＋曝光 |
| `App/MainViewModel.swift` | 接線：`sender.onReverseBytes=parser.feed`；`parser.onAck=sender.ackReceived`；`parser.onTouch=touchController.handle` |

## 資料流
```
8808 ─(TCP 反向)→ FrameStreamSender.onReverseBytes ─→ ReverseChannelParser.feed
        ├─ 非 'TC' byte → onAck → sender.ackReceived()   （流量控制沿用，FPS 不掉）
        └─ 'TC' 封包    → onTouch → TouchController.handle → tap → AVCaptureDevice 對焦/曝光 POI
```
設定 `onReverseBytes` 後，M1 的「每 byte 當 ACK」內建路徑自動關閉，改由 parser 統一處理（ACK 仍由 parser 對非-`'TC'` byte 觸發）。

## 座標校正（**必做，實機**）
POI 映射目前是 portrait 起始猜測：`POI = (ny, 1 - nx)`（`TouchController.applyFocusExposure`）。
- 8808 面板點**四角 + 中心**，看相機對焦框落點，調整映射式——依 `videoRotationAngle = 90` 與前/後鏡頭鏡像，可能要 swap/flip。
- 前鏡頭 `isVideoMirrored` 時 `nx` 可能要改 `1 - nx`。
- 這通常是**只改一行**的事，但一定要在真機上對齊。

## M2 驗證
1. 先確認 M1 已跑通（相機→8808 顯示、ACK 正常、FPS 有值）。
2. 8808 面板點一下 → iPhone 相機在**對應位置**對焦＋測光（看預覽對焦框／曝光變化）。
3. 反應 < 100ms（受 8808 端 `move` 節流影響）。
4. 連續投屏時 FPS **不因觸摸而掉**（驗證 ACK 仍被 parser 正確計數）。

## 待調 / M3
- **POI 映射方向**：實機校正（最可能要改的一行）。
- **tap 參數**：`tapMaxDuration=0.4s`、`tapMaxMove=0.03`（正規化）依手感調。
- **雙指 zoom、拖曳曝光補償** = M3。
- **面板解析度 640×1136** 寫死在 `TouchController.panelWidth/Height`，多面板要改動態。

## 依賴前提（8808 端，已確認）
- 送 `'TC'`：`0x54 0x43` + `count` + 每點 6B（`id + x(LE) + y(LE) + tip`）。
- **每幀回 ACK**（FW 已補上）；ACK byte 建議避開 `0x54`，以免與 `'TC'` magic 混淆。
- 觸控座標為 **640×1136 面板座標**。
