# 測試

```bash
bash verify.sh
```

離線核心測試，不需要網路或 API 金鑰。內容包括：斷句器（用合成聲音測底噪、停頓與長句切分）、詞彙與讀音規則、舊設定相容、本機暫譯引擎的規則。

## 用自己的錄音測斷句

可以加上一段錄音（24 kHz、單聲道、16 位元 WAV）和一份標註檔：

```bash
bash verify.sh 我的錄音.wav 我的錄音.json
```

標註檔記錄每一段的類型與起訖秒數，測試會檢查安靜時沒有產生句子、停頓後有換句。段落名稱需要包含 `quiet-noise-10s`、`chinese`、`english`、`bilingual-in-loud-noise`：

```json
{ "segments": [
  { "label": "quiet-noise", "start": 0.0, "end": 2.0 },
  { "label": "chinese", "start": 2.0, "end": 11.5 },
  { "label": "pause-1.5s", "start": 11.5, "end": 13.0 },
  { "label": "english", "start": 13.0, "end": 20.4 },
  { "label": "quiet-noise-10s", "start": 20.4, "end": 30.4 },
  { "label": "bilingual-in-loud-noise", "start": 38.4, "end": 60.3 }
] }
```

## 測試本機模型伺服器

```bash
ZHUYU_DRAFT_ENDPOINT=http://127.0.0.1:11434/v1 ZHUYU_DRAFT_MODEL=translategemma:4b bash verify.sh
```
