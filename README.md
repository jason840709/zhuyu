# 逐語 Zhuyu

逐語是 Mac 上的即時雙語逐字稿 App。左右兩欄各選一種語言（繁體中文、英文、日文），有人講話時，原話出現在它那一側，譯文出現在另一側。適合上課、演講、會議與線上影片。

- **自備金鑰**：語音辨識可用 OpenAI 或 Gemini，翻譯可用 OpenAI、Gemini 或 Claude。不需要另外註冊帳號或訂閱。
- **App 自己斷句**：App 會自動估計環境底噪，講者停頓就換下一句。沒人講話時不送出聲音，安靜的時間不計辨識費。
- **整句潤飾**：每句講完後，翻譯會去掉結巴和口頭禪，譯成通順的書面句，並參考前三句。中文一律用台灣用語。
- **情境摘要**：App 會用一句話描述場合和目前的話題，再挑出最多 12 個容易聽錯的術語，同時提示語音辨識和翻譯。整理次數有上限，一小時的課約多 0.004 美元。
- **本機暫譯**：講話當下先在這台 Mac 上產生灰色暫譯，句子講完再換成正式譯文。暫譯引擎可以替換，見下方說明。

> 系統需求：Apple Silicon Mac、macOS 26 以上。從原始碼建置需要含 macOS 26 或更新 SDK 的 Xcode 或 Command Line Tools。

## 快速開始

```bash
bash build.sh
```

建置好的 App 在 `build/逐語.app`，可以直接打開，或搬到「應用程式」資料夾。

1. 打開「設定」，選服務商，貼上 API 金鑰後按「儲存」。
2. 分別選擇「語音辨識」和「翻譯與詞彙」要用哪一家；兩者可以交叉搭配。
3. 在逐字稿兩欄頂端選好語言，底部選收音來源（麥克風或電腦播放的聲音），按「開始辨識」（⌘R）。

完整操作見 [docs/使用說明.md](docs/使用說明.md)，費用估算見 [docs/模型與費率.md](docs/模型與費率.md)。

## 本機暫譯引擎（可替換）

灰色暫譯只是為了讓你講話時就看得到大意，正式譯文一定來自你選的雲端翻譯服務，所以這個引擎可以換成任何你喜歡的模型。在「設定 → 本機暫譯」可以選：

| 選項 | 說明 |
| --- | --- |
| 本機模型（預設） | 連到這台 Mac 上任何 OpenAI 相容的伺服器，例如 [Ollama](https://ollama.com)、LM Studio、llama.cpp server。預設模型是 Google 開放權重的 [TranslateGemma](https://ollama.com/library/translategemma) 4B。 |
| Apple 系統翻譯 | macOS 內建的離線翻譯，要先在「系統設定 → 一般 → 語言與地區 → 翻譯語言」下載語言包。 |
| 不使用 | 不產生暫譯，句子講完才出現正式譯文。 |

用預設模型的話，裝好 Ollama 後執行：

```bash
ollama pull translategemma:4b
```

> 預設模型是依網路上的評價選的，作者沒有實際測過它的速度和品質。速度太慢或譯文不理想時，可以在設定裡改填其他模型名稱。想自己寫一個新引擎也可以，見 [docs/替換本機暫譯引擎.md](docs/替換本機暫譯引擎.md)。

為了保護隱私，本機模型只接受這台 Mac 的位址（`127.0.0.1`、`localhost`）。暫譯的文字不會送出這台電腦。

## 隱私與資料

- 聲音只送給你選的語音辨識服務，句子文字只送給你選的翻譯服務。App 不保存錄音。
- 歷史紀錄和設定存放在 `~/Library/Application Support/app.zhuyu.mac/`。金鑰是其中 `Private/` 目錄內的**明文檔案**。
- 開啟「無痕模式」時不保存逐字稿。

## 開發

```bash
bash verify.sh            # 離線核心測試，不需要網路或金鑰
bash build.sh             # 建置 build/逐語.app
```

程式結構：

| 檔案 | 負責 |
| --- | --- |
| `Sources/UtteranceSegmenter.swift` | 斷句：估計底噪、判斷開口與停頓、只在講話時送出聲音 |
| `Sources/SpeechPipeline.swift` | 連接 OpenAI／Gemini 即時語音辨識 |
| `Sources/TranslationClient.swift` | 整句翻譯與潤飾（OpenAI、Gemini、Claude） |
| `Sources/SemanticEnvironment.swift` | 情境摘要、罕見詞、誤聽修正與用量上限 |
| `Sources/LocalDraftTranslator.swift` | 可替換的本機暫譯引擎 |
| `Sources/AppModel.swift`、`Views.swift` | App 狀態與 SwiftUI 介面 |

## 授權

MIT License，見 [LICENSE](LICENSE)。各家 API、Ollama、TranslateGemma 與 Apple Translation 依各自的條款使用；本專案不附帶任何模型權重。

---

## English

Zhuyu is a real-time bilingual transcript app for macOS (Apple Silicon, macOS 26+). Bring your own API key: speech recognition uses OpenAI or Gemini, and translation uses OpenAI, Gemini or Claude. The app detects pauses on its own and sends audio only while someone is speaking. Each finished sentence is polished into a written translation, and a running one-sentence scene summary guides both recognition and translation.

While someone is speaking, a gray draft translation is produced on your Mac. The draft engine is replaceable: by default it calls any OpenAI-compatible local server (Ollama, LM Studio, llama.cpp) running `translategemma:4b`. You can switch to Apple's on-device Translation framework or turn drafts off. To add your own engine, see [docs/替換本機暫譯引擎.md](docs/替換本機暫譯引擎.md). The default model has not been benchmarked by the author.

Build with `bash build.sh` and run the offline tests with `bash verify.sh`. MIT licensed.
