--
-- PostgreSQL database dump
--

\restrict 2dxnD1B7H0jrAuQoewu6N699OZIc6utb2tgBLXt6DsBrOBmjGmrG7enQahDGXfL

-- Dumped from database version 18.2
-- Dumped by pg_dump version 18.2

-- Started on 2026-11-27 01:02:07

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 276 (class 1255 OID 33642)
-- Name: auto_replenish_before_sale(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auto_replenish_before_sale() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    ordered public.orders%ROWTYPE;
BEGIN
    SELECT * INTO ordered FROM public.orders WHERE id_order = NEW.id_order FOR UPDATE;
    -- Для пустого и неизвестного ID возвращаем штатные ошибки NOT NULL и FK.
    IF NOT FOUND THEN
        NEW.previous_order_status := 'создан';
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT FROM public.sales WHERE id_order = NEW.id_order) THEN
        RAISE unique_violation USING MESSAGE = format('Продажа для заказа %s уже оформлена', NEW.id_order),
            CONSTRAINT = 'sales_id_order_key', SCHEMA = 'public', TABLE = 'sales';
    END IF;
    IF ordered.status <> 'готов' AND NOT (ordered.order_type = 'ready' AND ordered.status = 'создан') THEN
        RAISE EXCEPTION 'Заказ % нельзя выдать из статуса «%»', NEW.id_order, ordered.status;
    END IF;
    PERFORM public.ensure_stock_for_order(ordered.order_type, ordered.id_frame, ordered.id_lens, ordered.id_glasses);
    NEW.previous_order_status := ordered.status;
    RETURN NEW;
END;
$$;


--
-- TOC entry 268 (class 1255 OID 33611)
-- Name: calculate_sale_sum(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_sale_sum() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.id_order IS NOT NULL AND NEW.id_order <> OLD.id_order)
           OR (NEW.id_sale IS NOT NULL AND NEW.id_sale <> OLD.id_sale) THEN
            RAISE EXCEPTION 'Идентификаторы существующей продажи нельзя изменить';
        END IF;
        NEW.sum_sale := OLD.sum_sale;
        NEW.previous_order_status := OLD.previous_order_status;
    ELSE
        NEW.sum_sale := public.get_order_total(NEW.id_order);
    END IF;
    RETURN NEW;
END;
$$;


--
-- TOC entry 270 (class 1255 OID 33594)
-- Name: complete_repair(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.complete_repair(IN p_repair_id integer)
    LANGUAGE plpgsql
    AS $$
declare
    v_current_status varchar(20);
begin
    select status into v_current_status
    from public.repair
    where id_repair = p_repair_id for update;

    if not found then
        raise exception 'Ремонт % не найден', p_repair_id;
    end if;

    if v_current_status = 'завершен' then
        raise exception 'Ремонт % уже завершен', p_repair_id;
    end if;

    update public.repair
    set date_out = current_date,
        status = 'завершен'
    where id_repair = p_repair_id;
end;
$$;


--
-- TOC entry 273 (class 1255 OID 33738)
-- Name: create_order(integer, character varying, integer, integer, integer, integer, integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.create_order(IN p_client_id integer, IN p_order_type character varying, IN p_frame_id integer, IN p_lens_id integer, IN p_glasses_id integer, IN p_presc_id integer, IN p_optometrist_id integer DEFAULT NULL::integer, IN p_consultant_id integer DEFAULT NULL::integer)
    LANGUAGE plpgsql
    AS $$
begin
    insert into public.orders(
        id_client,
        order_type,
        id_frame,
        id_lens,
        id_glasses,
        id_presc,
        id_optometrist,
        id_consultant,
        status
    )
    values (
        p_client_id,
        p_order_type,
        p_frame_id,
        p_lens_id,
        p_glasses_id,
        p_presc_id,
        p_optometrist_id,
        p_consultant_id,
        'создан'
    );
end;
$$;


--
-- TOC entry 271 (class 1255 OID 33650)
-- Name: create_repair(integer, character varying, numeric, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.create_repair(IN p_client_id integer, IN p_description character varying, IN p_price numeric, IN p_status character varying DEFAULT 'принят'::character varying)
    LANGUAGE plpgsql
    AS $$
declare
    v_client_exists boolean;
    v_repair_id integer;
begin
    select exists(select 1 from public.clients where id_client = p_client_id) into v_client_exists;

    if not v_client_exists then
        raise exception 'Клиент с id % не найден', p_client_id;
    end if;

    if p_price <= 0 then
        raise exception 'Цена ремонта должна быть больше 0. Указано: %', p_price;
    end if;

    insert into public.repair (id_client, description, price, status, date_in)
    values (p_client_id, p_description, p_price, p_status, current_date)
    returning id_repair into v_repair_id;

    raise notice 'Создан ремонт #% для клиента %', v_repair_id, p_client_id;
end;
$$;


--
-- TOC entry 266 (class 1255 OID 33590)
-- Name: create_sale(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.create_sale(IN p_order_id integer)
    LANGUAGE plpgsql
    AS $$
declare
    v_exists boolean;
begin
    select exists(select 1 from public.sales where id_order = p_order_id) into v_exists;

    if v_exists then
        raise exception 'Продажа для заказа % уже оформлена', p_order_id;
    end if;

    insert into public.sales(id_order, date_sale)
    values (p_order_id, current_date);
end;
$$;


--
-- TOC entry 269 (class 1255 OID 33645)
-- Name: ensure_stock_for_order(character varying, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_stock_for_order(
    p_order_type varchar, p_frame_id int, p_lens_id int, p_glasses_id int, p_quantity int DEFAULT 1
) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
    frame_stock int;
    frame_price numeric;
    lens_stock int;
    lens_price numeric;
    glasses_stock int;
    glasses_price numeric;
    units_needed int;
    supplier_id int;
    supply_id int;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Количество для заказа должно быть больше нуля';
    END IF;

    CASE p_order_type
        WHEN 'ready' THEN
            IF p_glasses_id IS NULL OR p_frame_id IS NOT NULL OR p_lens_id IS NOT NULL THEN
                RAISE EXCEPTION 'Готовый заказ должен содержать только готовые очки';
            END IF;
            SELECT quantity, price INTO glasses_stock, glasses_price
            FROM public.glasses WHERE id_glasses = p_glasses_id FOR NO KEY UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Готовые очки с id % не найдены', p_glasses_id; END IF;
            IF glasses_stock >= p_quantity THEN RETURN true; END IF;
        WHEN 'custom' THEN
            IF p_frame_id IS NULL OR p_lens_id IS NULL OR p_glasses_id IS NOT NULL THEN
                RAISE EXCEPTION 'Индивидуальный заказ должен содержать оправу и линзу';
            END IF;
            -- Поставки и продажи берут блокировки оправ раньше блокировок линз.
            SELECT quantity, price INTO frame_stock, frame_price
            FROM public.frames WHERE id_frame = p_frame_id FOR NO KEY UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Оправа с id % не найдена', p_frame_id; END IF;
            SELECT quantity, price INTO lens_stock, lens_price
            FROM public.lenses WHERE id_lens = p_lens_id FOR NO KEY UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Линза с id % не найдена', p_lens_id; END IF;
            IF frame_stock >= p_quantity AND lens_stock >= p_quantity THEN RETURN true; END IF;
        ELSE
            RAISE EXCEPTION 'Неизвестный тип заказа: %', p_order_type;
    END CASE;

    SELECT id_sup INTO supplier_id FROM public.suppliers ORDER BY id_sup LIMIT 1 FOR KEY SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Нет поставщиков в системе'; END IF;

    IF glasses_stock < p_quantity THEN
        units_needed := p_quantity - glasses_stock;
        INSERT INTO public.supply(id_sup, date_supply, sum_supply)
        VALUES (supplier_id, CURRENT_DATE, units_needed * glasses_price)
        RETURNING id_supply INTO supply_id;
        INSERT INTO public.supply_glasses(id_supply, id_glasses, quantity, price)
        VALUES (supply_id, p_glasses_id, units_needed, glasses_price);
        UPDATE public.glasses SET quantity = p_quantity WHERE id_glasses = p_glasses_id;
    END IF;
    IF frame_stock < p_quantity THEN
        units_needed := p_quantity - frame_stock;
        INSERT INTO public.supply(id_sup, date_supply, sum_supply)
        VALUES (supplier_id, CURRENT_DATE, units_needed * frame_price)
        RETURNING id_supply INTO supply_id;
        INSERT INTO public.supply_frames(id_supply, id_frame, quantity, price)
        VALUES (supply_id, p_frame_id, units_needed, frame_price);
        UPDATE public.frames SET quantity = p_quantity WHERE id_frame = p_frame_id;
    END IF;
    IF lens_stock < p_quantity THEN
        units_needed := p_quantity - lens_stock;
        INSERT INTO public.supply(id_sup, date_supply, sum_supply)
        VALUES (supplier_id, CURRENT_DATE, units_needed * lens_price)
        RETURNING id_supply INTO supply_id;
        INSERT INTO public.supply_lenses(id_supply, id_lens, quantity, price)
        VALUES (supply_id, p_lens_id, units_needed, lens_price);
        UPDATE public.lenses SET quantity = p_quantity WHERE id_lens = p_lens_id;
    END IF;
    RETURN true;
END;
$$;


--
-- TOC entry 246 (class 1255 OID 33592)
-- Name: finish_order(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.finish_order(IN p_order_id int) LANGUAGE plpgsql AS $$
DECLARE
    ordered public.orders%ROWTYPE;
BEGIN
    SELECT * INTO ordered FROM public.orders WHERE id_order = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Заказ % не найден', p_order_id; END IF;
    IF ordered.status = 'готов' THEN RETURN; END IF;
    IF (ordered.order_type = 'custom' AND ordered.status = 'в работе')
       OR (ordered.order_type = 'ready' AND ordered.status = 'создан') THEN
        UPDATE public.orders SET status = 'готов' WHERE id_order = p_order_id;
        RETURN;
    END IF;
    RAISE EXCEPTION 'Заказ % нельзя завершить из статуса «%»', p_order_id, ordered.status;
END;
$$;


--
-- TOC entry 261 (class 1255 OID 33599)
-- Name: get_frame_stock(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_frame_stock(p_frame_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
declare
    stock int;
begin
    select quantity into stock
    from public.frames
    where id_frame = p_frame_id;

    return coalesce(stock, 0);
end;
$$;


--
-- TOC entry 262 (class 1255 OID 33601)
-- Name: get_glasses_stock(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_glasses_stock(p_glasses_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
declare
    stock int;
begin
    select quantity into stock
    from public.glasses
    where id_glasses = p_glasses_id;

    return coalesce(stock, 0);
end;
$$;


--
-- TOC entry 263 (class 1255 OID 33600)
-- Name: get_lens_stock(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_lens_stock(p_lens_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
declare
    stock int;
begin
    select quantity into stock
    from public.lenses
    where id_lens = p_lens_id;

    return coalesce(stock, 0);
end;
$$;


--
-- TOC entry 264 (class 1255 OID 33602)
-- Name: get_order_total(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_order_total(p_order_id int) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    total numeric;
BEGIN
    SELECT CASE o.order_type WHEN 'custom' THEN f.price + l.price ELSE g.price END INTO total
    FROM public.orders o
    LEFT JOIN public.frames f ON f.id_frame = o.id_frame
    LEFT JOIN public.lenses l ON l.id_lens = o.id_lens
    LEFT JOIN public.glasses g ON g.id_glasses = o.id_glasses
    WHERE o.id_order = p_order_id;
    IF NOT FOUND THEN RETURN 0; END IF;
    IF total IS NULL THEN RAISE EXCEPTION 'Невозможно рассчитать цену заказа %', p_order_id; END IF;
    RETURN total;
END;
$$;


--
-- TOC entry 272 (class 1255 OID 33647)
-- Name: get_sales_by_month(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sales_by_month(p_month integer, p_year integer) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
declare
    v_total numeric;
    v_start_date date;
    v_end_date date;
begin
    v_start_date := make_date(p_year, p_month, 1);
    v_end_date := (v_start_date + interval '1 month' - interval '1 day')::date;

    select coalesce(sum(sum_sale), 0)
    into v_total
    from public.sales
    where date_sale between v_start_date and v_end_date;

    return v_total;
end;
$$;


--
-- TOC entry 274 (class 1255 OID 33648)
-- Name: in_work_order(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.in_work_order(IN p_order_id integer)
    LANGUAGE plpgsql
    AS $$
declare
    v_current_status varchar(20);
    v_order_type varchar(20);
begin
    select status, order_type into v_current_status, v_order_type
    from public.orders
    where id_order = p_order_id for update;

    if not found then
        raise exception 'Заказ % не найден', p_order_id;
    end if;

    if v_order_type = 'ready' then
        return;
    end if;

    if v_current_status != 'создан' then
        raise exception 'Заказ % можно перевести в работу только из статуса "создан"', p_order_id;
    end if;

    update public.orders set status = 'в работе' where id_order = p_order_id;
end;
$$;


--
-- TOC entry 258 (class 1255 OID 33605)
-- Name: prevent_negative_frame_stock(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_negative_frame_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
    if new.quantity < 0 then
        raise exception 'Отрицательный остаток оправы! id=%, попытка установить %',
                        new.id_frame, new.quantity;
    end if;
    return new;
end;
$$;


--
-- TOC entry 259 (class 1255 OID 33607)
-- Name: prevent_negative_glasses_stock(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_negative_glasses_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
    if new.quantity < 0 then
        raise exception 'Отрицательный остаток готовых очков! id=%, попытка установить %',
                        new.id_glasses, new.quantity;
    end if;
    return new;
end;
$$;


--
-- TOC entry 260 (class 1255 OID 33606)
-- Name: prevent_negative_lens_stock(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_negative_lens_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
    if new.quantity < 0 then
        raise exception 'Отрицательный остаток линз! id=%, попытка установить %',
                        new.id_lens, new.quantity;
    end if;
    return new;
end;
$$;


--
-- TOC entry 267 (class 1255 OID 33595)
-- Name: receive_supply(integer, date, jsonb); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.receive_supply(IN p_supplier_id int, IN p_supply_date date, IN p_items jsonb)
LANGUAGE plpgsql AS $$
DECLARE
    supply_id int;
    item record;
    total numeric := 0;
    line_total numeric;
BEGIN
    IF p_items IS NULL THEN RAISE EXCEPTION 'Поставка должна содержать позиции'; END IF;
    IF jsonb_typeof(p_items) <> 'array' THEN
        RAISE invalid_parameter_value USING MESSAGE = 'Позиции поставки должны быть массивом JSON';
    END IF;
    -- Существование поставщика проверяет FK, в том числе для пустого массива.
    INSERT INTO public.supply(id_sup, date_supply, sum_supply)
    VALUES (p_supplier_id, p_supply_date, 0) RETURNING id_supply INTO supply_id;
    IF jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Поставка должна содержать позиции'; END IF;

    FOR item IN
        SELECT * FROM jsonb_to_recordset(p_items) AS x(type text, id int, quantity int, price numeric)
        ORDER BY x.type COLLATE "C", x.id
    LOOP
        CASE item.type
            WHEN 'frame' THEN
                INSERT INTO public.supply_frames(id_supply, id_frame, quantity, price)
                VALUES (supply_id, item.id, item.quantity, item.price) RETURNING quantity * price INTO line_total;
                UPDATE public.frames SET quantity = quantity + item.quantity WHERE id_frame = item.id;
            WHEN 'glasses' THEN
                INSERT INTO public.supply_glasses(id_supply, id_glasses, quantity, price)
                VALUES (supply_id, item.id, item.quantity, item.price) RETURNING quantity * price INTO line_total;
                UPDATE public.glasses SET quantity = quantity + item.quantity WHERE id_glasses = item.id;
            WHEN 'lens' THEN
                INSERT INTO public.supply_lenses(id_supply, id_lens, quantity, price)
                VALUES (supply_id, item.id, item.quantity, item.price) RETURNING quantity * price INTO line_total;
                UPDATE public.lenses SET quantity = quantity + item.quantity WHERE id_lens = item.id;
            ELSE
                RAISE EXCEPTION 'Неизвестный тип товара: %', item.type;
        END CASE;
        total := total + line_total;
    END LOOP;
    UPDATE public.supply SET sum_supply = total WHERE id_supply = supply_id;
    RAISE NOTICE 'Поставка % принята. ID: %', p_supplier_id, supply_id;
END;
$$;


--
-- TOC entry 265 (class 1255 OID 33615)
-- Name: trg_update_order_status_on_sale(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_update_order_status_on_sale() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.orders SET status = OLD.previous_order_status WHERE id_order = OLD.id_order;
    ELSE
        UPDATE public.orders SET status = 'выдан' WHERE id_order = NEW.id_order;
    END IF;
    RETURN NULL;
END;
$$;


--
-- TOC entry 275 (class 1255 OID 33603)
-- Name: trg_write_off_on_sale(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_write_off_on_sale() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    ordered public.orders%ROWTYPE;
    stock_change int;
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT * INTO STRICT ordered FROM public.orders WHERE id_order = OLD.id_order FOR UPDATE;
        stock_change := 1;
    ELSE
        SELECT * INTO STRICT ordered FROM public.orders WHERE id_order = NEW.id_order;
        stock_change := -1;
    END IF;

    IF ordered.order_type = 'ready' THEN
        UPDATE public.glasses SET quantity = quantity + stock_change WHERE id_glasses = ordered.id_glasses;
    ELSE
        UPDATE public.frames SET quantity = quantity + stock_change WHERE id_frame = ordered.id_frame;
        UPDATE public.lenses SET quantity = quantity + stock_change WHERE id_lens = ordered.id_lens;
    END IF;
    RETURN NULL;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 220 (class 1259 OID 33386)
-- Name: clients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clients (
    id_client integer NOT NULL,
    name character varying(50) NOT NULL,
    phone character varying(15),
    email character varying(50)
);


--
-- TOC entry 219 (class 1259 OID 33385)
-- Name: clients_id_client_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clients_id_client_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5195 (class 0 OID 0)
-- Dependencies: 219
-- Name: clients_id_client_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clients_id_client_seq OWNED BY public.clients.id_client;


--
-- TOC entry 243 (class 1259 OID 33652)
-- Name: consultants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consultants (
    id_consultant integer NOT NULL,
    name character varying(50) NOT NULL,
    phone character varying(15),
    email character varying(50),
    hire_date date DEFAULT CURRENT_DATE
);


--
-- TOC entry 242 (class 1259 OID 33651)
-- Name: consultants_id_consultant_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consultants_id_consultant_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5196 (class 0 OID 0)
-- Dependencies: 242
-- Name: consultants_id_consultant_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consultants_id_consultant_seq OWNED BY public.consultants.id_consultant;


--
-- TOC entry 222 (class 1259 OID 33399)
-- Name: frames; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.frames (
    id_frame integer NOT NULL,
    name character varying(50) NOT NULL,
    brand character varying(30),
    price numeric(10,2),
    quantity integer,
    CONSTRAINT frames_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    CONSTRAINT frames_quantity_check CHECK ((quantity >= 0))
);


--
-- TOC entry 221 (class 1259 OID 33398)
-- Name: frames_id_frame_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.frames_id_frame_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5197 (class 0 OID 0)
-- Dependencies: 221
-- Name: frames_id_frame_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.frames_id_frame_seq OWNED BY public.frames.id_frame;


--
-- TOC entry 226 (class 1259 OID 33422)
-- Name: glasses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.glasses (
    id_glasses integer NOT NULL,
    id_frame integer,
    id_lens integer,
    price numeric(10,2),
    quantity integer,
    CONSTRAINT glasses_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    CONSTRAINT glasses_quantity_check CHECK ((quantity >= 0))
);


--
-- TOC entry 225 (class 1259 OID 33421)
-- Name: glasses_id_glasses_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.glasses_id_glasses_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5198 (class 0 OID 0)
-- Dependencies: 225
-- Name: glasses_id_glasses_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.glasses_id_glasses_seq OWNED BY public.glasses.id_glasses;


--
-- TOC entry 224 (class 1259 OID 33412)
-- Name: lenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lenses (
    id_lens integer NOT NULL,
    type character varying(30),
    sphere numeric(4,2),
    coating character varying(30),
    price numeric(10,2),
    quantity integer,
    CONSTRAINT lenses_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    CONSTRAINT lenses_quantity_check CHECK ((quantity >= 0))
);


--
-- TOC entry 223 (class 1259 OID 33411)
-- Name: lenses_id_lens_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lenses_id_lens_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5199 (class 0 OID 0)
-- Dependencies: 223
-- Name: lenses_id_lens_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lenses_id_lens_seq OWNED BY public.lenses.id_lens;


--
-- TOC entry 245 (class 1259 OID 33662)
-- Name: optometrists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.optometrists (
    id_optometrist integer NOT NULL,
    name character varying(50) NOT NULL,
    phone character varying(15),
    email character varying(50),
    qualification character varying(100),
    hire_date date DEFAULT CURRENT_DATE
);


--
-- TOC entry 244 (class 1259 OID 33661)
-- Name: optometrists_id_optometrist_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.optometrists_id_optometrist_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5200 (class 0 OID 0)
-- Dependencies: 244
-- Name: optometrists_id_optometrist_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.optometrists_id_optometrist_seq OWNED BY public.optometrists.id_optometrist;


--
-- TOC entry 236 (class 1259 OID 33518)
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id_order integer NOT NULL,
    id_client integer,
    order_type character varying(20),
    id_frame integer,
    id_lens integer,
    id_glasses integer,
    id_presc integer,
    date_order date DEFAULT CURRENT_DATE,
    status character varying(20),
    id_optometrist integer,
    id_consultant integer,
    CONSTRAINT orders_check CHECK (((((order_type)::text = 'custom'::text) AND (id_frame IS NOT NULL) AND (id_lens IS NOT NULL) AND (id_glasses IS NULL)) OR (((order_type)::text = 'ready'::text) AND (id_glasses IS NOT NULL) AND (id_frame IS NULL) AND (id_lens IS NULL)))),
    CONSTRAINT orders_order_type_check CHECK (((order_type)::text = ANY ((ARRAY['custom'::character varying, 'ready'::character varying])::text[]))),
    CONSTRAINT orders_status_check CHECK (((status)::text = ANY ((ARRAY['создан'::character varying, 'в работе'::character varying, 'готов'::character varying, 'выдан'::character varying])::text[])))
);


--
-- TOC entry 235 (class 1259 OID 33517)
-- Name: orders_id_order_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orders_id_order_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5201 (class 0 OID 0)
-- Dependencies: 235
-- Name: orders_id_order_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orders_id_order_seq OWNED BY public.orders.id_order;


--
-- TOC entry 234 (class 1259 OID 33505)
-- Name: prescriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prescriptions (
    id_presc integer NOT NULL,
    id_client integer,
    left_sphere numeric(4,2),
    right_sphere numeric(4,2),
    pd integer,
    date_presc date,
    id_optometrist integer
);


--
-- TOC entry 233 (class 1259 OID 33504)
-- Name: prescriptions_id_presc_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.prescriptions_id_presc_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5202 (class 0 OID 0)
-- Dependencies: 233
-- Name: prescriptions_id_presc_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.prescriptions_id_presc_seq OWNED BY public.prescriptions.id_presc;


--
-- TOC entry 240 (class 1259 OID 33570)
-- Name: repair; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.repair (
    id_repair integer NOT NULL,
    id_client integer,
    description character varying(100),
    price numeric(10,2),
    status character varying(20),
    date_in date,
    date_out date,
    CONSTRAINT repair_check CHECK (((date_out IS NULL) OR (date_out >= date_in))),
    CONSTRAINT repair_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric)
);


--
-- TOC entry 239 (class 1259 OID 33569)
-- Name: repair_id_repair_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.repair_id_repair_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5203 (class 0 OID 0)
-- Dependencies: 239
-- Name: repair_id_repair_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.repair_id_repair_seq OWNED BY public.repair.id_repair;


--
-- TOC entry 238 (class 1259 OID 33555)
-- Name: sales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales (
    id_sale integer NOT NULL,
    id_order integer,
    date_sale date DEFAULT CURRENT_DATE,
    sum_sale numeric(10,2),
    CONSTRAINT sales_sum_sale_check CHECK (sum_sale >= 0 AND sum_sale <> 'NaN'::numeric)
);


--
-- TOC entry 237 (class 1259 OID 33554)
-- Name: sales_id_sale_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sales_id_sale_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5204 (class 0 OID 0)
-- Dependencies: 237
-- Name: sales_id_sale_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sales_id_sale_seq OWNED BY public.sales.id_sale;


--
-- TOC entry 228 (class 1259 OID 33444)
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppliers (
    id_sup integer NOT NULL,
    name character varying(50) NOT NULL,
    phone character varying(15),
    email character varying(50)
);


--
-- TOC entry 227 (class 1259 OID 33443)
-- Name: suppliers_id_sup_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.suppliers_id_sup_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5205 (class 0 OID 0)
-- Dependencies: 227
-- Name: suppliers_id_sup_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.suppliers_id_sup_seq OWNED BY public.suppliers.id_sup;


--
-- TOC entry 230 (class 1259 OID 33453)
-- Name: supply; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supply (
    id_supply integer NOT NULL,
    id_sup integer,
    date_supply date,
    sum_supply numeric(10,2),
    CONSTRAINT supply_sum_supply_check CHECK (sum_supply >= 0 AND sum_supply <> 'NaN'::numeric)
);


--
-- TOC entry 231 (class 1259 OID 33466)
-- Name: supply_frames; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supply_frames (
    id_supply integer NOT NULL,
    id_frame integer NOT NULL,
    quantity integer,
    price numeric(10,2),
    CONSTRAINT supply_frames_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    CONSTRAINT supply_frames_quantity_check CHECK ((quantity > 0))
);


--
-- TOC entry 241 (class 1259 OID 33623)
-- Name: supply_glasses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supply_glasses (
    id_supply integer NOT NULL,
    id_glasses integer NOT NULL,
    quantity integer,
    price numeric(10,2),
    CONSTRAINT supply_glasses_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    CONSTRAINT supply_glasses_quantity_check CHECK ((quantity > 0))
);


--
-- TOC entry 229 (class 1259 OID 33452)
-- Name: supply_id_supply_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.supply_id_supply_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 5206 (class 0 OID 0)
-- Dependencies: 229
-- Name: supply_id_supply_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.supply_id_supply_seq OWNED BY public.supply.id_supply;


--
-- TOC entry 232 (class 1259 OID 33485)
-- Name: supply_lenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supply_lenses (
    id_supply integer NOT NULL,
    id_lens integer NOT NULL,
    quantity integer,
    price numeric(10,2),
    CONSTRAINT supply_lenses_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    CONSTRAINT supply_lenses_quantity_check CHECK ((quantity > 0))
);


--
-- TOC entry 4943 (class 2604 OID 33389)
-- Name: clients id_client; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients ALTER COLUMN id_client SET DEFAULT nextval('public.clients_id_client_seq'::regclass);


--
-- TOC entry 4955 (class 2604 OID 33655)
-- Name: consultants id_consultant; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consultants ALTER COLUMN id_consultant SET DEFAULT nextval('public.consultants_id_consultant_seq'::regclass);


--
-- TOC entry 4944 (class 2604 OID 33402)
-- Name: frames id_frame; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frames ALTER COLUMN id_frame SET DEFAULT nextval('public.frames_id_frame_seq'::regclass);


--
-- TOC entry 4946 (class 2604 OID 33425)
-- Name: glasses id_glasses; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glasses ALTER COLUMN id_glasses SET DEFAULT nextval('public.glasses_id_glasses_seq'::regclass);


--
-- TOC entry 4945 (class 2604 OID 33415)
-- Name: lenses id_lens; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lenses ALTER COLUMN id_lens SET DEFAULT nextval('public.lenses_id_lens_seq'::regclass);


--
-- TOC entry 4957 (class 2604 OID 33665)
-- Name: optometrists id_optometrist; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.optometrists ALTER COLUMN id_optometrist SET DEFAULT nextval('public.optometrists_id_optometrist_seq'::regclass);


--
-- TOC entry 4950 (class 2604 OID 33521)
-- Name: orders id_order; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders ALTER COLUMN id_order SET DEFAULT nextval('public.orders_id_order_seq'::regclass);


--
-- TOC entry 4949 (class 2604 OID 33508)
-- Name: prescriptions id_presc; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prescriptions ALTER COLUMN id_presc SET DEFAULT nextval('public.prescriptions_id_presc_seq'::regclass);


--
-- TOC entry 4954 (class 2604 OID 33573)
-- Name: repair id_repair; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair ALTER COLUMN id_repair SET DEFAULT nextval('public.repair_id_repair_seq'::regclass);


--
-- TOC entry 4952 (class 2604 OID 33558)
-- Name: sales id_sale; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales ALTER COLUMN id_sale SET DEFAULT nextval('public.sales_id_sale_seq'::regclass);


--
-- TOC entry 4947 (class 2604 OID 33447)
-- Name: suppliers id_sup; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers ALTER COLUMN id_sup SET DEFAULT nextval('public.suppliers_id_sup_seq'::regclass);


--
-- TOC entry 4948 (class 2604 OID 33456)
-- Name: supply id_supply; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply ALTER COLUMN id_supply SET DEFAULT nextval('public.supply_id_supply_seq'::regclass);


--
-- TOC entry 4979 (class 2606 OID 33397)
-- Name: clients clients_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_email_key UNIQUE (email);


--
-- TOC entry 4981 (class 2606 OID 33395)
-- Name: clients clients_phone_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_phone_key UNIQUE (phone);


--
-- TOC entry 4983 (class 2606 OID 33393)
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id_client);


--
-- TOC entry 5013 (class 2606 OID 33660)
-- Name: consultants consultants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consultants
    ADD CONSTRAINT consultants_pkey PRIMARY KEY (id_consultant);


--
-- TOC entry 4985 (class 2606 OID 33410)
-- Name: frames frames_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frames
    ADD CONSTRAINT frames_name_key UNIQUE (name);


--
-- TOC entry 4987 (class 2606 OID 33408)
-- Name: frames frames_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frames
    ADD CONSTRAINT frames_pkey PRIMARY KEY (id_frame);


--
-- TOC entry 4991 (class 2606 OID 33432)
-- Name: glasses glasses_id_frame_id_lens_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glasses
    ADD CONSTRAINT glasses_id_frame_id_lens_key UNIQUE (id_frame, id_lens);


--
-- TOC entry 4993 (class 2606 OID 33430)
-- Name: glasses glasses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glasses
    ADD CONSTRAINT glasses_pkey PRIMARY KEY (id_glasses);


--
-- TOC entry 4989 (class 2606 OID 33420)
-- Name: lenses lenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lenses
    ADD CONSTRAINT lenses_pkey PRIMARY KEY (id_lens);


--
-- TOC entry 5015 (class 2606 OID 33670)
-- Name: optometrists optometrists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.optometrists
    ADD CONSTRAINT optometrists_pkey PRIMARY KEY (id_optometrist);


--
-- TOC entry 5005 (class 2606 OID 33528)
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id_order);


--
-- TOC entry 5003 (class 2606 OID 33511)
-- Name: prescriptions prescriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prescriptions
    ADD CONSTRAINT prescriptions_pkey PRIMARY KEY (id_presc);


--
-- TOC entry 5009 (class 2606 OID 33578)
-- Name: repair repair_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair
    ADD CONSTRAINT repair_pkey PRIMARY KEY (id_repair);


--
-- TOC entry 5007 (class 2606 OID 33563)
-- Name: sales sales_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_pkey PRIMARY KEY (id_sale);


--
-- TOC entry 4995 (class 2606 OID 33451)
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id_sup);


--
-- TOC entry 4999 (class 2606 OID 33474)
-- Name: supply_frames supply_frames_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_frames
    ADD CONSTRAINT supply_frames_pkey PRIMARY KEY (id_supply, id_frame);


--
-- TOC entry 5011 (class 2606 OID 33631)
-- Name: supply_glasses supply_glasses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_glasses
    ADD CONSTRAINT supply_glasses_pkey PRIMARY KEY (id_supply, id_glasses);


--
-- TOC entry 5001 (class 2606 OID 33493)
-- Name: supply_lenses supply_lenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_lenses
    ADD CONSTRAINT supply_lenses_pkey PRIMARY KEY (id_supply, id_lens);


--
-- TOC entry 4997 (class 2606 OID 33460)
-- Name: supply supply_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply
    ADD CONSTRAINT supply_pkey PRIMARY KEY (id_supply);


--
-- TOC entry 5039 (class 2620 OID 33643)
-- Name: sales trg_auto_replenish_before_sale; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_auto_replenish_before_sale BEFORE INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION public.auto_replenish_before_sale();


--
-- TOC entry 5036 (class 2620 OID 33608)
-- Name: frames trg_prevent_negative_frame; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_prevent_negative_frame BEFORE UPDATE OF quantity ON public.frames FOR EACH ROW EXECUTE FUNCTION public.prevent_negative_frame_stock();


--
-- TOC entry 5038 (class 2620 OID 33610)
-- Name: glasses trg_prevent_negative_glasses; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_prevent_negative_glasses BEFORE UPDATE OF quantity ON public.glasses FOR EACH ROW EXECUTE FUNCTION public.prevent_negative_glasses_stock();


--
-- TOC entry 5037 (class 2620 OID 33609)
-- Name: lenses trg_prevent_negative_lens; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_prevent_negative_lens BEFORE UPDATE OF quantity ON public.lenses FOR EACH ROW EXECUTE FUNCTION public.prevent_negative_lens_stock();


--
-- TOC entry 5040 (class 2620 OID 33604)
-- Name: sales trg_sale_stock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sale_stock AFTER INSERT OR DELETE ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.trg_write_off_on_sale();


--
-- TOC entry 5041 (class 2620 OID 33612)
-- Name: sales trg_sale_sum_calc; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sale_sum_calc BEFORE INSERT OR UPDATE ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.calculate_sale_sum();


--
-- TOC entry 5042 (class 2620 OID 33619)
-- Name: sales trg_upd_order; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_upd_order AFTER INSERT OR DELETE ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.trg_update_order_status_on_sale();


--
-- TOC entry 5016 (class 2606 OID 33433)
-- Name: glasses glasses_id_frame_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glasses
    ADD CONSTRAINT glasses_id_frame_fkey FOREIGN KEY (id_frame) REFERENCES public.frames(id_frame);


--
-- TOC entry 5017 (class 2606 OID 33438)
-- Name: glasses glasses_id_lens_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.glasses
    ADD CONSTRAINT glasses_id_lens_fkey FOREIGN KEY (id_lens) REFERENCES public.lenses(id_lens);


--
-- TOC entry 5025 (class 2606 OID 33529)
-- Name: orders orders_id_client_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_client_fkey FOREIGN KEY (id_client) REFERENCES public.clients(id_client);


--
-- TOC entry 5026 (class 2606 OID 33692)
-- Name: orders orders_id_consultant_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_consultant_fkey FOREIGN KEY (id_consultant) REFERENCES public.consultants(id_consultant);


--
-- TOC entry 5027 (class 2606 OID 33534)
-- Name: orders orders_id_frame_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_frame_fkey FOREIGN KEY (id_frame) REFERENCES public.frames(id_frame);


--
-- TOC entry 5028 (class 2606 OID 33544)
-- Name: orders orders_id_glasses_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_glasses_fkey FOREIGN KEY (id_glasses) REFERENCES public.glasses(id_glasses);


--
-- TOC entry 5029 (class 2606 OID 33539)
-- Name: orders orders_id_lens_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_lens_fkey FOREIGN KEY (id_lens) REFERENCES public.lenses(id_lens);


--
-- TOC entry 5030 (class 2606 OID 33687)
-- Name: orders orders_id_optometrist_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_optometrist_fkey FOREIGN KEY (id_optometrist) REFERENCES public.optometrists(id_optometrist);


--
-- TOC entry 5031 (class 2606 OID 33549)
-- Name: orders orders_id_presc_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_id_presc_fkey FOREIGN KEY (id_presc) REFERENCES public.prescriptions(id_presc);


--
-- TOC entry 5023 (class 2606 OID 33512)
-- Name: prescriptions prescriptions_id_client_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prescriptions
    ADD CONSTRAINT prescriptions_id_client_fkey FOREIGN KEY (id_client) REFERENCES public.clients(id_client);


--
-- TOC entry 5024 (class 2606 OID 33672)
-- Name: prescriptions prescriptions_id_optometrist_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prescriptions
    ADD CONSTRAINT prescriptions_id_optometrist_fkey FOREIGN KEY (id_optometrist) REFERENCES public.optometrists(id_optometrist);


--
-- TOC entry 5033 (class 2606 OID 33579)
-- Name: repair repair_id_client_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair
    ADD CONSTRAINT repair_id_client_fkey FOREIGN KEY (id_client) REFERENCES public.clients(id_client);


--
-- TOC entry 5032 (class 2606 OID 33564)
-- Name: sales sales_id_order_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_id_order_fkey FOREIGN KEY (id_order) REFERENCES public.orders(id_order);


--
-- TOC entry 5019 (class 2606 OID 33480)
-- Name: supply_frames supply_frames_id_frame_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_frames
    ADD CONSTRAINT supply_frames_id_frame_fkey FOREIGN KEY (id_frame) REFERENCES public.frames(id_frame);


--
-- TOC entry 5020 (class 2606 OID 33475)
-- Name: supply_frames supply_frames_id_supply_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_frames
    ADD CONSTRAINT supply_frames_id_supply_fkey FOREIGN KEY (id_supply) REFERENCES public.supply(id_supply) ON DELETE CASCADE;


--
-- TOC entry 5034 (class 2606 OID 33637)
-- Name: supply_glasses supply_glasses_id_glasses_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_glasses
    ADD CONSTRAINT supply_glasses_id_glasses_fkey FOREIGN KEY (id_glasses) REFERENCES public.glasses(id_glasses);


--
-- TOC entry 5035 (class 2606 OID 33632)
-- Name: supply_glasses supply_glasses_id_supply_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_glasses
    ADD CONSTRAINT supply_glasses_id_supply_fkey FOREIGN KEY (id_supply) REFERENCES public.supply(id_supply) ON DELETE CASCADE;


--
-- TOC entry 5018 (class 2606 OID 33461)
-- Name: supply supply_id_sup_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply
    ADD CONSTRAINT supply_id_sup_fkey FOREIGN KEY (id_sup) REFERENCES public.suppliers(id_sup);


--
-- TOC entry 5021 (class 2606 OID 33499)
-- Name: supply_lenses supply_lenses_id_lens_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_lenses
    ADD CONSTRAINT supply_lenses_id_lens_fkey FOREIGN KEY (id_lens) REFERENCES public.lenses(id_lens);


--
-- TOC entry 5022 (class 2606 OID 33494)
-- Name: supply_lenses supply_lenses_id_supply_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supply_lenses
    ADD CONSTRAINT supply_lenses_id_supply_fkey FOREIGN KEY (id_supply) REFERENCES public.supply(id_supply) ON DELETE CASCADE;


-- Completed on 2026-11-27 01:02:08

--
-- PostgreSQL database dump complete
--

-- Исправления для установки в пустой базе. Этот блок не является миграцией.
ALTER TABLE public.frames ALTER COLUMN price SET NOT NULL, ALTER COLUMN quantity SET NOT NULL;
ALTER TABLE public.lenses ALTER COLUMN price SET NOT NULL, ALTER COLUMN quantity SET NOT NULL;
ALTER TABLE public.glasses ALTER COLUMN price SET NOT NULL, ALTER COLUMN quantity SET NOT NULL;

ALTER TABLE public.prescriptions
    ADD CONSTRAINT prescriptions_id_presc_id_client_key UNIQUE (id_presc, id_client);

ALTER TABLE public.orders
    ALTER COLUMN order_type SET NOT NULL,
    ALTER COLUMN status SET NOT NULL,
    ADD CONSTRAINT orders_recipe_client_required CHECK (id_presc IS NULL OR id_client IS NOT NULL),
    ADD CONSTRAINT orders_recipe_owner_fkey FOREIGN KEY (id_presc, id_client)
        REFERENCES public.prescriptions (id_presc, id_client);

ALTER TABLE public.repair
    ALTER COLUMN price SET NOT NULL,
    ALTER COLUMN status SET NOT NULL,
    ALTER COLUMN date_in SET NOT NULL,
    ADD CONSTRAINT repair_valid_positive_price CHECK (price > 0),
    ADD CONSTRAINT repair_status_dates_check CHECK ((status = 'завершен') = (date_out IS NOT NULL)),
    ADD CONSTRAINT repair_status_domain CHECK (status IN ('принят', 'в работе', 'завершен'));

ALTER TABLE public.sales
    ALTER COLUMN id_order SET NOT NULL,
    ALTER COLUMN date_sale SET NOT NULL,
    ALTER COLUMN sum_sale SET NOT NULL,
    ADD COLUMN previous_order_status varchar(20) NOT NULL,
    ADD CONSTRAINT sales_id_order_key UNIQUE (id_order),
    ADD CONSTRAINT sales_previous_order_status_check CHECK (previous_order_status IN ('создан', 'готов'));

ALTER TABLE public.supply
    ALTER COLUMN id_sup SET NOT NULL,
    ALTER COLUMN date_supply SET NOT NULL,
    ALTER COLUMN sum_supply SET NOT NULL;
ALTER TABLE public.supply_frames ALTER COLUMN quantity SET NOT NULL, ALTER COLUMN price SET NOT NULL;
ALTER TABLE public.supply_lenses ALTER COLUMN quantity SET NOT NULL, ALTER COLUMN price SET NOT NULL;
ALTER TABLE public.supply_glasses ALTER COLUMN quantity SET NOT NULL, ALTER COLUMN price SET NOT NULL;

CREATE FUNCTION public.protect_sold_order() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'выдан' THEN
            RAISE EXCEPTION 'Для перехода в статус «выдан» оформите продажу';
        END IF;
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT FROM public.sales WHERE id_order = OLD.id_order) THEN
        IF NEW.status <> 'выдан' OR ROW(NEW.id_order, NEW.order_type, NEW.id_frame, NEW.id_lens,
               NEW.id_glasses, NEW.id_client, NEW.id_presc) IS DISTINCT FROM
               ROW(OLD.id_order, OLD.order_type, OLD.id_frame, OLD.id_lens,
                   OLD.id_glasses, OLD.id_client, OLD.id_presc) THEN
            RAISE EXCEPTION 'Сначала отмените продажу для заказа %', OLD.id_order;
        END IF;
    ELSIF NEW.status = 'выдан' THEN
        RAISE EXCEPTION 'Для перехода в статус «выдан» оформите продажу';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_protect_sold_order BEFORE INSERT OR UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.protect_sold_order();

\unrestrict 2dxnD1B7H0jrAuQoewu6N699OZIc6utb2tgBLXt6DsBrOBmjGmrG7enQahDGXfL
