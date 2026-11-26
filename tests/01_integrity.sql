\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset fieldsep ' | '
\encoding UTF8

-- Запускать в свежей тестовой базе после восстановления исправленной схемы.
-- Результаты проверок выводятся перед ROLLBACK. Код выхода 3 означает расхождения.
BEGIN;
SET LOCAL search_path TO public, pg_catalog;
SET LOCAL client_min_messages TO warning;

CREATE TEMP TABLE audit_results (
    code text PRIMARY KEY, result text NOT NULL, detail text NOT NULL
);

CREATE FUNCTION pg_temp.assert_true(ok boolean, detail text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING ERRCODE = 'P1001', MESSAGE = detail;
    END IF;
END;
$$;

-- Каждый сценарий откатывается даже при успехе. Ошибки проверяются по SQLSTATE
-- и, где применимо, по точному имени ограничения или фрагменту сообщения.
CREATE FUNCTION pg_temp.test(
    code text, statement text, expected_state text DEFAULT NULL,
    expected_constraint text DEFAULT NULL, expected_message text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual_state text;
    actual_constraint text;
    actual_message text;
    passed boolean;
BEGIN
    BEGIN
        EXECUTE statement;
        RAISE EXCEPTION USING ERRCODE = 'P1000', MESSAGE = 'команда завершилась успешно';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE,
            actual_constraint = CONSTRAINT_NAME, actual_message = MESSAGE_TEXT;
    END;
    passed := actual_state = COALESCE(expected_state, 'P1000')
        AND (expected_constraint IS NULL OR actual_constraint = expected_constraint)
        AND (expected_message IS NULL OR strpos(actual_message, expected_message) > 0);
    INSERT INTO pg_temp.audit_results VALUES (
        code, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END,
        concat_ws(' ', CASE WHEN NOT passed AND expected_state IS NOT NULL
                            THEN 'ожидали ' || expected_state || ', получено' END,
                  CASE WHEN actual_state <> 'P1000' THEN actual_state END,
                  NULLIF(actual_constraint, ''), actual_message)
    );
END;
$$;

DO $inventory$
BEGIN
    PERFORM pg_temp.test('INV.tables', $t$
        SELECT pg_temp.assert_true(
            array_agg(relname::text ORDER BY relname::text COLLATE "C") = ARRAY[
                'clients','consultants','frames','glasses','lenses','optometrists','orders',
                'prescriptions','repair','sales','suppliers','supply','supply_frames',
                'supply_glasses','supply_lenses'], 'состав таблиц отличается')
        FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
    $t$);
    PERFORM pg_temp.test('INV.empty', $t$
        DO $b$ DECLARE t record; rows_found bigint;
        BEGIN
            FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
                EXECUTE format('SELECT count(*) FROM public.%I', t.tablename) INTO rows_found;
                PERFORM pg_temp.assert_true(rows_found = 0, 'таблица содержит данные: ' || t.tablename);
            END LOOP;
        END $b$
    $t$);
    PERFORM pg_temp.test('INV.routines', $t$
        SELECT pg_temp.assert_true(
            count(*) FILTER (WHERE prokind = 'f') = 14
            AND count(*) FILTER (WHERE prokind = 'p') = 7,'ожидались 14 функций и 7 процедур')
        FROM pg_proc WHERE pronamespace = 'public'::regnamespace
    $t$);
    PERFORM pg_temp.test('INV.triggers', $t$
        SELECT pg_temp.assert_true(
            array_agg(tgname::text ORDER BY tgname::text COLLATE "C") = ARRAY[
                'trg_auto_replenish_before_sale','trg_prevent_negative_frame',
                'trg_prevent_negative_glasses','trg_prevent_negative_lens','trg_protect_sold_order',
                'trg_sale_stock','trg_sale_sum_calc','trg_upd_order']
            AND bool_and(tgenabled = 'O'), 'состав или режим триггеров отличается')
        FROM pg_trigger JOIN pg_class ON pg_class.oid = tgrelid
        WHERE relnamespace = 'public'::regnamespace AND NOT tgisinternal
    $t$);
    PERFORM pg_temp.test('INV.sequences', $t$
        SELECT pg_temp.assert_true(count(*) = 12, 'ожидались 12 последовательностей')
        FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'S'
    $t$);
    PERFORM pg_temp.test('INV.constraints', $t$
        SELECT pg_temp.assert_true(count(*) FILTER (WHERE contype = 'p') = 15
            AND count(*) FILTER (WHERE contype = 'f') = 21
            AND count(*) FILTER (WHERE contype = 'u') = 6
            AND count(*) FILTER (WHERE contype = 'c') = 24
            AND count(*) FILTER (WHERE contype = 'n') = 47
            AND bool_and(convalidated), 'состав или состояние ограничений отличается')
        FROM pg_constraint WHERE connamespace = 'public'::regnamespace
    $t$);
END;
$inventory$;

-- Во всех 15 таблицах используются только специально созданные записи.
INSERT INTO clients VALUES (-101,'Тест Клиент 1','0000000001','client1@example.invalid'),
                           (-102,'Тест Клиент 2',NULL,NULL);
INSERT INTO consultants(id_consultant,name) VALUES (-101,'Тест Консультант');
INSERT INTO optometrists(id_optometrist,name) VALUES (-101,'Тест Оптометрист'),(-102,'Тест Оптометрист 2');
INSERT INTO frames(id_frame,name,price,quantity) VALUES
    (-101,'Тест Оправа',100,8),(-102,'Тест Оправа 0',110,0),(-103,'Тест Оправа 3',120,0);
INSERT INTO lenses(id_lens,type,price,quantity) VALUES
    (-101,'Тест Линза',40,8),(-102,'Тест Линза 0',55,0),(-103,'Тест Линза 3',65,0);
INSERT INTO glasses(id_glasses,id_frame,id_lens,price,quantity) VALUES
    (-101,-101,-101,250,8),(-102,-102,-102,290,0),(-103,-103,-103,320,0);
INSERT INTO prescriptions VALUES (-101,-101,0,0,60,DATE '2024-01-01',-101),
                                 (-102,-102,0,0,61,DATE '2024-01-01',-102);
INSERT INTO orders(id_order,id_client,order_type,id_frame,id_lens,id_glasses,id_presc,status,id_optometrist,id_consultant) VALUES
    (-101,-101,'ready',NULL,NULL,-101,NULL,'создан',NULL,-101),
    (-102,-101,'custom',-101,-101,NULL,-101,'создан',-101,-101),
    (-103,-101,'ready',NULL,NULL,-102,NULL,'создан',NULL,-101),
    (-104,-101,'custom',-102,-102,NULL,-101,'создан',-101,-101),
    (-105,-101,'ready',NULL,NULL,-103,NULL,'создан',NULL,-101),
    (-106,-101,'ready',NULL,NULL,-101,NULL,'готов',NULL,-101),
    (-107,-101,'ready',NULL,NULL,-101,NULL,'создан',NULL,-101),
    (-108,-101,'ready',NULL,NULL,-101,NULL,'создан',NULL,-101),
    (-109,-101,'custom',-101,-101,NULL,-101,'готов',-101,-101),
    (-110,-101,'ready',NULL,NULL,-101,NULL,'создан',NULL,-101),
    (-111,-101,'ready',NULL,NULL,-101,NULL,'создан',NULL,-101);
INSERT INTO repair VALUES (-101,-101,'Тест ремонт',25,'принят',CURRENT_DATE,NULL);
INSERT INTO sales VALUES (-101,-106,DATE '2024-02-01',12345);
INSERT INTO suppliers VALUES (-101,'Тест Поставщик',NULL,NULL);
INSERT INTO supply VALUES (-101,-101,DATE '2024-01-01',100);
INSERT INTO supply_frames VALUES (-101,-101,1,50);
INSERT INTO supply_lenses VALUES (-101,-101,1,20);
INSERT INTO supply_glasses VALUES (-101,-101,1,30);

DO $constraints$
DECLARE item record;
BEGIN
    -- Актуальная тестовая строка берётся из каждой таблицы. Первая запись
    -- нарушает PK, а замена по одному столбцу проверяет каждый NOT NULL.
    FOR item IN
        SELECT c.conname, c.contype, r.relname, a.attname
        FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
        LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = c.conkey[1]
        WHERE c.connamespace = 'public'::regnamespace AND c.contype IN ('p','n')
    LOOP
        IF item.contype = 'p' THEN
            PERFORM pg_temp.test('PK.' || item.conname, CASE item.relname
                WHEN 'clients' THEN $q$INSERT INTO clients(id_client,name) VALUES (-101,'Тест PK')$q$
                WHEN 'frames' THEN $q$INSERT INTO frames(id_frame,name,price,quantity) VALUES (-101,'Тест PK',1,0)$q$
                WHEN 'glasses' THEN 'INSERT INTO glasses(id_glasses,price,quantity) VALUES (-101,1,0)'
                WHEN 'sales' THEN 'INSERT INTO sales(id_sale,id_order) VALUES (-101,-101)'
                ELSE format('INSERT INTO public.%1$I SELECT * FROM public.%1$I LIMIT 1', item.relname)
                END, '23505', item.conname);
        ELSIF item.relname = 'sales' AND item.attname IN ('sum_sale','previous_order_status') THEN
            PERFORM pg_temp.test('NN.' || item.relname || '.' || item.attname,
                format('UPDATE sales SET %1$I = NULL;
                        SELECT pg_temp.assert_true(bool_and(%1$I IS NOT NULL), %2$L) FROM sales',
                       item.attname, 'триггер должен сохранять исходное значение'));
        ELSE
            PERFORM pg_temp.test('NN.' || item.relname || '.' || item.attname,
                format('UPDATE public.%I SET %I = NULL%s', item.relname, item.attname,
                       CASE WHEN item.relname = 'orders' THEN ' WHERE id_order <> -106' ELSE '' END),
                '23502', NULL, '"' || item.attname || '"');
        END IF;
    END LOOP;

    -- Ложный идентификатор ставится в строку с нужным типом заказа.
    FOR item IN
        SELECT c.conname, r.relname, a.attname
        FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = c.conkey[1]
        WHERE c.connamespace = 'public'::regnamespace AND c.contype = 'f'
    LOOP
        PERFORM pg_temp.test('FK.' || item.conname, CASE item.conname
            WHEN 'orders_recipe_owner_fkey' THEN 'UPDATE orders SET id_presc=-102 WHERE id_order=-102'
            WHEN 'sales_id_order_fkey' THEN 'INSERT INTO sales(id_order) VALUES(-999999)'
            WHEN 'prescriptions_id_client_fkey' THEN 'INSERT INTO prescriptions(id_client) VALUES(-999999)'
            ELSE format('UPDATE public.%1$I SET %2$I = -999999 WHERE ctid = (
                        SELECT ctid FROM public.%1$I WHERE %2$I IS NOT NULL %3$s LIMIT 1)',
                   item.relname, item.attname,
                   CASE WHEN item.relname = 'orders' THEN 'AND id_order <> -106' ELSE '' END)
            END, '23503', item.conname);
    END LOOP;

    FOR item IN SELECT * FROM (VALUES
        ('clients_email_key', $q$INSERT INTO clients(name,email) VALUES ('Тест','client1@example.invalid')$q$),
        ('clients_phone_key', $q$INSERT INTO clients(name,phone) VALUES ('Тест','0000000001')$q$),
        ('frames_name_key', $q$INSERT INTO frames(name,price,quantity) VALUES ('Тест Оправа',1,0)$q$),
        ('glasses_id_frame_id_lens_key', 'INSERT INTO glasses(id_frame,id_lens,price,quantity) VALUES (-101,-101,1,0)'),
        ('sales_id_order_key', $q$ALTER TABLE sales DISABLE TRIGGER trg_auto_replenish_before_sale;
             INSERT INTO sales(id_order,previous_order_status) VALUES (-106,'готов')$q$),
        ('prescriptions_id_presc_id_client_key', $q$ALTER TABLE prescriptions DROP CONSTRAINT prescriptions_pkey CASCADE;
             INSERT INTO prescriptions(id_presc,id_client) VALUES (-101,-101)$q$)
    ) AS v(name, sql) LOOP
        PERFORM pg_temp.test('UQ.' || item.name, item.sql, '23505', item.name);
    END LOOP;

    FOR item IN SELECT * FROM (VALUES
        ('frames_price_check', $q$INSERT INTO frames(name,price,quantity) VALUES ('Тест цена',-1,0)$q$),
        ('frames_quantity_check', $q$INSERT INTO frames(name,price,quantity) VALUES ('Тест остаток',1,-1)$q$),
        ('glasses_price_check', 'INSERT INTO glasses(price,quantity) VALUES (-1,0)'),
        ('glasses_quantity_check', 'INSERT INTO glasses(price,quantity) VALUES (1,-1)'),
        ('lenses_price_check', 'INSERT INTO lenses(price,quantity) VALUES (-1,0)'),
        ('lenses_quantity_check', 'INSERT INTO lenses(price,quantity) VALUES (1,-1)'),
        ('orders_check', $q$INSERT INTO orders(order_type,id_frame,status) VALUES ('custom',-101,'создан')$q$),
        ('orders_order_type_check', $q$ALTER TABLE orders DROP CONSTRAINT orders_check;
                                     INSERT INTO orders(order_type,status) VALUES ('unknown','создан')$q$),
        ('orders_status_check', $q$UPDATE orders SET status = 'unknown' WHERE id_order = -101$q$),
        ('orders_recipe_client_required', 'UPDATE orders SET id_client=NULL WHERE id_order=-102'),
        ('repair_check', 'UPDATE repair SET date_out = date_in - 1'),
        ('repair_price_check', 'UPDATE repair SET price = -1'),
        ('repair_valid_positive_price', 'UPDATE repair SET price = 0'),
        ('repair_status_dates_check', $q$UPDATE repair SET status='завершен'$q$),
        ('repair_status_domain', $q$UPDATE repair SET status='unknown'$q$),
        ('sales_sum_sale_check', 'ALTER TABLE sales DISABLE TRIGGER trg_sale_sum_calc; UPDATE sales SET sum_sale = -1'),
        ('sales_previous_order_status_check', $q$ALTER TABLE sales DISABLE TRIGGER trg_sale_sum_calc;
             UPDATE sales SET previous_order_status='unknown'$q$),
        ('supply_sum_supply_check', 'UPDATE supply SET sum_supply = -1'),
        ('supply_frames_price_check', 'UPDATE supply_frames SET price = -1'),
        ('supply_frames_quantity_check', 'UPDATE supply_frames SET quantity = 0'),
        ('supply_glasses_price_check', 'UPDATE supply_glasses SET price = -1'),
        ('supply_glasses_quantity_check', 'UPDATE supply_glasses SET quantity = 0'),
        ('supply_lenses_price_check', 'UPDATE supply_lenses SET price = -1'),
        ('supply_lenses_quantity_check', 'UPDATE supply_lenses SET quantity = 0')
    ) AS v(name, sql) LOOP
        PERFORM pg_temp.test('CK.' || item.name, item.sql, '23514', item.name);
    END LOOP;
END;
$constraints$;

DO $scenarios$
DECLARE item record;
BEGIN
    FOR item IN SELECT * FROM (VALUES
        ('DDL.defaults', $q$DO $b$ DECLARE item record; BEGIN
           FOR item IN SELECT * FROM (VALUES
                ('clients','id_client'),('consultants','id_consultant'),('frames','id_frame'),
                ('glasses','id_glasses'),('lenses','id_lens'),('optometrists','id_optometrist'),
                ('orders','id_order'),('prescriptions','id_presc'),('repair','id_repair'),
                ('sales','id_sale'),('suppliers','id_sup'),('supply','id_supply')
           ) AS v(tbl,col) LOOP
               PERFORM pg_temp.assert_true(
                   (SELECT column_default LIKE 'nextval(%' FROM information_schema.columns
                     WHERE table_schema='public' AND table_name=item.tbl AND column_name=item.col)
                   AND pg_get_serial_sequence('public.' || item.tbl,item.col) IS NOT NULL,
                   'нет DEFAULT/OWNED BY для ' || item.tbl || '.' || item.col);
           END LOOP;
           PERFORM pg_temp.assert_true((SELECT hire_date = CURRENT_DATE FROM consultants)
               AND (SELECT hire_date = CURRENT_DATE FROM optometrists WHERE id_optometrist = -101)
               AND (SELECT date_order = CURRENT_DATE FROM orders WHERE id_order = -101),
               'не применились значения дат по умолчанию');
        END $b$$q$),
        ('DDL.supply_cascade', $q$DELETE FROM supply WHERE id_supply = -101;
             SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM supply_frames)
                 AND NOT EXISTS(SELECT FROM supply_lenses) AND NOT EXISTS(SELECT FROM supply_glasses),
                 'позиции поставки не удалились каскадно')$q$),
        ('FN.frame_stock', $q$SELECT pg_temp.assert_true(get_frame_stock(-101)=8
             AND get_frame_stock(-999999)=0, 'остаток существующей/отсутствующей оправы')$q$),
        ('FN.glasses_stock', $q$SELECT pg_temp.assert_true(get_glasses_stock(-101)=7
             AND get_glasses_stock(-999999)=0, 'остаток существующих/отсутствующих очков')$q$),
        ('FN.lens_stock', $q$SELECT pg_temp.assert_true(get_lens_stock(-101)=8
             AND get_lens_stock(-999999)=0, 'остаток существующей/отсутствующей линзы')$q$),
        ('FN.order_total', $q$SELECT pg_temp.assert_true(get_order_total(-101)=250
             AND get_order_total(-102)=140 AND get_order_total(-999999)=0,
             'суммы ready/custom/несуществующего заказа')$q$),
        ('FN.month_boundaries', $q$INSERT INTO sales(id_order,date_sale) VALUES
             (-107,DATE '2024-01-31'),(-108,DATE '2024-02-29'),(-110,DATE '2024-03-01');
             SELECT pg_temp.assert_true(get_sales_by_month(2,2024)=500
                 AND get_sales_by_month(12,2024)=0 AND get_sales_by_month(3,2024)=250,
                 'границы февраля високосного года и пустой месяц')$q$),
        ('FN.stock_existing', $q$SELECT pg_temp.assert_true(ensure_stock_for_order('ready',NULL,NULL,-101,2)
             AND ensure_stock_for_order('custom',-101,-101,NULL,2), 'функция отвергла имеющийся запас');
             SELECT pg_temp.assert_true((SELECT count(*)=1 FROM supply) AND get_glasses_stock(-101)=7
                 AND get_frame_stock(-101)=8 AND get_lens_stock(-101)=8, 'запас/поставки изменились')$q$),
        ('FN.stock_custom_restock', $q$SELECT pg_temp.assert_true(ensure_stock_for_order('custom',-102,-102,NULL,3),
                 'функция не подтвердила пополнение');
             SELECT pg_temp.assert_true(get_frame_stock(-102)=3 AND get_lens_stock(-102)=3
                 AND (SELECT array_agg(sum_supply ORDER BY sum_supply) = ARRAY[165,330]::numeric[]
                        FROM supply WHERE id_supply > 0)
                 AND EXISTS(SELECT FROM supply_frames WHERE id_frame=-102 AND quantity=3 AND price=110)
                 AND EXISTS(SELECT FROM supply_lenses WHERE id_lens=-102 AND quantity=3 AND price=55),
                 'оправа, линза или суммы автопоставок неверны')$q$),
        ('PROC.create_order', $q$CALL create_order(-101,'ready',NULL,NULL,-101,NULL);
             CALL create_order(-101,'custom',-101,-101,NULL,-101,-101,-101);
             SELECT pg_temp.assert_true((SELECT count(*)=2 FROM orders WHERE id_order>0)
                 AND EXISTS(SELECT FROM orders WHERE id_order>0 AND order_type='ready' AND id_glasses=-101
                     AND status='создан' AND date_order=CURRENT_DATE AND id_consultant IS NULL)
                 AND EXISTS(SELECT FROM orders WHERE id_order>0 AND order_type='custom' AND id_frame=-101
                     AND id_lens=-101 AND id_presc=-101 AND id_optometrist=-101 AND id_consultant=-101
                     AND id_client=-101 AND status='создан'), 'неверные поля созданного заказа')$q$),
        ('PROC.in_work_finish', $q$CALL in_work_order(-102);
             SELECT pg_temp.assert_true((SELECT status='в работе' FROM orders WHERE id_order=-102), 'не переведён в работу');
             CALL finish_order(-102);
             SELECT pg_temp.assert_true((SELECT status='готов' FROM orders WHERE id_order=-102), 'не переведён в готов');
             CALL in_work_order(-101);
             SELECT pg_temp.assert_true((SELECT status='создан' FROM orders WHERE id_order=-101), 'статус ready изменился')$q$),
        ('PROC.create_sale', $q$CALL create_sale(-101);
             SELECT pg_temp.assert_true(EXISTS(SELECT FROM sales WHERE id_order=-101
                   AND sum_sale=250 AND date_sale=CURRENT_DATE), 'продажа не создана')$q$),
        ('TRG.sale_total', $q$UPDATE orders SET status='готов' WHERE id_order=-102;
             INSERT INTO sales(id_order,sum_sale) VALUES (-102,999);
             SELECT pg_temp.assert_true((SELECT sum_sale=140 FROM sales WHERE id_order=-102), 'входная сумма не пересчитана')$q$),
        ('TRG.sale_status', $q$INSERT INTO sales(id_order) VALUES (-101);
             SELECT pg_temp.assert_true((SELECT status='выдан' FROM orders WHERE id_order=-101), 'статус не выдан')$q$),
        ('TRG.sale_stock', $q$UPDATE orders SET status='готов' WHERE id_order=-102;
             INSERT INTO sales(id_order) VALUES (-101),(-102);
             SELECT pg_temp.assert_true(get_glasses_stock(-101)=6 AND get_frame_stock(-101)=7
                 AND get_lens_stock(-101)=7 AND (SELECT count(*)=1 FROM supply), 'списание ready/custom неверно')$q$),
        ('TRG.replenish_ready', $q$INSERT INTO sales(id_order) VALUES (-103);
             SELECT pg_temp.assert_true(get_glasses_stock(-102)=0 AND EXISTS(SELECT FROM supply s
                 JOIN supply_glasses g USING(id_supply) WHERE s.id_supply>0 AND s.id_sup=-101
                 AND s.date_supply=CURRENT_DATE AND g.id_glasses=-102 AND g.quantity=1
                 AND g.price=290 AND s.sum_supply=290)
                 AND (SELECT sum_sale=290 FROM sales WHERE id_order=-103), 'нет корректной автопоставки очков')$q$),
        ('TRG.replenish_custom', $q$UPDATE orders SET status='готов' WHERE id_order=-104;
             INSERT INTO sales(id_order) VALUES (-104);
             SELECT pg_temp.assert_true(get_frame_stock(-102)=0 AND get_lens_stock(-102)=0
                 AND (SELECT count(*)=2 AND sum(sum_supply)=165 FROM supply WHERE id_supply>0)
                 AND (SELECT sum_sale=165 FROM sales WHERE id_order=-104), 'нет корректной автопоставки комплектующих')$q$),
        ('TRG.nonnegative_ok', $q$UPDATE frames SET quantity=0 WHERE id_frame=-101;
             UPDATE glasses SET quantity=0 WHERE id_glasses=-101;
             UPDATE lenses SET quantity=0 WHERE id_lens=-101;
             SELECT pg_temp.assert_true(get_frame_stock(-101)=0 AND get_glasses_stock(-101)=0
                 AND get_lens_stock(-101)=0, 'нулевой остаток не принят')$q$),
        ('PROC.repair_cycle', $q$CALL create_repair(-101,'Тест новый ремонт',42.25);
             DO $b$ DECLARE idx integer; BEGIN
                 SELECT id_repair INTO STRICT idx FROM repair WHERE id_repair>0 AND id_client=-101
                     AND description='Тест новый ремонт' AND price=42.25 AND status='принят'
                     AND date_in=CURRENT_DATE AND date_out IS NULL;
                 CALL complete_repair(idx);
                 PERFORM pg_temp.assert_true((SELECT status='завершен' AND date_out=CURRENT_DATE
                     FROM repair WHERE id_repair=idx), 'ремонт не завершён');
             END $b$$q$),
        ('PROC.supply_items', $q$CALL receive_supply(-101,DATE '2024-04-01',
             '[{"type":"frame","id":-101,"quantity":2,"price":12.34},
               {"type":"lens","id":-101,"quantity":3,"price":5.25}]');
             SELECT pg_temp.assert_true((SELECT sum_supply=40.43 AND id_sup=-101 AND date_supply=DATE '2024-04-01'
                   FROM supply WHERE id_supply>0)
                 AND get_frame_stock(-101)=10 AND get_lens_stock(-101)=11
                 AND EXISTS(SELECT FROM supply_frames WHERE id_supply>0 AND id_frame=-101 AND quantity=2 AND price=12.34)
                 AND EXISTS(SELECT FROM supply_lenses WHERE id_supply>0 AND id_lens=-101 AND quantity=3 AND price=5.25),
                 'позиции, остатки или сумма поставки неверны')$q$),
        ('PROC.supply_atomic', $q$DO $b$ BEGIN
            BEGIN
                CALL receive_supply(-101,CURRENT_DATE,
                    '[{"type":"frame","id":-101,"quantity":2,"price":1},
                      {"type":"lens","id":-999999,"quantity":1,"price":1}]');
                RAISE EXCEPTION 'поставка с некорректной второй позицией принята';
            EXCEPTION WHEN foreign_key_violation THEN NULL;
            END;
            PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM supply)
                AND (SELECT count(*)=1 FROM supply_frames) AND (SELECT count(*)=1 FROM supply_lenses)
                AND get_frame_stock(-101)=8 AND get_lens_stock(-101)=8,
                'сохранились часть поставки или изменение остатков');
        END $b$$q$)
    ) AS v(code,sql) LOOP
        PERFORM pg_temp.test(item.code, item.sql);
    END LOOP;

    FOR item IN SELECT * FROM (VALUES
        ('ERR.month_invalid', 'SELECT get_sales_by_month(13,2024)', '22008', NULL, NULL),
        ('ERR.stock_frame_missing', $q$SELECT ensure_stock_for_order('custom',-999999,-101,NULL)$q$, 'P0001', NULL, 'не найдена'),
        ('ERR.order_shape', $q$CALL create_order(-101,'custom',-101,NULL,NULL,NULL)$q$, '23514', 'orders_check', NULL),
        ('ERR.order_client', $q$CALL create_order(-999999,'ready',NULL,NULL,-101,NULL)$q$, '23503', 'orders_id_client_fkey', NULL),
        ('ERR.in_work_missing', 'CALL in_work_order(-999999)', 'P0001', NULL, 'не найден'),
        ('ERR.in_work_status', 'CALL in_work_order(-109)', 'P0001', NULL, 'только из статуса'),
        ('ERR.sale_duplicate_call', 'CALL create_sale(-106)', 'P0001', NULL, 'уже оформлена'),
        ('ERR.sale_missing', 'CALL create_sale(-999999)', '23503', 'sales_id_order_fkey', NULL),
        ('ERR.sale_without_supplier', 'DELETE FROM supply; DELETE FROM suppliers; CALL create_sale(-103)',
             'P0001', NULL, 'Нет поставщиков'),
        ('TRG.negative_frame', 'UPDATE frames SET quantity=-1 WHERE id_frame=-101', 'P0001', NULL, 'Отрицательный остаток оправы'),
        ('TRG.negative_glasses', 'UPDATE glasses SET quantity=-1 WHERE id_glasses=-101', 'P0001', NULL, 'Отрицательный остаток готовых очков'),
        ('TRG.negative_lens', 'UPDATE lenses SET quantity=-1 WHERE id_lens=-101', 'P0001', NULL, 'Отрицательный остаток линз'),
        ('ERR.repair_no_client', $q$CALL create_repair(-999999,'Тест',25)$q$, 'P0001', NULL, 'не найден'),
        ('ERR.repair_zero_price', $q$CALL create_repair(-101,'Тест',0)$q$, 'P0001', NULL, 'больше 0'),
        ('ERR.repair_missing', 'CALL complete_repair(-999999)', 'P0001', NULL, 'не найден'),
        ('ERR.repair_repeat', 'CALL complete_repair(-101); CALL complete_repair(-101)', 'P0001', NULL, 'уже завершен'),
        ('ERR.supply_nonarray', $q$CALL receive_supply(-101,CURRENT_DATE,'{}')$q$, '22023', NULL, NULL),
        ('ERR.supply_invalid_supplier', $q$CALL receive_supply(-999999,CURRENT_DATE,'[]')$q$, '23503', 'supply_id_sup_fkey', NULL),
        ('ERR.supply_bad_quantity', $q$CALL receive_supply(-101,CURRENT_DATE,
            '[{"type":"frame","id":-101,"quantity":0,"price":1}]')$q$, '23514', 'supply_frames_quantity_check', NULL),
        ('ERR.supply_dup_item', $q$CALL receive_supply(-101,CURRENT_DATE,
            '[{"type":"lens","id":-101,"quantity":1,"price":1},
              {"type":"lens","id":-101,"quantity":1,"price":1}]')$q$, '23505', 'supply_lenses_pkey', NULL)
    ) AS v(code,sql,state,constraint_name,message) LOOP
        PERFORM pg_temp.test(item.code, item.sql, item.state, item.constraint_name, item.message);
    END LOOP;
END;
$scenarios$;

-- Проверки, которые выявили расхождения в исходной схеме.
DO $integrity$
DECLARE item record;
BEGIN
    FOR item IN SELECT * FROM (VALUES
        ('I.sale_unique', $q$INSERT INTO sales(id_order) VALUES (-106);
            SELECT pg_temp.assert_true((SELECT count(*)=1 FROM sales WHERE id_order=-106),
                format('продаж заказа: %s, остаток: %s',
                       (SELECT count(*) FROM sales WHERE id_order=-106), get_glasses_stock(-101)))$q$,
            '23505', NULL),
        ('I.sale_order_required', $q$INSERT INTO sales(id_order) VALUES (NULL);
            SELECT pg_temp.assert_true(false, format('продажа без заказа, сумма %s',
                (SELECT sum_sale FROM sales WHERE id_order IS NULL)))$q$, '23502', NULL),
        ('I.sale_stock_known', $q$UPDATE glasses SET quantity=NULL WHERE id_glasses=-103;
            CALL create_sale(-105);
            SELECT pg_temp.assert_true(false, format('сумма продажи %s, статус заказа %s, фактический остаток NULL',
                (SELECT sum_sale FROM sales WHERE id_order=-105), (SELECT status FROM orders WHERE id_order=-105)))$q$,
            '23502', NULL),
        ('I.order_type_required', $q$CALL create_order(-101,NULL,NULL,NULL,-101,NULL);
             SELECT pg_temp.assert_true(false,'создан заказ с типом NULL')$q$, '23502', NULL),
        ('I.order_status_required', $q$UPDATE orders SET status=NULL WHERE id_order=-101;
             SELECT pg_temp.assert_true(false,'заказ допускает статус NULL')$q$, '23502', NULL),
        ('I.stock_quantity_required', $q$UPDATE lenses SET quantity=NULL WHERE id_lens=-101;
             SELECT pg_temp.assert_true(false,'UPDATE установил остаток NULL')$q$, '23502', NULL),
        ('I.order_total_price_missing', $q$UPDATE frames SET price=NULL WHERE id_frame=-101;
             SELECT pg_temp.assert_true(false,format('get_order_total для заказа с неизвестной ценой: %s',
                 get_order_total(-102)))$q$, '23502', NULL),
        ('I.stock_ready_missing', $q$SELECT ensure_stock_for_order('ready',NULL,NULL,-999999)$q$, 'P0001', NULL),
        ('I.stock_lens_missing', $q$SELECT ensure_stock_for_order('custom',-101,-999999,NULL)$q$, 'P0001', NULL),
        ('I.stock_unknown_type', $q$SELECT ensure_stock_for_order('unknown',NULL,NULL,NULL)$q$, 'P0001', NULL),
        ('I.stock_bad_quantity', $q$SELECT ensure_stock_for_order('ready',NULL,NULL,-101,-1)$q$, 'P0001', NULL),
        ('I.finish_unknown_order', $q$CALL finish_order(-999999);
             SELECT pg_temp.assert_true(false,'процедура завершилась без ошибки для отсутствующего заказа')$q$,
             'P0001', NULL),
        ('I.finish_sold_order', $q$CALL finish_order(-106);
             SELECT pg_temp.assert_true((SELECT status='выдан' FROM orders WHERE id_order=-106),
                  'выданный заказ вернулся в статус «готов»')$q$, 'P0001', NULL),
        ('I.custom_sale_before_ready', $q$CALL create_sale(-102);
             SELECT pg_temp.assert_true(false, 'индивидуальный заказ выдан непосредственно из статуса «создан»')$q$,
             'P0001', NULL),
        ('I.order_prescription_owner', $q$CALL create_order(-101,'custom',-101,-101,NULL,-102,-101,-101);
             SELECT pg_temp.assert_true(false, 'заказ клиента -101 с рецептом клиента -102 сохранён')$q$,
             '23503', NULL),
        ('I.repair_price_required', $q$CALL create_repair(-101,'Тест без цены',NULL);
             SELECT pg_temp.assert_true(false,'создан ремонт с ценой NULL')$q$, '23502', NULL),
        ('I.repair_status_domain', $q$CALL create_repair(-101,'Тест статуса',25,'unknown');
             SELECT pg_temp.assert_true(false,'сохранён произвольный статус ремонта')$q$, '23514', NULL),
        ('I.supply_glasses', $q$CALL receive_supply(-101,CURRENT_DATE,
               '[{"type":"glasses","id":-101,"quantity":2,"price":20}]');
             SELECT pg_temp.assert_true(get_glasses_stock(-101)=9
                 AND EXISTS(SELECT FROM supply_glasses WHERE id_supply>0 AND id_glasses=-101 AND quantity=2)
                 AND (SELECT sum_supply=40 FROM supply WHERE id_supply>0),'очки пропущены, сумма поставки 0')$q$,
             NULL, NULL),
        ('I.supply_unknown_type', $q$CALL receive_supply(-101,CURRENT_DATE,
              '[{"type":"frame","id":-101,"quantity":2,"price":3},
                {"type":"unknown","id":-101,"quantity":1,"price":1}]');
             SELECT pg_temp.assert_true(false,format('неизвестная позиция пропущена; остаток оправы %s; сумма %s',
                get_frame_stock(-101),(SELECT sum_supply FROM supply WHERE id_supply>0)))$q$, 'P0001', NULL),
        ('I.supply_empty', $q$CALL receive_supply(-101,CURRENT_DATE,'[]');
             SELECT pg_temp.assert_true(false,format('создана пустая поставка с суммой %s',
                 (SELECT sum_supply FROM supply WHERE id_supply>0)))$q$, 'P0001', NULL),
        ('I.supply_null_quantity', $q$CALL receive_supply(-101,CURRENT_DATE,
             '[{"type":"frame","id":-101,"price":2}]');
             SELECT pg_temp.assert_true(false,format('после поставки остаток оправы %s, сумма %s',
                 (SELECT coalesce(quantity::text,'NULL') FROM frames WHERE id_frame=-101),
                 (SELECT sum_supply FROM supply WHERE id_supply>0)))$q$, '23502', NULL),
        ('I.sale_delete', $q$DELETE FROM sales WHERE id_order=-106;
             SELECT pg_temp.assert_true(get_glasses_stock(-101)=8
                 AND (SELECT status='готов' FROM orders WHERE id_order=-106),
                 format('после удаления остаток %s, статус %s',get_glasses_stock(-101),
                     (SELECT status FROM orders WHERE id_order=-106)))$q$, NULL, NULL),
        ('I.sale_sum_update', $q$UPDATE sales SET sum_sale=1 WHERE id_order=-106;
             SELECT pg_temp.assert_true((SELECT sum_sale=250 FROM sales WHERE id_order=-106),
                 'прямой UPDATE изменил рассчитанную сумму с 250 на 1')$q$, NULL, NULL),
        ('I.search_path', $q$SET LOCAL search_path TO ''; CALL public.create_sale(-101)$q$,
             NULL, NULL)
    ) AS v(code,sql,state,constraint_name) LOOP
        PERFORM pg_temp.test(item.code, item.sql, item.state, item.constraint_name);
    END LOOP;
END;
$integrity$;

DO $regressions$
BEGIN
    PERFORM pg_temp.test('R.cancel_custom', $q$
        CALL in_work_order(-102);
        CALL finish_order(-102);
        CALL create_sale(-102);
        SELECT pg_temp.assert_true(get_frame_stock(-101)=7 AND get_lens_stock(-101)=7,
            'списание комплекта не выполнено');
        DELETE FROM sales WHERE id_order=-102;
        SELECT pg_temp.assert_true(get_frame_stock(-101)=8 AND get_lens_stock(-101)=8
            AND (SELECT status='готов' FROM orders WHERE id_order=-102),
            'отмена не вернула комплект и исходный статус');
        CALL create_sale(-102);
        SELECT pg_temp.assert_true((SELECT count(*)=1 FROM sales WHERE id_order=-102)
            AND (SELECT status='выдан' FROM orders WHERE id_order=-102),
            'после отмены заказ нельзя продать заново')
    $q$);
    PERFORM pg_temp.test('R.cancel_ready_created', $q$
        CALL create_sale(-101);
        DELETE FROM sales WHERE id_order=-101;
        SELECT pg_temp.assert_true(get_glasses_stock(-101)=7
            AND (SELECT status='создан' FROM orders WHERE id_order=-101),
            'отмена не вернула товар и статус создан')
    $q$);
    PERFORM pg_temp.test('R.sold_order_items_immutable',
        'UPDATE orders SET id_glasses=-102 WHERE id_order=-106', 'P0001', NULL, 'Сначала отмените');
    PERFORM pg_temp.test('R.direct_issue_rejected',
        $q$UPDATE orders SET status='выдан' WHERE id_order=-101$q$, 'P0001', NULL, 'оформите продажу');
    PERFORM pg_temp.test('R.catalog_nan_price',
        $q$UPDATE frames SET price='NaN' WHERE id_frame=-101$q$, '23514', 'frames_price_check');
    PERFORM pg_temp.test('R.supply_nan_price', $q$CALL receive_supply(-101,CURRENT_DATE,
        '[{"type":"glasses","id":-101,"quantity":1,"price":"NaN"}]')$q$,
        '23514', 'supply_glasses_price_check');
    PERFORM pg_temp.test('R.new_issued_order_rejected',
        $q$INSERT INTO orders(order_type,id_glasses,status) VALUES ('ready',-101,'выдан')$q$,
        'P0001', NULL, 'оформите продажу');
    PERFORM pg_temp.test('R.sale_snapshot', $q$
        UPDATE glasses SET price=300 WHERE id_glasses=-101;
        UPDATE sales SET sum_sale=300,previous_order_status='создан',date_sale=DATE '2024-02-02' WHERE id_sale=-101;
        SELECT pg_temp.assert_true((SELECT sum_sale=250 AND previous_order_status='готов'
            AND date_sale=DATE '2024-02-02' FROM sales WHERE id_sale=-101), 'историческая сумма или статус изменились')
    $q$);
    PERFORM pg_temp.test('R.supply_unknown_atomic', $q$DO $b$ BEGIN
        BEGIN
            CALL receive_supply(-101,CURRENT_DATE,
                '[{"type":"frame","id":-101,"quantity":2,"price":3},
                  {"type":"unknown","id":-101,"quantity":1,"price":1}]');
        EXCEPTION WHEN raise_exception THEN
            PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM supply)
                AND (SELECT count(*)=1 FROM supply_frames) AND get_frame_stock(-101)=8,
                'неизвестный тип оставил часть поставки');
            RETURN;
        END;
        RAISE EXCEPTION 'неизвестный тип принят';
    END $b$$q$);
    PERFORM pg_temp.test('R.search_path_other_calls', $q$
        SET LOCAL search_path TO '';
        CALL public.create_order(-101,'ready',NULL,NULL,-101,NULL);
        CALL public.create_repair(-101,'Проверка схемы',25);
        CALL public.receive_supply(-101,CURRENT_DATE,'[{"type":"glasses","id":-101,"quantity":1,"price":5}]');
        SELECT pg_temp.assert_true(public.get_glasses_stock(-101)=8,'квалифицированный вызов не обновил остаток')
    $q$);
END;
$regressions$;

SELECT code, result, detail FROM audit_results ORDER BY code COLLATE "C";
SELECT result, count(*) AS tests FROM audit_results GROUP BY result ORDER BY result;
SELECT EXISTS(SELECT FROM audit_results WHERE result = 'FAIL') AS audit_failed \gset
ROLLBACK;
\if :audit_failed
    DO $$ BEGIN RAISE EXCEPTION 'Есть непройденные проверки. См. строки FAIL.'; END $$;
\endif
