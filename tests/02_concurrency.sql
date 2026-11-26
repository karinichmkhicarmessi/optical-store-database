\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset fieldsep ' | '
\encoding UTF8

-- Запускать в отдельной одноразовой тестовой базе. dblink соединяется с ней
-- по loopback. Для локальной аутентификации без trust передайте -v audit_conn=...
-- с параметрами подключения (пароль можно хранить в файле pgpass сервера).
\if :{?audit_conn}
\else
SELECT format('host=127.0.0.1 port=%s dbname=%L user=%L connect_timeout=5',
              inet_server_port(), current_database(), current_user) AS audit_conn \gset
\endif

CREATE EXTENSION dblink;
BEGIN;
INSERT INTO clients(id_client,name) VALUES (-801,'Тест параллельных продаж');
INSERT INTO suppliers(id_sup,name) VALUES (-801,'Тест поставщик');
INSERT INTO glasses(id_glasses,price,quantity) VALUES (-801,25,5),(-802,40,1);
INSERT INTO orders(id_order,id_client,order_type,id_glasses,status) VALUES
    (-801,-801,'ready',-801,'готов'),(-802,-801,'ready',-802,'готов'),
    (-803,-801,'ready',-802,'готов');
COMMIT;

SELECT dblink_connect('audit_a', :'audit_conn');
SELECT dblink_connect('audit_b', :'audit_conn');
CREATE TEMP TABLE audit_parallel(code text, result text, detail text);

CREATE FUNCTION pg_temp.parallel_sales(first_order integer, second_order integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    a_pid integer;
    b_pid integer;
    deadline timestamptz;
    result text;
BEGIN
    SELECT pid INTO STRICT a_pid FROM dblink('audit_a', 'SELECT pg_backend_pid()') AS t(pid int);
    SELECT pid INTO STRICT b_pid FROM dblink('audit_b', 'SELECT pg_backend_pid()') AS t(pid int);
    PERFORM dblink_exec('audit_a','SET search_path TO public, pg_catalog');
    PERFORM dblink_exec('audit_b','SET search_path TO public, pg_catalog');
    PERFORM dblink_exec('audit_b','SET statement_timeout = ''15s''');
    PERFORM dblink_exec('audit_a','BEGIN');
    PERFORM dblink_exec('audit_a',format('CALL create_sale(%s)',first_order));
    IF dblink_send_query('audit_b',format('CALL create_sale(%s)',second_order)) <> 1 THEN
        RAISE EXCEPTION 'Не удалось запустить второй CALL';
    END IF;
    deadline := clock_timestamp() + interval '8 seconds';
    LOOP
        EXIT WHEN a_pid = ANY(pg_blocking_pids(b_pid));
        IF clock_timestamp() >= deadline THEN
            PERFORM dblink_exec('audit_a','ROLLBACK');
            RAISE EXCEPTION 'Вторая сессия не дошла до ожидаемой блокировки';
        END IF;
        PERFORM pg_sleep(0.02);
    END LOOP;
    PERFORM dblink_exec('audit_a','COMMIT');
    BEGIN
        SELECT status INTO STRICT result FROM dblink_get_result('audit_b') AS t(status text);
    EXCEPTION WHEN OTHERS THEN
        result := SQLSTATE || ' ' || SQLERRM;
    END;
    PERFORM * FROM dblink_get_result('audit_b') AS t(status text);
    RETURN result;
END;
$$;

SELECT pg_temp.parallel_sales(-801,-801) AS second_call \gset
INSERT INTO audit_parallel
SELECT 'CON.same_order', CASE WHEN count(*)=1 AND get_glasses_stock(-801)=4
       AND starts_with(:'second_call', '23505 ') THEN 'PASS' ELSE 'FAIL' END,
       format('CALL B: %s; продаж: %s; остаток: %s', :'second_call', count(*), get_glasses_stock(-801))
FROM sales WHERE id_order=-801;

SELECT pg_temp.parallel_sales(-802,-803) AS second_call \gset
INSERT INTO audit_parallel
SELECT 'CON.last_item', CASE WHEN :'second_call'='CALL' AND count(*)=2 AND get_glasses_stock(-802)=0 AND
       (SELECT count(*)=1 FROM supply_glasses WHERE id_glasses=-802 AND quantity=1)
       THEN 'PASS' ELSE 'FAIL' END,
       format('CALL B: %s; продаж: %s; остаток: %s; строк автопоставки: %s',
              :'second_call', count(*), get_glasses_stock(-802),
              (SELECT count(*) FROM supply_glasses WHERE id_glasses=-802))
FROM sales WHERE id_order IN (-802,-803);

SELECT dblink_disconnect('audit_a');
SELECT dblink_disconnect('audit_b');
SELECT * FROM audit_parallel ORDER BY code;
SELECT EXISTS(SELECT FROM audit_parallel WHERE result = 'FAIL') AS audit_failed \gset

BEGIN;
DELETE FROM sales WHERE id_order IN (-801,-802,-803);
DELETE FROM orders WHERE id_order IN (-801,-802,-803);
DELETE FROM supply WHERE id_sup=-801;
DELETE FROM suppliers WHERE id_sup=-801;
DELETE FROM glasses WHERE id_glasses IN (-801,-802);
DELETE FROM clients WHERE id_client=-801;
DROP EXTENSION dblink;
COMMIT;
\if :audit_failed
    DO $$ BEGIN RAISE EXCEPTION 'Есть непройденные параллельные проверки. См. строки FAIL.'; END $$;
\endif
