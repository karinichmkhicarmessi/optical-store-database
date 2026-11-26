-- Заказы, состояние обработки и зафиксированная сумма продажи.
SELECT o.id_order, c.name AS client, o.order_type, o.status, s.sum_sale
FROM public.orders AS o
LEFT JOIN public.clients AS c USING (id_client)
LEFT JOIN public.sales AS s USING (id_order)
ORDER BY o.id_order;

-- Выручка за текущий месяц.
SELECT public.get_sales_by_month(
    EXTRACT(MONTH FROM CURRENT_DATE)::integer,
    EXTRACT(YEAR FROM CURRENT_DATE)::integer
) AS monthly_revenue;

-- Товары с остатком меньше двух единиц.
WITH stock AS (
    SELECT 'frame' AS product_type, id_frame AS product_id, quantity FROM public.frames
    UNION ALL
    SELECT 'lens', id_lens, quantity FROM public.lenses
    UNION ALL
    SELECT 'glasses', id_glasses, quantity FROM public.glasses
)
SELECT product_type, product_id, quantity
FROM stock
WHERE quantity < 2
ORDER BY quantity, product_type, product_id;

-- Поставки и суммарное количество единиц в каждой из них.
WITH lines AS (
    SELECT id_supply, quantity FROM public.supply_frames
    UNION ALL
    SELECT id_supply, quantity FROM public.supply_lenses
    UNION ALL
    SELECT id_supply, quantity FROM public.supply_glasses
)
SELECT s.id_supply, s.date_supply, sp.name AS supplier, SUM(l.quantity) AS units, s.sum_supply
FROM public.supply AS s
JOIN public.suppliers AS sp USING (id_sup)
JOIN lines AS l USING (id_supply)
GROUP BY s.id_supply, sp.name
ORDER BY s.id_supply;

-- Ремонты, которые ещё не завершены.
SELECT r.id_repair, c.name AS client, r.description, r.date_in, r.price
FROM public.repair AS r
LEFT JOIN public.clients AS c USING (id_client)
WHERE r.status <> 'завершен'
ORDER BY r.date_in, r.id_repair;
