# 資料庫(Supabase PostgreSQL)

這個資料夾是把訂單後端從「Google Apps Script + Google Sheet」搬到 Supabase 的**資料庫地基**。
目前網站(`index.html`、`admin.html`)**仍然使用 Google Apps Script**,還沒有串接 Supabase。

## 架構與安全原則

完成串接後的目標架構:

```
訪客的瀏覽器 ──► Supabase Edge Functions(使用 service_role)──► 資料庫
        └──(僅讀取)anon key ──► products / stores(只看得到上架資料)
```

- 訪客**不能**直接讀寫訂單相關資料表。訂單、明細、狀態紀錄、計數器、店員名單都啟用 RLS 且**沒有任何政策**,
  並且明確收回 anon / authenticated 的所有權限。
- 訂單資料之後要由 Edge Function 用 **service_role** 讀寫;service_role 也只被授與必要權限(**沒有 DELETE / TRUNCATE**)。
- 下單、查單、改狀態是三個資料庫函式,**只有 service_role 能執行**。
- ⚠️ service_role / secret key **只能放在 Edge Function 的環境變數**,絕對不要寫進 `index.html`、`admin.html` 或任何前端檔案。
  前端只能用 anon(publishable)key,而且它只能讀商品與門市。

## 檔案與執行順序

| 順序 | 檔案 | 用途 |
|---|---|---|
| 1 | `database/001_create_orders.sql` | 建立資料表、限制、索引、函式、觸發器,並設定 RLS 與權限 |
| 2 | `supabase/seed.sql` | 匯入門市(3 間)與商品(19 項)的初始資料 |
| 3 | `database/002_verify_orders.sql` | 建表後查核 + 用虛構訂單測試寫入/查詢(全部回滾,不留資料) |
| — | `database/README.md` | 本說明 |

在 Supabase Dashboard → **SQL Editor** 貼上整份檔案後執行(請用預設的 postgres 身分)。**先 001,再 seed,最後 002。**
002 不依賴 seed(它用自己的虛構門市與商品),但沒跑 seed 時會有一項 SKIP 提醒你。

> 001 可以重複執行(只用 `create ... if not exists` / `create or replace`,觸發器與政策是先 drop 再重建),
> 不使用 DROP TABLE、TRUNCATE,也不會刪除任何資料列。
>
> seed.sql 是一般的 `insert`,**只要執行一次**。重複執行會出現 `duplicate key` 錯誤,代表資料已經匯入過,不會產生重複資料。
>
> 002 可以隨時重複執行,而且正式上線後、有真實訂單時也能跑(見下方「002 怎麼保證不留下假訂單」)。

## 001 建立了什麼

**7 張資料表**

| 資料表 | 用途 |
|---|---|
| `stores` | 門市(代碼、名稱、地址、電話、是否營業、排序) |
| `products` | 商品(代碼、品名、價格、分類、描述、圖片、標籤、是否上架、排序) |
| `orders` | 訂單(`order_no`、狀態、取餐方式、顧客資料、門市、金額) |
| `order_items` | 訂單明細(品名與單價為下單當下的快照) |
| `order_status_log` | 狀態變更紀錄(誰、何時、從哪到哪) |
| `order_counters` | 每日訂單流水號計數器 |
| `staff_members` | 店員名單(之後的後台用來判斷登入者是否為店員) |

**資料庫函式**

| 函式 | 用途 |
|---|---|
| `create_order(payload jsonb)` | 下單:驗證欄位、以 `products` 價格重算金額、產生訂單編號,回傳 `order_no`、`total`、`eta` |
| `track_order(p_order_no text)` | 查單:只憑訂單編號,只回傳品項、金額、狀態、時間,不回傳個資 |
| `update_order_status(p_order_no, p_status, p_actor)` | 後台改狀態(會寫入狀態紀錄) |
| `calc_fee`、`next_order_no`、`is_staff` | 內部輔助函式(運費/服務費、訂單編號、店員判斷) |

**代碼**

- 訂單狀態:`new`(新訂單)、`preparing`(製作中)、`ready`(待取餐)、`delivering`(配送中)、`done`(已完成)、`cancelled`(已取消)
- 取餐方式:`dine`(內用)、`take`(外帶)、`ship`(宅配)
- 訂單編號:`JF` + `yyMMdd`(台北時間)+ 流水號,例如 `JF251022-001`

## seed.sql 匯入了什麼

- `stores`:`flag`(旗艦店)、`xinyi`(信義店)、`taichung`(台中勤美店)
- `products`:`s1`–`s4`(招牌鍋貼)、`d1`–`d4`(精選水餃)、`p1`–`p4`(湯品/飲料)、`k1`–`k4`(經典小菜)、`g1`–`g3`(冷凍禮盒)

這些代碼與價格和 `index.html` 的 `STORES` / `MENU` / `GIFTS`、`gas/Code.gs` 的 `PRODUCTS` 一致。

## 每一步預期看到什麼

**執行 001**:最後顯示 *Success. No rows returned*,沒有錯誤。
之後在 Table Editor 應看到 7 張表:`stores`、`products`、`orders`、`order_items`、`order_status_log`、`order_counters`、`staff_members`,
且每張表都標示 RLS enabled。

**執行 seed.sql**:顯示 *Success*。之後在 Table Editor 應看到 `stores` 有 3 筆、`products` 有 19 筆;
其餘 5 張訂單相關的表是空的。

**執行 002**:整份貼上、一次執行(不要只選一段)。結果是**一張表**,欄位為 `r_step / r_section / r_check / r_result / r_detail`:

- 第 0 列是總結。全部正常時 `r_result` 為 **`ALL PASS`**,`r_detail` 類似「共 110 項上下:PASS n、FAIL 0、SKIP 0~4」(確切項數依是否略過店員測試而略有不同)。
- 其餘每列一個檢查項目,`r_result` 是 `PASS`、`FAIL` 或 `SKIP`。
  - 分區:`A 結構`、`A RLS 與權限`、`A 資料`(唯讀查核)→ `B 下單`、`B 拒絕不合法輸入`、`B 查單`、`B 改狀態`、`B 資料庫限制`、`B 權限`(虛構訂單測試)→ `C 回滾確認`。
  - 出現 `FAIL`:看 `r_detail`;最常見是 001 沒完整執行(重跑 001 即可)。
  - 出現 `SKIP`:不是錯誤。可能是①還沒執行 seed.sql(`A 資料` 那列);②專案不允許在 `auth.users` 寫入虛構店員,於是「店員改狀態」那 3 項略過;③無法切換成 anon 角色。`r_detail` 會寫原因。
- 若 Dashboard 跳出「查詢含有破壞性操作」的警告:那是因為檔案內的註解與字串提到 DELETE / TRUNCATE(用來檢查「後端沒有這兩種權限」)。
  實際沒有任何 DROP TABLE、TRUNCATE、DELETE 敘述,可放心繼續。
- 跑完後再看一次 Table Editor:`orders` 等表的筆數**與跑之前完全相同**(`C 回滾確認` 那幾列也會證明這點)。

### 002 怎麼保證不留下假訂單

- 所有虛構資料(門市 `zz_test_store`、商品 `zz_test_a/b/off`、訂單、明細、狀態紀錄、虛構店員)都寫在 PL/pgSQL 的**子交易**(等同 SAVEPOINT)裡,
  最後一行**無條件** `RAISE`,整段回滾;中途任何一步出錯也一樣回滾。
- 之所以不用單純的 `BEGIN ... ROLLBACK`:Dashboard 的 SQL Editor 只顯示「最後一個」結果,而 `ROLLBACK` 會排在最後;
  用子交易可以讓整份檢查結果集中在最後一張表,且就算編輯器自動提交也不會留下資料。
- 每日流水號(`order_counters`)也會一併回滾,**不會吃掉真實的訂單編號**。唯一的痕跡:`order_status_log` 的 identity 序號會往前跳幾號(序號本來就不保證連續)。
- 暫時函式建立在 `pg_temp`(只存在於這次連線),不會留在 `public`。
- 測試虛構資料:姓名「測試訪客(虛構)」、手機 `0900000001`、信箱 `fake.customer@example.com`(`example.com` 為保留網域)。

### 002 測了什麼

| 區 | 內容 |
|---|---|
| A 結構 | 7 張表、6 個函式、主鍵、`orders` / `order_items` 欄位與型別、CHECK / UNIQUE 限制、3 個觸發器 |
| A RLS 與權限 | 7 張表皆啟用 RLS;5 張訂單相關表**沒有任何政策**;沒有寫入政策或對 `public` 開放的政策;anon / authenticated 對訂單相關表**零權限**、對商品/門市**只讀**;service_role **沒有 DELETE / TRUNCATE**,明細/狀態紀錄/店員名單只有最小權限;函式只有 service_role 能執行 |
| B 下單 | 外帶、內用(服務費 10%)、宅配(未滿 1000 運費 150、滿 1000 免運)、同商品合併、價格快照、訂單編號格式、預設狀態 `new`、觸發器寫入第一筆狀態紀錄 |
| B 拒絕不合法輸入 | 18 種錯誤輸入(手機、Email、姓名、地址、門市、空購物車、超過 30 項、數量 0/51/負數/非數字、下架或不存在商品…)與 honeypot,皆被拒絕且**不新增任何資料** |
| B 查單 | 只回品項/金額/狀態/時間,**不含姓名、手機、Email、地址、備註**;大小寫不拘;不存在、格式錯誤的處理 |
| B 改狀態 | 非店員被拒(AUTH);店員改狀態成功、`updated_at` 更新、狀態紀錄記下操作者 |
| B 資料庫限制 | 繞過函式、直接寫入不合法資料(金額不符、不合法狀態、手機/Email 格式、宅配無地址、編號重複、外鍵、明細數量與小計)全部被資料庫擋下 |
| B 權限 | 實際切換成 `anon`、`authenticated`、`service_role` 身分嘗試越權操作,全部回 `42501 permission denied`;anon 讀商品只看得到「上架」的 |
| C 回滾確認 | 各表筆數、流水號、殘留資料與測試前一致 |

> ⚠️ **誠實說明**:我(Claude)沒有連線你的 Supabase,本機也沒有 PostgreSQL 可以試跑,
> 所以 001 的修正、002 都**還沒有實際執行過**。請你在 SQL Editor 跑一次 002 並以結果為準;
> 若有 `FAIL`,把 `r_check` 與 `r_detail` 貼給我,我再修。

## 哪些來自原專案,哪些是新設計

### 來自原專案(`gas/Code.gs`、`index.html`)

| 項目 | 來源 |
|---|---|
| 訂單欄位:訂單編號、建立時間、狀態、取餐方式、姓名、手機、Email、門市、地址、備註、小計、運費/服務費、應付總額、更新時間 | 「訂單」工作表 14 欄 |
| 明細欄位:商品ID、品名、單價、數量、小計(品名與單價為下單當下快照) | 「訂單明細」工作表 |
| 商品欄位:ID、品名、單價、分類、上架 | 「商品」工作表 |
| 驗證規則:手機 `09` 開頭共 10 碼、Email 格式、姓名必填、宅配必填地址、1–30 個品項、每項 1–50 份、文字截 200 字、清除控制字元 | `validate_`、`price_` |
| 費用規則:內用 10%(四捨五入)、外帶 0、宅配滿 1000 免運否則 150 | `FEES` |
| 金額以資料庫商品價格重算,不信任前端 | `price_` |
| 訂單編號格式 `JF` + `yyMMdd` + 流水號 | `nextOrderNo_` |
| honeypot 欄位:機器人靜默略過 | `doPost` |
| 查單只憑訂單編號,不回傳個資 | `track_` |
| 狀態共六種(新訂單、製作中、待取餐、配送中、已完成、已取消) | `CONFIG.STATUSES` |
| 預計時間文字(15–20 分鐘 / 2–3 個工作天) | `FEES[..].eta` |

### 新設計或改變

| 項目 | 說明 |
|---|---|
| `id uuid` 主鍵 + 唯一 `order_no` | 原本訂單編號就是識別,現在 uuid 為主鍵、`order_no` 為顯示用且唯一 |
| 狀態改英文代碼 | `new / preparing / ready / delivering / done / cancelled`,畫面再轉成中文 |
| 取餐方式改代碼 | `dine / take / ship`(前端本來就送這三個值) |
| `stores` 表、`store_id` | 原本訂單存「旗艦店 — 地址」整串文字,現在存門市代碼 |
| `products` 表加入圖片、描述、標籤、排序等 | 原本只有價格在 Sheet,其餘寫死在前端 |
| `order_status_log` 狀態紀錄 | 原本只有最後狀態;現在記錄每次變更(誰、何時、從哪到哪) |
| `order_counters` 每日計數器 | 原本存在 Apps Script 的 Script Properties;並修正「第 1000 筆會重複」的問題 |
| `staff_members` 店員名單 | 取代 `ADMIN_KEY`;之後的後台以此判斷是否為店員 |
| `updated_at` 自動更新(觸發器) | 原本靠程式手動寫入 |
| 時間改為 `timestamptz`,編號日期固定用台北時間 | 原本 Sheet 時間不含時區 |
| 同一商品重複出現時合併成一列 | 原本會變成兩列 |
| 內用 / 外帶必須選門市 | 原本後端沒有強制;資料表本身仍允許 `store_id` 為空,以便遷移舊資料 |
| 資料庫層的 CHECK 限制(`total = subtotal + fee` 等)、RLS 與函式權限 | 全新 |
| `002_verify_orders.sql` 查核與回滾測試 | 全新 |

### 這次對 001 的一處修正

`create_order` 檢查數量時,原本把「格式檢查」與「轉成數字」寫在同一個 `AND`,PostgreSQL 不保證求值順序;
若直接呼叫函式並傳入 `"qty":"abc"`,可能丟出資料庫例外而不是回傳「商品數量不正確」。已改用 `CASE`,保證先檢查格式再轉型。
(經 Edge Function 呼叫時,數量一定是數字,所以不影響現有流程。)

## 這次尚未完成的串接工作

本資料夾**只完成資料庫地基**,以下都還沒做(也沒有被我執行過):

| 項目 | 現況 |
|---|---|
| 在 Supabase 實際執行 001、seed、002 | **尚未**。我沒有連線雲端資料庫;需要你在 SQL Editor 依序執行並確認 002 全部 PASS |
| 部署 Edge Functions | `supabase/functions/create-order`、`get-order` 的程式檔已存在,但**尚未部署**、也沒有確認過能運作 |
| 後台 Edge Function | **尚未建立**。資料庫已有 `update_order_status`、`staff_members`,但沒有「列出訂單」「改狀態」的 Edge Function;列出訂單也還沒有對應的資料庫查詢函式 |
| 前端改接 | `index.html`(下單、查單)與 `admin.html`(列表、改狀態)**仍然呼叫 Google Apps Script**,完全沒有改動 |
| 店員帳號 | 需要先在 Supabase Auth 建立店員帳號,再把其 `user_id` 加進 `staff_members`;後台登入流程(取代 `ADMIN_KEY`)**尚未設計** |
| 通知信 | 原 Apps Script 會寄「店家收單」與「顧客確認」信,Supabase 這邊**還沒有對應功能** |
| 查單的安全性 | `track_order` 仍**只憑訂單編號**(編號有規律、無流量限制),與原系統一致,尚未加強(例如加手機後三碼、限流) |
| 舊資料遷移 | Google Sheet 裡既有的訂單**尚未匯入**;匯入時需把中文狀態/取餐方式轉成英文代碼、把「旗艦店 — 地址」轉成門市代碼 |
| 門市營業時間 | 前端仍寫死,**未入庫**(seed.sql 已註記待確認是否需要) |
| 環境變數與金鑰 | Edge Function 需要 `ALLOWED_ORIGINS`(建議設定);`service_role` key 只放在 Edge Function 環境(Supabase 自動提供),**不可寫進任何前端檔案** |
