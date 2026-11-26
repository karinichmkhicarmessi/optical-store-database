-- Синтетические данные для пустой базы. Пример запускается один раз.
BEGIN;

DO $$
DECLARE
    ready_client_id integer;
    second_client_id integer;
    custom_client_id integer;
    consultant_id integer;
    optometrist_id integer;
    supplier_id integer;
    frame_id integer;
    lens_id integer;
    glasses_id integer;
    prescription_id integer;
    order_id integer;
    repair_id integer;
BEGIN
    INSERT INTO public.clients(name, email) VALUES ('Клиент Демо 1', 'ready@example.invalid')
        RETURNING id_client INTO ready_client_id;
    INSERT INTO public.clients(name, email) VALUES ('Клиент Демо 2', 'ready2@example.invalid')
        RETURNING id_client INTO second_client_id;
    INSERT INTO public.clients(name, email) VALUES ('Клиент Демо 3', 'custom@example.invalid')
        RETURNING id_client INTO custom_client_id;
    INSERT INTO public.consultants(name) VALUES ('Консультант Демо')
        RETURNING id_consultant INTO consultant_id;
    INSERT INTO public.optometrists(name, qualification) VALUES ('Оптометрист Демо', 'Учебный пример')
        RETURNING id_optometrist INTO optometrist_id;
    INSERT INTO public.suppliers(name, email) VALUES ('Поставщик Демо', 'supplier@example.invalid')
        RETURNING id_sup INTO supplier_id;

    INSERT INTO public.frames(name, brand, price, quantity) VALUES ('Оправа Демо', 'Demo', 1550, 0)
        RETURNING id_frame INTO frame_id;
    INSERT INTO public.lenses(type, sphere, coating, price, quantity)
        VALUES ('Однофокусная', -1.25, 'Защитное', 950, 0) RETURNING id_lens INTO lens_id;
    INSERT INTO public.glasses(id_frame, id_lens, price, quantity) VALUES (frame_id, lens_id, 3600, 0)
        RETURNING id_glasses INTO glasses_id;

    CALL public.receive_supply(supplier_id, CURRENT_DATE, jsonb_build_array(
        jsonb_build_object('type','frame','id',frame_id,'quantity',2,'price',850),
        jsonb_build_object('type','lens','id',lens_id,'quantity',2,'price',420),
        jsonb_build_object('type','glasses','id',glasses_id,'quantity',1,'price',2100)
    ));

    CALL public.create_order(ready_client_id, 'ready', NULL, NULL, glasses_id, NULL, NULL, consultant_id);
    SELECT id_order INTO STRICT order_id FROM public.orders WHERE id_client = ready_client_id;
    CALL public.create_sale(order_id);

    -- После первой продажи остаток очков равен нулю. Вторая вызывает автопополнение.
    CALL public.create_order(second_client_id, 'ready', NULL, NULL, glasses_id, NULL, NULL, consultant_id);
    SELECT id_order INTO STRICT order_id FROM public.orders WHERE id_client = second_client_id;
    CALL public.create_sale(order_id);

    INSERT INTO public.prescriptions(id_client, left_sphere, right_sphere, pd, date_presc, id_optometrist)
        VALUES (custom_client_id, -1.25, -1.25, 62, CURRENT_DATE, optometrist_id)
        RETURNING id_presc INTO prescription_id;
    CALL public.create_order(custom_client_id, 'custom', frame_id, lens_id, NULL, prescription_id,
                             optometrist_id, consultant_id);
    SELECT id_order INTO STRICT order_id FROM public.orders WHERE id_client = custom_client_id;
    CALL public.in_work_order(order_id);
    CALL public.finish_order(order_id);
    CALL public.create_sale(order_id);

    CALL public.create_repair(ready_client_id, 'Замена носоупоров', 350);
    SELECT id_repair INTO STRICT repair_id FROM public.repair WHERE id_client = ready_client_id;
    CALL public.complete_repair(repair_id);
    CALL public.create_repair(second_client_id, 'Регулировка дужек', 250);
END;
$$;

COMMIT;
