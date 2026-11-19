# 後端測試紀錄(Supabase Edge Functions)

日期:2026-11-19
範圍:`create-order`、`get-order`,以及 `index.html` 改接後的送單與查詢。
測試資料一律為虛構:姓名「測試顧客(虛構)」、手機 `0900000001`、Email `fake.customer@example.com`、備註「課堂測試,請勿製作或配送」。

本檔不含任何金鑰或密碼。

## 已確認成功

| 項目 | 結果 | 依據 |
|---|---|---|
| Dashboard Test 面板送出 `create-order` | 成功,訂單編號 `JF261119-001` | 使用者回報 |
| 網站結帳送單(外帶、1 份招牌豬肉鍋貼) | 成功,訂單編號 `JF261119-002`,應付 NT$85,預計約 15–20 分鐘 | 成功畫面截圖 |
| 網站載入新版程式 | `typeof callOrderApi` 為 `function` | 使用者回報 |
| 前端使用的金鑰類型 | publishable key(公開金鑰),未使用 service_role / secret key | 推送前掃描 |
| 網站的請求能通過函式的 JWT 檢查 | 請求成功送達並建立訂單 | 由送單成功推得 |

總額 NT$85 由後端依 `products` 表計算,前端未送價格與總額。

## 尚未確認(請補測)

以下項目沒有收到結果,**不能視為通過**:

1. **get-order 在 Test 面板的四步測試**:查詢 `JF261119-001`、將 `status` 改為 `preparing`、再查一次、查無訂單(`JF000101-999`)。
2. **Table Editor 核對 `JF261119-002`**:
   - `orders`:`status = new`、`fulfillment_type = take`、`store_id = flag`、`total = 85`。
   - `order_items`:1 列,單價 85、數量 1。
3. **網站「訂單查詢」**:查詢 `JF261119-002`,應顯示「新訂單」、品項與金額。
4. **網站狀態更新**:在 Table Editor 改成 `preparing` 後按「重新查詢」,應顯示「製作中」。
5. **網站錯誤情境**:輸入 `JF000101-999` 應顯示「查無此訂單」;輸入 `abc` 應顯示格式不正確。
6. **內用、宅配**:尚未測試。內用應加 10% 服務費;宅配應送 `address`、不送 `store_id`,未滿 1000 加運費 150。

## 已知限制

- `get-order` 只憑訂單編號查詢,沒有驗證查詢者身分,也沒有流量限制(見 `supabase/functions/get-order/index.ts` 開頭說明)。
- 網頁上顯示的商品價格仍寫死在 `index.html`;若資料庫價格不同,畫面小計會與後端回傳的 `total` 不一致,一律以後端為準。
- 成功畫面的「我們已開始為您準備」是固定文字,與訂單狀態無關。

## 留在資料庫的測試資料

- `JF261119-001`、`JF261119-002` 兩張虛構訂單。
- 另有 `demo-store`、`demo-chive`、`demo-pork` 三筆課堂測試用門市與商品。

如需清除,到 Table Editor 手動刪除 `orders` 的對應列;`order_items` 與 `order_status_log` 會一併刪除。
