# USBCameraTouch iOS — 實現規劃 (Implementation Plan v1)

> 依據 `Docs/SPEC.md` v0.1 ＋ **實讀** 姊妹專案 `USBDisplay_IOS_Standalone_From_Python` 全部原始碼後撰寫。
> 目的：把 SPEC 的「大量重用」策略**具體到檔案／介面級**，並逐條回答 SPEC §9 開放問題。
> 對接的裝置端（8808 韌體）觸摸接口背景見 2ndbrain `規格與協議/8808 with ios(airplay)/觸摸反控-規格需求.md`。

---

## 0. 一頁摘要（TL;DR）

**本質**：`USBCameraTouch` = `USBDisplay` 的三處改造——
1. **換來源**：ReplayKit 螢幕擷取 → AVFoundation 相機（`CMSampleBuffer` 介面不變）。
2. **升級反向通道**：目前「每個 byte 當一個 ACK」→ 型別解析器（`0x01` ACK／`0x02` TOUCH）。
3. **新增觸摸控相機**：解析出的觸摸點 → `AVCaptureDevice` 對焦／曝光／縮放。

**最大重用槓桿**：`CMSampleBuffer` 是 ReplayKit 與 AVFoundation 的**共同貨幣**。既有 `JPEGEncoder`（吃 `CMSampleBuffer`）、pacing／ACK 節流、`TCPTransport`、metrics 幾乎**零改動**沿用。

**比 USBDisplay 更簡單**：相機用 AVFoundation 在 App 內即可，**單一 App target、無 Broadcast Extension**，省掉 extension 的 App Group IPC／`stopGeneration`／記憶體限制那一整套。

**三個要動的地方**：
| 動作 | 元件 | 來源 |
|---|---|---|
| 抽出重用 | `FrameStreamSender` | 從 `BroadcastStreamController` 抽出 encode＋pacing＋ACK gate＋metrics |
| 新寫 | `CameraCaptureController` | 取代 `SampleHandler`（ReplayKit），改 AVFoundation delegate |
| 新寫 | `ReverseChannelParser` ＋ `TouchController` | 型別解析 ＋ 觸摸→相機控制 |

---

## 1. 既有 code 盤點（實讀結論 → 相機專案處置）

| 檔案 | 現況（USBDisplay） | 相機專案處置 |
|---|---|---|
| `Network/TCPTransport.swift` | `NWConnection`，`start/stop/send`，callbacks `onReady/onData/onStateChanged/onRemoteClosed`；noDelay＋keepalive＋自動重連；`onData` 已是反向 byte 流 | **原封沿用** |
| `JPEG/JPEGEncoder.swift` | `encode(sampleBuffer:width:height:quality:) -> Data`；CoreImage resize（stretch）＋ImageIO 壓縮；驗 `FFD8…FFD9` | **原封沿用**（相機 `CMSampleBuffer` 直接餵） |
| `JPEG/JPEGSamplingInspector.swift` | 事後檢查 chroma sampling | 沿用（debug 用） |
| `BroadcastExtension/BroadcastStreamController.swift` | **真正的連續影像 sender**：`submit(CMSampleBuffer)`、targetFps 節流、`ackPaced` gate（在途一幀）、`ackTimeout` 0.5s、`pendingAckTimes` RTT、metrics | **抽出成 `FrameStreamSender`**（去掉 ReplayKit／extension／`RuntimeBridge.currentStopRequest` 耦合） |
| `BroadcastExtension/SampleHandler.swift` | `RPBroadcastSampleHandler.processSampleBuffer → controller.submit()` | **棄用**，換 `CameraCaptureController` |
| `DirectSender/DirectImageSender.swift` | App 內純色測試送圖；`onData` 數 byte 算 RTT 的範式 | 參考（App 內送圖＋onData 範式） |
| `Runtime/RuntimeConstants.swift` | host `192.168.0.1`／port `7658`／`ackTimeout 0.5`／`reconnect 1s`；`appGroupID`／extension bundleID | 沿用 host/port/timeout；**改 IDs**、刪 extension bundleID |
| `Model/AppModels.swift` | `RuntimeConfig`（w/h/quality/targetFps/ackPaced/sendMode/imageMode）、`RuntimeStatus`（含 encode/send/rtt/fps metrics） | **擴充**：鏡頭、觸摸開關、zoom；`imageMode` 的 SCREEN/RGB 語意改成相機相關或移除 |
| `Runtime/RuntimeBridge.swift` | App Group `UserDefaults`（config/status IPC）＋共享容器（preview、`metrics.csv`） | 單 App 可簡化 IPC；**保留 `metrics.csv`**（SPEC §4.6，便於 `devicectl` 拉取分析） |
| `UI/MainView.swift`／`App/MainViewModel.swift` | 設定／狀態橫幅／統計版型 | 沿用版型，M3 加相機控制項 |
| `UI/BroadcastPickerView.swift` | ReplayKit 系統 picker | **棄用** |

> ⚠️ **反向通道關鍵事實**：`BroadcastStreamController.onData` 目前是
> `for _ in 0..<data.count { pendingAckTimes.removeFirst() }` —— 把**每個 byte 都當一個 ACK**、不檢查值。ACK gate（`awaitingAck`）也靠這個開。升級成型別解析後，**ACK 語意從「數 byte」改成「數 `0x01` 封包」**，且 `0x02` 不能被誤當 ACK。這牽動**裝置端韌體必須送 `0x01` 當 ACK、`0x02` 當 TOUCH**（見 §4 相容性前提）。

---

## 2. 目標架構

```
┌──────────────────────── iPhone App（單一 target）────────────────────────┐
│ CameraCaptureController                                                   │
│   AVCaptureSession → AVCaptureVideoDataOutput(delegate)                   │
│     └─ captureOutput(_:didOutput sampleBuffer:) ─┐                        │
│   AVCaptureVideoPreviewLayer（本機預覽）          │                        │
│   AVCaptureDevice ◀───────────────┐              ▼                        │
│                                    │   FrameStreamSender.submit(buf)      │
│                                    │     encode(JPEGEncoder) → pacing     │
│                                    │     → ACK gate → TCPTransport.send   │
│                                    │            │ 純 JPEG ↓  ↑ 反向 bytes  │
│   TouchController ◀── .touch ── ReverseChannelParser ◀── TCPTransport.onData
│     座標映射 → focus/exposure/zoom     .ack ─→ FrameStreamSender.ackReceived()
└──────────────────────────────────────────────────────────────────────────┘
                        │ USB / NCM  TCP 192.168.0.1:7658
                        ▼   出站：純 JPEG(FFD8…FFD9)  入站：0x01 ACK / 0x02 TOUCH
                 ┌─────────────────────────┐
                 │ 8808（外接觸控顯示器）    │ 收 JPEG→解碼→顯示；回 0x01；觸摸回 0x02 │
                 └─────────────────────────┘
```

---

## 3. 元件設計（介面級）

### 3.1 `FrameStreamSender`（從 `BroadcastStreamController` 抽出）
把「連續影像 sender」從 extension 抽成獨立、與來源無關的類別。

```swift
final class FrameStreamSender {
    init(config: RuntimeConfig)
    func start()                          // transport.start(reconnect: continuous)
    func stop()
    func submit(_ sampleBuffer: CMSampleBuffer)   // 來源無關：相機或任何 CMSampleBuffer
    func ackReceived(count: Int = 1)      // 由 ReverseChannelParser 呼叫，開 ACK gate + 算 RTT
    var onStatus: ((RuntimeStatus) -> Void)?
    var onPreview: ((Data) -> Void)?      // 可選：送出的 JPEG 回顯（若不用相機預覽層）
}
```

**保留**（原封搬過來）：`targetFps` 節流、`ackPaced && awaitingAck` gate、`ackTimeout` 0.5s 強制開 gate、`pendingAckTimes` FIFO RTT、encode 走獨立 `encodeQueue`、metrics/`instantFps`。
**移除**（extension 專屬耦合）：`RuntimeBridge.currentStopRequest()`／`stopGeneration` 那段跨程序停止協商（單 App 直接 `stop()`）、`extensionActive` 相關狀態。
**改動**：原 `onData` 內「數 byte 算 RTT ＋ 開 gate」的邏輯**移出**到 `ReverseChannelParser`，改由 parser 解析出 `.ack` 後呼叫 `ackReceived()`。

### 3.2 `CameraCaptureController`（新寫，取代 `SampleHandler`）
```swift
final class CameraCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    init(sender: FrameStreamSender)
    func configure(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset)
    func start(); func stop()
    func switchCamera(to: AVCaptureDevice.Position)
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    var device: AVCaptureDevice? { get }   // 交給 TouchController 控制

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sender.submit(sampleBuffer)        // ← 與 SampleHandler.processSampleBuffer 對稱
    }
}
```
要點：
- `AVCaptureVideoDataOutput.videoSettings` 設 `kCVPixelFormatType_32BGRA` 或 `420f`——兩者 `CIImage(cvPixelBuffer:)` 都吃，`JPEGEncoder` 無需改。
- `connection.videoOrientation` / `isVideoMirrored`（前鏡頭）要**與座標映射一致**（見 §5）。
- `alwaysDiscardsLateVideoFrames = true`（sender 已自帶背壓丟幀，避免 buffer 堆積）。
- 相機權限：`Info.plist` 加 `NSCameraUsageDescription`。
- 執行緒：delegate callback queue 建議獨立 serial queue；`submit` 內部本來就切回自己的 queue。

### 3.3 `ReverseChannelParser`（新寫）
取代目前 onData 的「數 byte」。狀態機累積 buffer、依型別長度切包，處理半包／黏包（SPEC §6.3）。
```swift
final class ReverseChannelParser {
    var onAck: (() -> Void)?
    var onTouch: ((TouchEvent) -> Void)?
    func feed(_ data: Data)   // 掛在 TCPTransport.onData
}
struct TouchEvent { let action: UInt8; let id: UInt8; let x: UInt16; let y: UInt16 } // x/y big-endian 已解
```
解析迴圈（在 transport queue 上）：
1. buffer 追加新 data；`while` 迴圈直到不足一包。
2. peek `buffer[0]`：
   - `0x01` → `onAck()`；消費 1 byte。
   - `0x02` → 需 `>= 7` bytes，否則 break 等下一段；讀 `action,id,x(BE),y(BE)` → `onTouch`；消費 7 bytes。
   - **其他值** → resync 策略（見下）。
3. `onAck` → `sender.ackReceived()`；`onTouch` → `touchController.handle()`。

**resync 策略**（要拍板）：遇到未知型別 byte，建議**丟棄 1 byte 往前掃**（自我復原，容忍偶發位元流錯位），並記一個 warning counter；不整段清空（避免丟掉後續合法封包）。

### 3.4 `TouchController`（新寫）
```swift
final class TouchController {
    init(deviceProvider: () -> AVCaptureDevice?, config: RuntimeConfig)
    func handle(_ e: TouchEvent, sourceSize: CGSize)   // sourceSize = 目前送出影像 width×height
}
```
行為（SPEC §4.4，預設可開關）：
- **點按**（`down` 後同點 `up`）→ 設 `focusPointOfInterest` ＋ `exposurePointOfInterest`（0..1）＋ `focusMode=.autoFocus`、`exposureMode=.autoExpose`。
- **拖曳**（`move`）→ 曝光補償 `setExposureTargetBias`（選配）或忽略；**需去抖/節流**（見 §7 風險）。
- **雙指**（兩個 `touchId` 同時）→ `videoZoomFactor` pinch（選配）。
- `cancel` → 結束該 touchId 的手勢狀態。
- 每次改 `AVCaptureDevice` 前 `lockForConfiguration()`／後 `unlockForConfiguration()`；先查 `isFocusPointOfInterestSupported` 等能力旗標。

### 3.5 Models 擴充（`AppModels.swift`）
```swift
struct RuntimeConfig {
    // 沿用：width, height, jpegQuality, targetFps, ackPaced, sendMode
    var cameraPosition: CameraPosition = .back        // 新
    var touchFocus: Bool = true                        // 新
    var touchExposure: Bool = true                     // 新
    var touchZoom: Bool = false                         // 新（選配）
    // imageMode(SCREEN/RGB) 移除或改為相機測試圖樣
}
enum CameraPosition: String, Codable { case front, back }
```

---

## 4. 通訊協定（對接 SPEC §6 ＋ 裝置端相容性）

- **出站 App→設備**：連續純 JPEG，無框架（**不變**，與設備現有接收端相容）。
- **入站 設備→App**：1-byte 型別 tag。

| type | 名稱 | 長度 | 內容 |
|---|---|---|---|
| `0x01` | ACK | 1 B | 每處理完一幀回一個（流量控制＋RTT） |
| `0x02` | TOUCH | 7 B | `type, action(0=down/1=move/2=up/3=cancel), touchId, x(u16 BE), y(u16 BE)` |

- 座標 `x/y` = **送出影像像素座標**（目前 `width×height`）→ App 端自己知道尺寸，映射最省事，**不需設備回報面板解析度**。
- **⚠️ 跨端相容性前提（必須與 8808 韌體對齊）**：
  1. 設備端 ACK **必須送 `0x01`**（現行 App 只數 byte 不驗值，升級為型別解析後會驗 type；若設備送的是其他 byte，會被 resync 丟棄，**ACK gate 永遠等不到 → 掉到 0.5s timeout 節奏、FPS 砍半**）。
  2. TOUCH **必須送 `0x02` ＋ 6 bytes**，`x/y` big-endian。
  3. 這需要在 8808 端的反向通道送出邏輯確認／修改。**M2 開工前先與韌體對齊此三點**。

---

## 5. 座標映射（觸摸像素 → 相機 POI）

輸入：`TouchEvent.x/y ∈ [0,width)×[0,height)`（送出影像像素座標）。
目標：`AVCaptureDevice.focusPointOfInterest ∈ [0,1]×[0,1]`。

```
nx = x / width ,  ny = y / height          // 先正規化到 0..1
POI = orient( nx, ny )                       // 依 videoOrientation/鏡像轉換
```

- `focusPointOfInterest` 的原生座標系是 **landscapeRight（home 鍵在右）下的 top-left 原點**，**與 UI 方向無關**。若送出影像／預覽是 portrait，`(nx,ny)` 要做方向轉換（portrait 常見為 `POI=(ny, 1-nx)` 一類），**依 `connection.videoOrientation` 決定**。
- **前鏡頭**：`isVideoMirrored` 若為真，送出影像已鏡像，`nx → 1-nx` 對齊。
- 原則：**「送出影像」怎麼被 orientation/鏡像變換，反向套回 POI**。方向轉換矩陣容易錯位，**M2 用「畫面四角＋中心點按」實機校正**，落地成一張對照表寫進註解。
- 建議用 `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)` 反推驗證映射是否正確（把像素座標換算成 preview layer 座標後比對）。

---

## 6. 里程碑與檔案級任務（對接 SPEC §8）

### M1 — 相機 → 設備顯示（先不接觸摸）
- [ ] 建 Xcode 專案（§7）；`Info.plist` 加 `NSCameraUsageDescription`。
- [ ] 複製沿用檔：`TCPTransport`、`JPEGEncoder`、`JPEGSamplingInspector`、`RuntimeConstants`（改 IDs）、`RuntimeBridge`、`AppModels`。
- [ ] 抽 `FrameStreamSender`（§3.1）；先不接反向解析，`onData` 暫時沿用「數 byte」保持 ACK gate 可動。
- [ ] 新寫 `CameraCaptureController`（§3.2），`captureOutput → sender.submit`。
- [ ] ✅ 驗證：設備看到相機即時畫面；`metrics.csv` 有 fps/RTT。

### M2 — 反向通道 ＋ 點按對焦/曝光
- [ ] **先與韌體對齊 `0x01`/`0x02` 協定（§4 相容性前提）**。
- [ ] 新寫 `ReverseChannelParser`（§3.3），接管 `TCPTransport.onData`；`.ack → sender.ackReceived()`。
- [ ] 新寫 `TouchController`（§3.4）；點按 → focus＋exposure POI。
- [ ] 座標映射＋實機四角校正（§5）。
- [ ] ✅ 驗證：設備觸摸螢幕 → App 對應點對焦/曝光；反應 < 100ms。

### M3 — 進階控制 ＋ UI ＋ metrics 面板
- [ ] 縮放（雙指 zoom）、曝光補償（拖曳，選配）、前後鏡頭切換。
- [ ] 設定 UI（沿用 `MainView` 版型）：解析度、品質、targetFps、ackPaced、觸摸行為開關、鏡頭。
- [ ] 連線狀態橫幅＋TEST TCP＋統計面板沿用。

### M4 — 實機調校 ＋ 穩定性
- [ ] RTT／FPS／觸摸延遲調校；`move` 事件節流（§7）。
- [ ] 斷線自動重連（`TCPTransport` 已內建）；parser 半包/黏包/resync 容錯壓測。

---

## 7. 專案骨架建立（目前 `USBCameraTouch_IOS/` 只有 `Docs/`，從零建）

**建議目錄**（單 App target）：
```
USBCameraTouch_IOS/
  Docs/                         # SPEC.md, IMPLEMENTATION_PLAN.md（本檔）
  USBCameraTouch/
    App/                        # App entry, MainViewModel
    Camera/                     # CameraCaptureController（新）
    Sender/                     # FrameStreamSender（抽出）
    Reverse/                    # ReverseChannelParser, TouchController（新）
    Network/ JPEG/ Runtime/ Model/ UI/   # 沿用自 USBDisplay
```

**共用層決策（✅ 已定案：複製）**：新專案直接**複製一份** `TCPTransport / JPEGEncoder / JPEGSamplingInspector / RuntimeConstants / RuntimeBridge / AppModels` 進去，**不抽 Swift Package**，兩專案各自維護。趕工最快；日後雙修負擔變大時，M3 穩定後再評估抽 package。

**設定**：
- iOS deployment target 對齊 USBDisplay（iOS 26.x / Xcode 26）。
- entitlements：若沿用 `metrics.csv` 共享容器→保留一個 App Group（單 App 也可，或改寫自身容器）；否則可完全不用 App Group。
- Team／bundle id：見 §9。

---

## 8. SPEC §9 開放問題 — 逐條回答

1. **相機→設備顯示**：是。架構圖與重用鏈都據此，確認無誤。
2. **觸摸來源/用途**：來源＝設備觸控螢幕回傳（`0x02`）；用途初版＝**對焦＋曝光 POI**（點按）。zoom/曝光補償列選配（M3）。「只轉發座標給別系統」→ 不在初版（SPEC out-of-scope）。
3. **傳輸方式**：**同一條 TCP**、擴充 `0x01/0x02`。理由：`TCPTransport.onData` 已是反向通道，複用最省；另開 port/UDP 徒增連線管理與設備端改動。
4. **封包格式**：7-byte 格式可接受。座標用「送出影像像素座標」（**App 端映射最簡，不需設備回報解析度**）。多點：`touchId` 已預留，初版單點（`id=0`）先落地，雙指 zoom 於 M3。壓力/時間戳：初版不需要，日後 `0x03` 擴充。
5. **延遲/頻率**：反應目標 < 100ms。設備端 `move` 建議上限 ~60Hz 並做位移門檻，避免灌爆反向通道排擠 ACK（§7 風險）。實際頻率待韌體端定，回填 SPEC §5。
6. **共用程式庫**：✅ **已定案——先各自複製**，不抽 package（M3 穩定後再評估）。
7. **命名/bundle/Team**：✅ **已定案（參考 USBDisplay）**——bundle id `wen.usbcameratouch`、App Group `group.wen.usbcameratouch`（沿用；`RuntimeBridge`/`RuntimeConstants` 只改 ID 字串，不改寫成自身容器）、Team `UQJKPW4GW8`。
8. **App 內預覽**：建議**要**，用 `AVCaptureVideoPreviewLayer`（比回顯送出 JPEG 低延遲、省電）。

---

## 9. 拍板結果（2026-08-18）

1. **共用層** ✅ **複製** — 不抽 package，兩專案各自維護。
2. **命名** ✅ 參考 USBDisplay — bundle `wen.usbcameratouch`、App Group `group.wen.usbcameratouch`、Team `UQJKPW4GW8`。
3. **觸摸優先級** ✅ **是** — 初版只做點按對焦＋曝光，zoom/拖曳延 M3。
4. **裝置端協定** 📤 **已寫進 `SPEC.md` §10 交 FW 團隊評估**（`0x01` ACK／`0x02` TOUCH(BE)、座標系分工、`move` 節流、評估點清單）。**M2 開工前需 FW 回覆**。

---

## 10. 風險

| 風險 | 說明 | 對策 |
|---|---|---|
| **跨端協定對齊** | 設備端 ACK 若非 `0x01`，升級型別解析後 ACK gate 失效 → FPS 砍半 | M2 前與韌體對齊（§4）；過渡期可加相容開關（未知 byte 也當 ACK 開 gate） |
| **座標映射方向/鏡像** | POI 原生 landscapeRight 座標系，portrait/前鏡頭易錯位 | 實機四角校正（§5），落成對照表 |
| **`move` 洪流 vs ACK 同 socket** | 高頻 move 佔用反向通道，排擠 ACK、拖累 pacing | 設備端 move 節流＋位移門檻；App parser 優先處理 ack |
| **相機像素格式** | `AVCaptureVideoDataOutput` YUV/BGRA 與 `JPEGEncoder` `CIImage` 相容性 | 兩者 `CIImage` 皆支援，M1 先驗；固定一種 `videoSettings` |
| **JPEGEncoder resize 是 stretch** | 相機比例（4:3/16:9）≠ 設備顯示比例會變形 | 沿用 USBDisplay 行為（stretch 到 width×height）；如需保比例，於 encoder 前加 letterbox（M3 選配） |

---

*v1 — 依實讀 USBDisplay 原始碼撰寫。§9 拍板、§4 韌體協定確認後即可進 M1。*
