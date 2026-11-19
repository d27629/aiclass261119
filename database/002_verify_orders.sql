-- ============================================================================
-- 002_verify_orders.sql — 煎福鍋貼 · 建表後查核 + 虛構訂單寫入/查詢測試
--
-- 前提:已執行 database/001_create_orders.sql(seed.sql 有沒有執行都可以測)。
--
-- 怎麼跑:Supabase Dashboard → SQL Editor,【整份貼上、一次執行】(不要只選取一段)。
--         結果是「一張表」:第 0 列是總結,之後每列一個檢查項目(PASS / FAIL / SKIP)。
--
-- 這份檔案做了什麼:
--   A. 結構與權限查核(唯讀):資料表、欄位、主鍵、限制、觸發器、RLS、政策、
--      anon / authenticated / service_role 的資料表與函式權限。
--   B. 用「虛構資料」實際寫入、查詢:下單、驗證拒絕、查單、改狀態、限制條件、
--      以 anon / authenticated / service_role 身分測試權限。
--
-- 安全保證(不留下假訂單、不動既有資料):
--   * 所有寫入都在 PL/pgSQL 的「子交易」(等同 SAVEPOINT)裡進行,最後一行一定主動 RAISE,
--     讓子交易整段回滾:虛構的門市、商品、訂單、明細、狀態紀錄、店員、每日流水號計數,全部撤銷。
--     即使中途任何一步出錯,也一樣回滾。
--   * 虛構資料的代碼都以 zz_test_ 開頭,姓名為「測試訪客(虛構)」,手機 0900000001,
--     信箱 fake.customer@example.com(example.com 為保留網域),不會寄信、不會碰到真實客戶。
--   * 本檔不使用 DROP、TRUNCATE、DELETE,不修改既有資料列。
--   * 唯一的副作用:order_status_log 的流水編號(identity 序號)會往前跳幾號,
--     序號本來就不保證連續,無害。
--   * 暫時函式建立在 pg_temp(只存在於這次連線,連線結束就消失),不會留在 public。
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 輔助函式(暫時,只存在於這次連線)
-- ---------------------------------------------------------------------------

-- 回傳一筆檢查結果;p_ok 為 true=PASS、其餘=FAIL
create or replace function pg_temp.vr_chk(p_section text, p_name text, p_ok boolean, p_detail text default null)
returns jsonb language sql immutable as $$
  select jsonb_build_object('section', p_section, 'name', p_name, 'ok', coalesce(p_ok, false), 'detail', p_detail)
$$;

-- 回傳一筆「略過」結果(ok 為 null)
create or replace function pg_temp.vr_skip(p_section text, p_name text, p_detail text default null)
returns jsonb language sql immutable as $$
  select jsonb_build_object('section', p_section, 'name', p_name, 'ok', null::boolean, 'detail', p_detail)
$$;

-- 執行一段 SQL,預期它「被資料庫拒絕」且 SQLSTATE 等於 p_sqlstate;若成功執行則為 FAIL。
-- (本身就在子交易裡執行,失敗時不影響呼叫者)
create or replace function pg_temp.vr_expect(p_section text, p_name text, p_sql text, p_sqlstate text)
returns jsonb language plpgsql as $$
begin
  execute p_sql;
  return pg_temp.vr_chk(p_section, p_name, false, format('預期被拒絕(SQLSTATE %s),但執行成功了', p_sqlstate));
exception when others then
  return pg_temp.vr_chk(p_section, p_name, sqlstate = p_sqlstate, format('SQLSTATE %s:%s', sqlstate, sqlerrm));
end $$;

-- 切換成指定角色後執行 SQL,預期被拒絕(通常是 42501 permission denied)。
-- 角色切換本身失敗時回報 SKIP,避免把「切不了角色」誤判成「權限正確」。
create or replace function pg_temp.vr_expect_as(p_section text, p_name text, p_role text, p_sql text, p_sqlstate text)
returns jsonb language plpgsql as $$
begin
  begin
    execute format('set local role %I', p_role);
  exception when others then
    return pg_temp.vr_skip(p_section, p_name, format('無法切換為角色 %s:%s', p_role, sqlerrm));
  end;
  begin
    execute p_sql;
    execute 'reset role';
    return pg_temp.vr_chk(p_section, p_name, false, format('[%s] 預期被拒絕(SQLSTATE %s),但執行成功了', p_role, p_sqlstate));
  exception when others then
    execute 'reset role';
    return pg_temp.vr_chk(p_section, p_name, sqlstate = p_sqlstate, format('[%s] SQLSTATE %s:%s', p_role, sqlstate, sqlerrm));
  end;
end $$;


-- ---------------------------------------------------------------------------
-- 主查核函式(暫時)
-- ---------------------------------------------------------------------------
create or replace function pg_temp.verify_orders()
returns table (r_step integer, r_section text, r_check text, r_result text, r_detail text)
language plpgsql
as $fn$
declare
  v_res     jsonb := '[]'::jsonb;
  v_s       text;
  v_n       bigint;
  v_n2      bigint;
  v_n3      bigint;
  v_b       boolean;
  v_miss    text;

  -- 測試前的快照(用來證明測完沒留下任何東西)
  v_orders_before   bigint;
  v_items_before    bigint;
  v_log_before      bigint;
  v_counters_before bigint;

  -- 測試用變數
  v_base    jsonb;
  v_cases   jsonb;
  v_case    jsonb;
  v_r       jsonb;
  v_o       public.orders%rowtype;
  v_no1 text; v_no2 text; v_no3 text; v_no4 text; v_no5 text;
  v_id1     uuid;
  v_staff   uuid := gen_random_uuid();
  v_staff_ok boolean := false;
begin
  -- ==========================================================================
  -- A. 結構與權限查核(唯讀)
  -- ==========================================================================

  select count(*) into v_n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relkind = 'r'
     and c.relname = any (array['stores','products','orders','order_items','order_status_log','order_counters','staff_members']);
  v_res := v_res || pg_temp.vr_chk('A 結構', '7 張資料表都存在', v_n = 7, format('找到 %s / 7 張', v_n));

  select string_agg(f, ', ') into v_miss
    from unnest(array['public.create_order(jsonb)','public.track_order(text)','public.update_order_status(text,text,uuid)',
                      'public.next_order_no()','public.calc_fee(text,integer)','public.is_staff(uuid)']) f
   where to_regprocedure(f) is null;
  v_res := v_res || pg_temp.vr_chk('A 結構', '6 個函式都存在', v_miss is null, coalesce('缺少:' || v_miss, '全部存在'));

  if v_n <> 7 or v_miss is not null then
    v_res := v_res || pg_temp.vr_chk('A 結構', '後續測試', false, '資料表或函式不齊全,請先執行 001_create_orders.sql,再重跑本檔。');
    return query
      select e.ord::integer,
             e.v->>'section', e.v->>'name',
             case when (e.v->>'ok') is null then 'SKIP' when (e.v->>'ok')::boolean then 'PASS' else 'FAIL' end,
             e.v->>'detail'
        from jsonb_array_elements(v_res) with ordinality as e(v, ord)
       order by e.ord;
    return;
  end if;

  -- 主鍵:7 張表各一個
  select count(*) into v_n
    from pg_constraint k join pg_class c on c.oid = k.conrelid join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and k.contype = 'p'
     and c.relname = any (array['stores','products','orders','order_items','order_status_log','order_counters','staff_members']);
  v_res := v_res || pg_temp.vr_chk('A 結構', '7 張資料表都有主鍵', v_n = 7, format('找到 %s / 7 個主鍵', v_n));

  -- orders 欄位與型別
  select string_agg(x, ', ') into v_miss
    from unnest(array['id:uuid','order_no:text','status:text','fulfillment_type:text','customer_name:text','customer_phone:text',
                      'customer_email:text','store_id:text','ship_address:text','note:text','subtotal:int4','fee:int4','total:int4',
                      'created_at:timestamptz','updated_at:timestamptz']) x
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public' and c.table_name = 'orders'
                        and c.column_name = split_part(x, ':', 1) and c.udt_name = split_part(x, ':', 2));
  v_res := v_res || pg_temp.vr_chk('A 結構', 'orders 欄位與型別(15 欄)', v_miss is null, coalesce('缺少或型別不符:' || v_miss, '全部符合'));

  select string_agg(x, ', ') into v_miss
    from unnest(array['id:uuid','order_id:uuid','product_id:text','product_name:text','unit_price:int4','quantity:int4','line_total:int4']) x
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public' and c.table_name = 'order_items'
                        and c.column_name = split_part(x, ':', 1) and c.udt_name = split_part(x, ':', 2));
  v_res := v_res || pg_temp.vr_chk('A 結構', 'order_items 欄位與型別(7 欄)', v_miss is null, coalesce('缺少或型別不符:' || v_miss, '全部符合'));

  -- 必要限制與觸發器
  select string_agg(x, ', ') into v_miss
    from unnest(array['orders_total_ok','orders_ship_addr']) x
   where not exists (select 1 from pg_constraint k where k.conname = x and k.conrelid = 'public.orders'::regclass and k.contype = 'c');
  v_res := v_res || pg_temp.vr_chk('A 結構', 'orders 的 CHECK 限制存在', v_miss is null, coalesce('缺少:' || v_miss, 'orders_total_ok、orders_ship_addr'));

  select exists (select 1 from pg_constraint k where k.conrelid = 'public.orders'::regclass and k.contype = 'u'
                    and k.conkey = array[(select attnum from pg_attribute where attrelid = 'public.orders'::regclass and attname = 'order_no')])
    into v_b;
  v_res := v_res || pg_temp.vr_chk('A 結構', 'orders.order_no 有唯一限制', v_b);

  select string_agg(x, ', ') into v_miss
    from unnest(array['orders_set_updated_at','orders_log_status_ins','orders_log_status_upd']) x
   where not exists (select 1 from pg_trigger t where t.tgname = x and t.tgrelid = 'public.orders'::regclass and not t.tgisinternal);
  v_res := v_res || pg_temp.vr_chk('A 結構', 'orders 觸發器存在', v_miss is null, coalesce('缺少:' || v_miss, '3 個觸發器'));

  -- RLS
  select string_agg(c.relname, ', ' order by c.relname) into v_miss
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
     and c.relname = any (array['stores','products','orders','order_items','order_status_log','order_counters','staff_members']);
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', '7 張資料表都已啟用 RLS', v_miss is null, coalesce('未啟用:' || v_miss, '全部已啟用'));

  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = any (array['orders','order_items','order_status_log','order_counters','staff_members']);
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', '訂單相關 5 張表沒有任何政策(訪客無法讀寫)', v_n = 0, format('政策數:%s', v_n));

  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename = any (array['stores','products','orders','order_items','order_status_log','order_counters','staff_members'])
     and (cmd <> 'SELECT' or 'public' = any (roles::text[]));
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', '沒有任何寫入政策、也沒有對「所有人(public)」開放的政策', v_n = 0, format('不合格政策數:%s', v_n));

  -- anon / authenticated 對訂單相關資料表完全沒有權限
  select string_agg(r || '→' || t, ', ') into v_miss
    from unnest(array['anon','authenticated']) r
    cross join unnest(array['orders','order_items','order_status_log','order_counters','staff_members']) t
   where has_table_privilege(r, format('public.%I', t), 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'anon / authenticated 對 5 張訂單相關資料表沒有任何權限', v_miss is null,
                                   coalesce('仍有權限:' || v_miss, '皆為無權限'));

  -- 商品、門市:公開只能讀
  select bool_and(has_table_privilege(r, format('public.%I', t), 'SELECT')) into v_b
    from unnest(array['anon','authenticated']) r cross join unnest(array['stores','products']) t;
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'anon / authenticated 可讀 stores、products(僅上架列,由 RLS 篩選)', v_b);

  select string_agg(r || '→' || t, ', ') into v_miss
    from unnest(array['anon','authenticated']) r cross join unnest(array['stores','products']) t
   where has_table_privilege(r, format('public.%I', t), 'INSERT,UPDATE,DELETE,TRUNCATE');
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'anon / authenticated 不能寫入 stores、products', v_miss is null, coalesce('仍可寫:' || v_miss, '皆為唯讀'));

  -- service_role:只拿到必要權限,沒有 DELETE / TRUNCATE
  select bool_and(has_table_privilege('service_role', 'public.orders', p)) into v_b from unnest(array['SELECT','INSERT','UPDATE']) p;
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'service_role 對 orders:有 SELECT、INSERT、UPDATE', v_b);

  select bool_or(has_table_privilege('service_role', format('public.%I', t), p)) into v_b
    from unnest(array['stores','products','orders','order_items','order_status_log','order_counters','staff_members']) t
    cross join unnest(array['DELETE','TRUNCATE']) p;
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'service_role 對 7 張表都沒有 DELETE / TRUNCATE(不能清除訂單)', not v_b);

  select bool_and(has_table_privilege('service_role', 'public.order_items', 'SELECT') and has_table_privilege('service_role', 'public.order_items', 'INSERT')
                  and not has_table_privilege('service_role', 'public.order_items', 'UPDATE')
                  and has_table_privilege('service_role', 'public.order_status_log', 'SELECT')
                  and not has_table_privilege('service_role', 'public.order_status_log', 'INSERT')
                  and has_table_privilege('service_role', 'public.staff_members', 'SELECT')
                  and not has_table_privilege('service_role', 'public.staff_members', 'INSERT')) into v_b;
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'service_role 對明細/狀態紀錄/店員名單只有最小必要權限', v_b,
                                   '明細:讀+寫入不可改;狀態紀錄:只讀(由觸發器寫);店員名單:只讀');

  -- 函式執行權限
  select string_agg(r || '→' || f, ', ') into v_miss
    from unnest(array['anon','authenticated']) r
    cross join unnest(array['public.create_order(jsonb)','public.track_order(text)','public.update_order_status(text,text,uuid)',
                            'public.next_order_no()','public.calc_fee(text,integer)','public.is_staff(uuid)']) f
   where has_function_privilege(r, f, 'EXECUTE');
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'anon / authenticated 不能執行下單、查單、改狀態等函式', v_miss is null,
                                   coalesce('仍可執行:' || v_miss, '皆不可執行'));

  select bool_and(has_function_privilege('service_role', f, 'EXECUTE')) into v_b
    from unnest(array['public.create_order(jsonb)','public.track_order(text)','public.update_order_status(text,text,uuid)',
                      'public.next_order_no()','public.calc_fee(text,integer)','public.is_staff(uuid)']) f;
  v_res := v_res || pg_temp.vr_chk('A RLS 與權限', 'service_role 可執行這 6 個函式', v_b);

  -- 種子資料(資訊性:沒跑 seed 只會 SKIP,不影響 B 區測試,因為 B 區用自己的虛構門市與商品)
  select count(*) into v_n from public.stores;
  select count(*) into v_n2 from public.products;
  if v_n >= 3 and v_n2 >= 19 then
    v_res := v_res || pg_temp.vr_chk('A 資料', '門市與商品種子資料已匯入', true, format('stores %s 筆、products %s 筆', v_n, v_n2));
  else
    v_res := v_res || pg_temp.vr_skip('A 資料', '門市與商品種子資料已匯入', format('stores %s 筆、products %s 筆;尚未執行 supabase/seed.sql(預期 3 與 19)', v_n, v_n2));
  end if;


  -- ==========================================================================
  -- B. 虛構訂單測試(整段在子交易內,結尾一定回滾)
  -- ==========================================================================

  select count(*) into v_orders_before from public.orders;
  select count(*) into v_items_before from public.order_items;
  select count(*) into v_log_before from public.order_status_log;
  select coalesce(sum(last_seq), 0) into v_counters_before from public.order_counters;

  begin  -- ── 子交易開始 ──────────────────────────────────────────────

    -- 虛構門市與商品(以 postgres 身分建立;與真實資料完全分離)
    insert into public.stores (id, name, address, phone, sort_order, is_active)
    values ('zz_test_store', '【測試】虛構門市', '(虛構地址)', null, 9999, true);
    insert into public.products (id, name, price, category_key, category_label, sort_order, is_active) values
      ('zz_test_a',   '【測試】商品A',     100, 'test', '測試', 9991, true),
      ('zz_test_b',   '【測試】商品B',     250, 'test', '測試', 9992, true),
      ('zz_test_off', '【測試】下架商品',   10, 'test', '測試', 9993, false);

    v_base := jsonb_build_object(
      'mode', 'take', 'name', '測試訪客(虛構)', 'phone', '0900000001', 'email', 'fake.customer@example.com',
      'store_id', 'zz_test_store', 'note', '虛構測試訂單,不會成立',
      'items', jsonb_build_array(jsonb_build_object('id', 'zz_test_a', 'qty', 2), jsonb_build_object('id', 'zz_test_b', 'qty', 1)));

    -- ── B1 外帶(用 service_role 身分呼叫,同時驗證後端權限夠用)──
    set local role service_role;
    v_r := public.create_order(v_base);
    reset role;
    v_no1 := v_r->>'order_no';
    v_res := v_res || pg_temp.vr_chk('B 下單', '外帶:create_order 回傳 ok=true 與訂單編號', (v_r->>'ok') = 'true' and v_no1 is not null, v_r::text);
    v_res := v_res || pg_temp.vr_chk('B 下單', '訂單編號格式 JF + 台北日期(yyMMdd) + 流水號',
                                     v_no1 ~ '^JF[0-9]{6}-[0-9]{3,}$' and substring(v_no1 from 3 for 6) = to_char(now() at time zone 'Asia/Taipei', 'YYMMDD'), v_no1);
    select * into v_o from public.orders where order_no = v_no1;
    v_id1 := v_o.id;
    v_res := v_res || pg_temp.vr_chk('B 下單', '訂單已寫入:預設狀態 new、取餐方式 take、門市代碼', v_o.status = 'new' and v_o.fulfillment_type = 'take' and v_o.store_id = 'zz_test_store',
                                     format('status=%s type=%s store=%s', v_o.status, v_o.fulfillment_type, v_o.store_id));
    v_res := v_res || pg_temp.vr_chk('B 下單', '金額由商品表重算:小計 450、費用 0、總額 450(100×2+250×1)', (v_o.subtotal, v_o.fee, v_o.total) = (450, 0, 450),
                                     format('subtotal=%s fee=%s total=%s', v_o.subtotal, v_o.fee, v_o.total));
    v_res := v_res || pg_temp.vr_chk('B 下單', '顧客欄位正確寫入;外帶沒有地址', v_o.customer_name = '測試訪客(虛構)' and v_o.customer_phone = '0900000001'
                                     and v_o.customer_email = 'fake.customer@example.com' and v_o.ship_address is null);
    v_res := v_res || pg_temp.vr_chk('B 下單', 'id、created_at、updated_at 預設值已自動產生', v_o.id is not null and v_o.created_at is not null and v_o.updated_at is not null);

    select count(*), bool_or(product_id = 'zz_test_a' and product_name = '【測試】商品A' and unit_price = 100 and quantity = 2 and line_total = 200)
      into v_n, v_b from public.order_items where order_id = v_id1;
    v_res := v_res || pg_temp.vr_chk('B 下單', '明細 2 列,且含品名/單價/數量/小計快照', v_n = 2 and v_b, format('明細列數 %s', v_n));

    select count(*), bool_or(from_status is null and to_status = 'new') into v_n, v_b from public.order_status_log where order_id = v_id1;
    v_res := v_res || pg_temp.vr_chk('B 下單', '觸發器已寫入第一筆狀態紀錄(null → new)', v_n = 1 and v_b, format('狀態紀錄 %s 筆', v_n));

    -- ── B2 內用:服務費 10% ──
    set local role service_role;
    v_r := public.create_order(v_base || '{"mode":"dine","items":[{"id":"zz_test_a","qty":3},{"id":"zz_test_b","qty":1}]}'::jsonb);
    reset role;
    v_no2 := v_r->>'order_no';
    select * into v_o from public.orders where order_no = v_no2;
    v_res := v_res || pg_temp.vr_chk('B 下單', '內用:小計 550、服務費 55(10%)、總額 605', (v_o.subtotal, v_o.fee, v_o.total) = (550, 55, 605) and (v_r->>'total')::int = 605,
                                     format('subtotal=%s fee=%s total=%s', v_o.subtotal, v_o.fee, v_o.total));

    -- ── B3 宅配未滿 1000:運費 150;就算傳了 store_id 也會被清空;地址必存 ──
    set local role service_role;
    v_r := public.create_order(v_base || '{"mode":"ship","address":"(虛構)台北市測試路 1 號","items":[{"id":"zz_test_a","qty":2}]}'::jsonb);
    reset role;
    v_no3 := v_r->>'order_no';
    select * into v_o from public.orders where order_no = v_no3;
    v_res := v_res || pg_temp.vr_chk('B 下單', '宅配未滿 1000:運費 150、總額 350', (v_o.subtotal, v_o.fee, v_o.total) = (200, 150, 350),
                                     format('subtotal=%s fee=%s total=%s', v_o.subtotal, v_o.fee, v_o.total));
    v_res := v_res || pg_temp.vr_chk('B 下單', '宅配:地址已存、門市代碼被清為 null', v_o.ship_address = '(虛構)台北市測試路 1 號' and v_o.store_id is null,
                                     format('address=%s store=%s', v_o.ship_address, v_o.store_id));

    -- ── B4 宅配滿 1000:免運 ──
    set local role service_role;
    v_r := public.create_order(v_base || '{"mode":"ship","address":"(虛構)台北市測試路 1 號","items":[{"id":"zz_test_b","qty":4}]}'::jsonb);
    reset role;
    v_no4 := v_r->>'order_no';
    select * into v_o from public.orders where order_no = v_no4;
    v_res := v_res || pg_temp.vr_chk('B 下單', '宅配滿 1000:免運(運費 0、總額 1000)', (v_o.subtotal, v_o.fee, v_o.total) = (1000, 0, 1000),
                                     format('subtotal=%s fee=%s total=%s', v_o.subtotal, v_o.fee, v_o.total));

    -- ── B5 同商品重複出現 → 合併成一列 ──
    set local role service_role;
    v_r := public.create_order(v_base || '{"items":[{"id":"zz_test_a","qty":1},{"id":"zz_test_a","qty":2}]}'::jsonb);
    reset role;
    v_no5 := v_r->>'order_no';
    select * into v_o from public.orders where order_no = v_no5;
    select count(*), bool_or(quantity = 3 and line_total = 300) into v_n, v_b from public.order_items where order_id = v_o.id;
    v_res := v_res || pg_temp.vr_chk('B 下單', '同商品出現兩次 → 合併為 1 列、數量 3、小計 300', v_n = 1 and v_b, format('明細列數 %s', v_n));

    select count(distinct x) into v_n from unnest(array[v_no1, v_no2, v_no3, v_no4, v_no5]) x;
    v_res := v_res || pg_temp.vr_chk('B 下單', '連續 5 張訂單的訂單編號互不重複', v_n = 5, format('%s / %s / %s / %s / %s', v_no1, v_no2, v_no3, v_no4, v_no5));

    -- ── B6 價格快照:商品之後改價,舊訂單明細不變 ──
    update public.products set price = 999 where id = 'zz_test_a';
    select unit_price into v_n from public.order_items where order_id = v_id1 and product_id = 'zz_test_a';
    v_res := v_res || pg_temp.vr_chk('B 下單', '商品改價後,舊訂單明細單價仍為下單當時的 100(快照)', v_n = 100, format('unit_price=%s', v_n));
    update public.products set price = 100 where id = 'zz_test_a';

    -- ── B7 各種不合法輸入:必須被拒絕、且不寫入任何資料 ──
    select count(*) into v_n from public.orders;   -- 此時應為 before + 5
    v_cases := jsonb_build_array(
      jsonb_build_object('name', '取餐方式不正確',   'patch', '{"mode":"fly"}'::jsonb,                       'error', '取餐方式不正確'),
      jsonb_build_object('name', '姓名空白',         'patch', '{"name":"   "}'::jsonb,                       'error', '請填寫姓名'),
      jsonb_build_object('name', '手機格式錯誤',     'patch', '{"phone":"123"}'::jsonb,                      'error', '手機號碼格式不正確'),
      jsonb_build_object('name', '手機不是 09 開頭', 'patch', '{"phone":"0812345678"}'::jsonb,               'error', '手機號碼格式不正確'),
      jsonb_build_object('name', 'Email 格式錯誤',   'patch', '{"email":"abc"}'::jsonb,                      'error', 'Email 格式不正確'),
      jsonb_build_object('name', '宅配未填地址',     'patch', '{"mode":"ship","address":""}'::jsonb,         'error', '宅配需填寫地址'),
      jsonb_build_object('name', '外帶未選門市',     'patch', '{"store_id":null}'::jsonb,                    'error', '請選擇取餐門市'),
      jsonb_build_object('name', '門市不存在',       'patch', '{"store_id":"nope"}'::jsonb,                  'error', '請選擇取餐門市'),
      jsonb_build_object('name', '購物車為空',       'patch', '{"items":[]}'::jsonb,                         'error', '購物車內容不正確'),
      jsonb_build_object('name', '購物車不是陣列',   'patch', '{"items":"x"}'::jsonb,                        'error', '購物車內容不正確'),
      jsonb_build_object('name', '超過 30 個品項',   'patch', jsonb_build_object('items', (select jsonb_agg(jsonb_build_object('id', 'zz_test_a', 'qty', 1)) from generate_series(1, 31))),
                                                                                                            'error', '購物車內容不正確'),
      jsonb_build_object('name', '數量 0',           'patch', '{"items":[{"id":"zz_test_a","qty":0}]}'::jsonb,   'error', '商品數量不正確'),
      jsonb_build_object('name', '數量 51',          'patch', '{"items":[{"id":"zz_test_a","qty":51}]}'::jsonb,  'error', '商品數量不正確'),
      jsonb_build_object('name', '數量為負數',       'patch', '{"items":[{"id":"zz_test_a","qty":-1}]}'::jsonb,  'error', '商品數量不正確'),
      jsonb_build_object('name', '數量不是數字',     'patch', '{"items":[{"id":"zz_test_a","qty":"abc"}]}'::jsonb, 'error', '商品數量不正確'),
      jsonb_build_object('name', '同商品合計超過 50','patch', '{"items":[{"id":"zz_test_a","qty":30},{"id":"zz_test_a","qty":30}]}'::jsonb, 'error', '商品數量不正確'),
      jsonb_build_object('name', '商品已下架',       'patch', '{"items":[{"id":"zz_test_off","qty":1}]}'::jsonb, 'error', '部分商品已下架或不存在'),
      jsonb_build_object('name', '商品不存在',       'patch', '{"items":[{"id":"nope","qty":1}]}'::jsonb,        'error', '部分商品已下架或不存在')
    );
    for v_case in select * from jsonb_array_elements(v_cases) loop
      set local role service_role;
      v_r := public.create_order(v_base || (v_case->'patch'));
      reset role;
      v_res := v_res || pg_temp.vr_chk('B 拒絕不合法輸入', v_case->>'name', (v_r->>'ok') = 'false' and (v_r->>'error') = (v_case->>'error'),
                                       format('回傳:%s', v_r->>'error'));
    end loop;

    -- honeypot:機器人欄位有值 → 靜默略過、不寫入
    set local role service_role;
    v_r := public.create_order(v_base || '{"hp":"bot"}'::jsonb);
    reset role;
    v_res := v_res || pg_temp.vr_chk('B 拒絕不合法輸入', 'honeypot 欄位有值:回傳 JF-IGNORED、不寫入', (v_r->>'ok') = 'true' and (v_r->>'order_no') = 'JF-IGNORED', v_r::text);

    select count(*) - v_n into v_n2 from public.orders;
    v_res := v_res || pg_temp.vr_chk('B 拒絕不合法輸入', '以上被拒絕/略過的請求都沒有新增訂單', v_n2 = 0, format('多出 %s 筆', v_n2));

    -- ── B8 查單 track_order:只回品項/金額/狀態,不含個資 ──
    set local role service_role;
    v_r := public.track_order(v_no1);
    reset role;
    v_res := v_res || pg_temp.vr_chk('B 查單', 'track_order:ok、狀態 new、取餐方式 take、總額 450、2 個品項',
                                     (v_r->>'ok') = 'true' and v_r->>'status' = 'new' and v_r->>'mode' = 'take' and (v_r->>'total')::int = 450 and jsonb_array_length(v_r->'items') = 2,
                                     left(v_r::text, 300));
    v_res := v_res || pg_temp.vr_chk('B 查單', 'track_order 回傳內容不含姓名、手機、Email、地址、備註',
                                     position('測試訪客' in v_r::text) = 0 and position('0900000001' in v_r::text) = 0 and position('example.com' in v_r::text) = 0
                                     and position('虛構測試訂單' in v_r::text) = 0
                                     and v_r->'customer_name' is null and v_r->'customer_phone' is null and v_r->'ship_address' is null and v_r->'note' is null);
    set local role service_role;
    v_r := public.track_order(lower(v_no1));
    reset role;
    v_res := v_res || pg_temp.vr_chk('B 查單', '訂單編號大小寫不拘(小寫也查得到)', (v_r->>'ok') = 'true', left(v_r::text, 120));
    set local role service_role;
    v_r := public.track_order('JF000101-999');
    reset role;
    v_res := v_res || pg_temp.vr_chk('B 查單', '不存在的訂單編號 → 查無此訂單', (v_r->>'ok') = 'false' and (v_r->>'error') = '查無此訂單', v_r::text);
    set local role service_role;
    v_r := public.track_order('abc');
    reset role;
    v_res := v_res || pg_temp.vr_chk('B 查單', '格式錯誤的訂單編號 → 格式不正確', (v_r->>'ok') = 'false' and (v_r->>'error') like '訂單編號格式不正確%', v_r::text);

    -- ── B9 後台改狀態 update_order_status ──
    set local role service_role;
    v_r := public.update_order_status(v_no1, 'preparing', gen_random_uuid());
    reset role;
    select status into v_s from public.orders where id = v_id1;
    v_res := v_res || pg_temp.vr_chk('B 改狀態', '非店員不能改狀態(AUTH),狀態維持 new', (v_r->>'ok') = 'false' and (v_r->>'code') = 'AUTH' and v_s = 'new', format('%s / status=%s', v_r::text, v_s));

    begin
      insert into auth.users (id) values (v_staff);
      insert into public.staff_members (user_id, display_name) values (v_staff, '【測試】虛構店員');
      v_staff_ok := true;
    exception when others then
      v_res := v_res || pg_temp.vr_skip('B 改狀態', '建立虛構店員(auth.users + staff_members)', format('略過店員相關測試。原因:%s', sqlerrm));
    end;

    if v_staff_ok then
      set local role service_role;
      v_r := public.update_order_status(v_no1, 'xxx', v_staff);
      reset role;
      v_res := v_res || pg_temp.vr_chk('B 改狀態', '店員傳入不合法狀態 → 狀態不正確', (v_r->>'ok') = 'false' and (v_r->>'error') = '狀態不正確', v_r::text);

      set local role service_role;
      v_r := public.update_order_status('JF000101-999', 'preparing', v_staff);
      reset role;
      v_res := v_res || pg_temp.vr_chk('B 改狀態', '店員改不存在的訂單 → 找不到訂單', (v_r->>'ok') = 'false' and (v_r->>'error') like '找不到訂單%', v_r::text);

      set local role service_role;
      v_r := public.update_order_status(v_no1, 'preparing', v_staff);
      reset role;
      select * into v_o from public.orders where id = v_id1;
      v_res := v_res || pg_temp.vr_chk('B 改狀態', '店員改成 preparing:回傳 ok、資料已更新', (v_r->>'ok') = 'true' and v_o.status = 'preparing', format('%s / status=%s', v_r::text, v_o.status));
      v_res := v_res || pg_temp.vr_chk('B 改狀態', 'updated_at 由觸發器更新(不早於 created_at)', v_o.updated_at >= v_o.created_at, format('created=%s updated=%s', v_o.created_at, v_o.updated_at));
      select count(*), bool_or(from_status = 'new' and to_status = 'preparing' and changed_by = v_staff) into v_n, v_b from public.order_status_log where order_id = v_id1;
      v_res := v_res || pg_temp.vr_chk('B 改狀態', '狀態紀錄共 2 筆,新增的一筆記錄了 new → preparing 與操作店員', v_n = 2 and v_b, format('狀態紀錄 %s 筆', v_n));
    else
      v_res := v_res || pg_temp.vr_skip('B 改狀態', '店員改狀態、updated_at、狀態紀錄(3 項)', '因無法建立虛構店員而略過;不代表有錯');
    end if;

    -- ── B10 資料庫限制:直接寫入不合法資料必須被擋(以 postgres 身分,專測 CHECK/UNIQUE/FK)──
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', 'total ≠ subtotal + fee 被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-901','take','測試','0900000001','zz_test_store',100,0,999)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '不合法的 status 被擋',
      $q$insert into public.orders (order_no, status, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-902','xxx','take','測試','0900000001','zz_test_store',100,0,100)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '不合法的取餐方式被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-903','fly','測試','0900000001','zz_test_store',100,0,100)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '手機格式錯誤被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-904','take','測試','12345','zz_test_store',100,0,100)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', 'Email 格式錯誤被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, customer_email, store_id, subtotal, fee, total)
         values ('JF000101-905','take','測試','0900000001','abc','zz_test_store',100,0,100)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '姓名空白被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-906','take','   ','0900000001','zz_test_store',100,0,100)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '宅配沒有地址被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, subtotal, fee, total)
         values ('JF000101-907','ship','測試','0900000001',100,150,250)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '金額為負數被擋',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-908','take','測試','0900000001','zz_test_store',-1,0,-1)$q$, '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '訂單編號重複被擋(唯一限制)',
      format($q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
                values (%L,'take','測試','0900000001','zz_test_store',100,0,100)$q$, v_no1), '23505');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '不存在的門市代碼被擋(外鍵)',
      $q$insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, store_id, subtotal, fee, total)
         values ('JF000101-909','take','測試','0900000001','nope',100,0,100)$q$, '23503');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '明細數量 0 被擋',
      format($q$insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
                values (%L,'zz_test_a','x',100,0,0)$q$, v_id1), '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '明細數量 51 被擋',
      format($q$insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
                values (%L,'zz_test_a','x',100,51,5100)$q$, v_id1), '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '明細小計 ≠ 單價 × 數量 被擋',
      format($q$insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
                values (%L,'zz_test_a','x',100,2,1)$q$, v_id1), '23514');
    v_res := v_res || pg_temp.vr_expect('B 資料庫限制', '明細指向不存在的訂單被擋(外鍵)',
      $q$insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
         values (gen_random_uuid(),'zz_test_a','x',100,1,100)$q$, '23503');

    -- ── B11 權限:訪客與一般登入者碰不到訂單;後端只有必要權限 ──
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 讀 orders 被拒', 'anon', 'select count(*) from public.orders', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 寫 orders 被拒', 'anon', 'insert into public.orders default values', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 改 orders 被拒', 'anon', 'update public.orders set note = note where false', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 讀 order_items 被拒', 'anon', 'select count(*) from public.order_items', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 讀 order_status_log 被拒', 'anon', 'select count(*) from public.order_status_log', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 讀 order_counters 被拒', 'anon', 'select count(*) from public.order_counters', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 讀 staff_members 被拒', 'anon', 'select count(*) from public.staff_members', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'authenticated 讀 orders 被拒', 'authenticated', 'select count(*) from public.orders', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'authenticated 寫 orders 被拒', 'authenticated', 'insert into public.orders default values', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'authenticated 讀 order_items 被拒', 'authenticated', 'select count(*) from public.order_items', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 不能執行 create_order', 'anon', $q$select public.create_order('{}'::jsonb)$q$, '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 不能執行 track_order', 'anon', $q$select public.track_order('JF000101-001')$q$, '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 不能執行 update_order_status', 'anon',
                                           $q$select public.update_order_status('JF000101-001','done',gen_random_uuid())$q$, '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'authenticated 不能執行 create_order', 'authenticated', $q$select public.create_order('{}'::jsonb)$q$, '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 不能改商品', 'anon', 'update public.products set price = 1 where false', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'anon 不能新增門市', 'anon',
                                           $q$insert into public.stores (id, name, address) values ('zz_x','x','x')$q$, '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'service_role 不能直接寫 order_status_log(只能靠觸發器)', 'service_role',
                                           $q$insert into public.order_status_log (order_id, to_status) values (gen_random_uuid(),'new')$q$, '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'service_role 不能改 order_items', 'service_role',
                                           'update public.order_items set quantity = quantity where false', '42501');
    v_res := v_res || pg_temp.vr_expect_as('B 權限', 'service_role 不能新增店員(店員由管理者在 Dashboard 維護)', 'service_role',
                                           $q$insert into public.staff_members (user_id) values (gen_random_uuid())$q$, '42501');

    -- anon 可讀商品/門市,但 RLS 只讓「上架」的列出現
    begin
      set local role anon;
      select count(*) filter (where id = 'zz_test_a'), count(*) filter (where id = 'zz_test_off') into v_n, v_n2 from public.products;
      select count(*) into v_n3 from public.stores where id = 'zz_test_store';
      reset role;
      v_res := v_res || pg_temp.vr_chk('B 權限', 'anon 讀 products:看得到上架商品、看不到下架商品(RLS 篩選)', v_n = 1 and v_n2 = 0, format('上架可見 %s、下架可見 %s', v_n, v_n2));
      v_res := v_res || pg_temp.vr_chk('B 權限', 'anon 讀 stores:看得到營業中門市', v_n3 = 1, format('可見 %s', v_n3));
    exception when others then
      reset role;
      if sqlerrm ilike '%set role%' then
        v_res := v_res || pg_temp.vr_skip('B 權限', 'anon 讀 products / stores(RLS 篩選)', format('無法切換為 anon:%s', sqlerrm));
      else
        v_res := v_res || pg_temp.vr_chk('B 權限', 'anon 讀 products / stores(RLS 篩選)', false, format('SQLSTATE %s:%s', sqlstate, sqlerrm));
      end if;
    end;

    -- ★ 一律回滾:以上所有虛構資料全部撤銷
    raise exception '虛構測試資料回滾' using errcode = 'VR001';

  exception
    when sqlstate 'VR001' then
      null;  -- 預期中的回滾
    when others then
      v_res := v_res || pg_temp.vr_chk('B 交易測試', '測試中途發生未預期錯誤(資料仍已回滾)', false, format('SQLSTATE %s:%s', sqlstate, sqlerrm));
  end;  -- ── 子交易結束(已回滾)──────────────────────────────────────
  reset role;

  -- ==========================================================================
  -- C. 回滾確認:測完沒有留下任何東西
  -- ==========================================================================
  select count(*) into v_n from public.orders;
  v_res := v_res || pg_temp.vr_chk('C 回滾確認', 'orders 筆數與測試前相同', v_n = v_orders_before, format('測試前 %s、現在 %s', v_orders_before, v_n));
  select count(*) into v_n from public.order_items;
  v_res := v_res || pg_temp.vr_chk('C 回滾確認', 'order_items 筆數與測試前相同', v_n = v_items_before, format('測試前 %s、現在 %s', v_items_before, v_n));
  select count(*) into v_n from public.order_status_log;
  v_res := v_res || pg_temp.vr_chk('C 回滾確認', 'order_status_log 筆數與測試前相同', v_n = v_log_before, format('測試前 %s、現在 %s', v_log_before, v_n));
  select coalesce(sum(last_seq), 0) into v_n from public.order_counters;
  v_res := v_res || pg_temp.vr_chk('C 回滾確認', '每日流水號計數與測試前相同(沒有吃掉真實訂單編號)', v_n = v_counters_before, format('測試前 %s、現在 %s', v_counters_before, v_n));
  select (select count(*) from public.stores where id like 'zz\_test%')
       + (select count(*) from public.products where id like 'zz\_test%')
       + (select count(*) from public.orders where customer_phone = '0900000001' or customer_name like '測試訪客%')
    into v_n;
  v_res := v_res || pg_temp.vr_chk('C 回滾確認', '沒有殘留虛構門市、商品、訂單', v_n = 0, format('殘留 %s 筆', v_n));
  select count(*) into v_n from public.staff_members where display_name like '【測試】%';
  v_res := v_res || pg_temp.vr_chk('C 回滾確認', '沒有殘留虛構店員', v_n = 0, format('殘留 %s 筆', v_n));

  -- ==========================================================================
  -- 輸出:第 0 列總結,之後依序列出每個檢查
  -- ==========================================================================
  return query
    select 0, '總結', '全部檢查項目',
           case when count(*) filter (where s.st = 'FAIL') = 0 then 'ALL PASS' else 'HAS FAIL' end,
           format('共 %s 項:PASS %s、FAIL %s、SKIP %s', count(*), count(*) filter (where s.st = 'PASS'),
                  count(*) filter (where s.st = 'FAIL'), count(*) filter (where s.st = 'SKIP'))
      from (select case when (e.v->>'ok') is null then 'SKIP' when (e.v->>'ok')::boolean then 'PASS' else 'FAIL' end as st
              from jsonb_array_elements(v_res) as e(v)) s
    union all
    select e.ord::integer, e.v->>'section', e.v->>'name',
           case when (e.v->>'ok') is null then 'SKIP' when (e.v->>'ok')::boolean then 'PASS' else 'FAIL' end,
           e.v->>'detail'
      from jsonb_array_elements(v_res) with ordinality as e(v, ord)
    order by 1;
end
$fn$;


-- ---------------------------------------------------------------------------
-- 執行查核(這一行的結果就是你要看的那張表)
-- ---------------------------------------------------------------------------
select * from pg_temp.verify_orders();
