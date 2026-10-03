-- =============================================================================
-- Ad-hoc: ILM1 Order Tracker Update
-- Pull ordered/received qty for specific POs at ILM1
-- POs: 10154440, 10154441, 10154442
-- Parts: only those listed in the ILM1 order tracker
-- Output: save as ilm1_order_update.csv
-- =============================================================================

WITH tracker_parts AS (
  SELECT part FROM (VALUES
    ('3039997'),('3051071'),('3516118'),('3316632'),('3008771'),('3020139'),('3020167'),
    ('3316631'),('3020062'),('3020070'),('3020081'),('3039994'),('11300'),('3316630'),
    ('3020090'),('3020095'),('3020136'),('3481269'),('2031551'),('3020141'),('3020192'),
    ('3020110'),('1071499'),('3020082'),('3020114'),('3020117'),('3020128'),('3020133'),
    ('3020177'),('3020064'),('3077266'),('3020077'),('2038957'),('3008695'),('3008712'),
    ('3008719'),('3008732'),('3008735'),('3008736'),('3008740'),('3020089'),('3020189'),
    ('3127816'),('3127818'),('3127820'),('3127824'),('3127830'),('3127835'),('3127843'),
    ('48520'),('72899'),('815798'),('87477'),('N15848'),('N17266'),('1068918'),('1069942'),
    ('1125460'),('153378'),('2038928'),('2038968'),('3008688'),('3008689'),('3008709'),
    ('3008731'),('3008734'),('3008738'),('3008746'),('3008748'),('3008760'),('3008764'),
    ('3020109'),('3020118'),('3020160'),('3020174'),('3127815'),('3127821'),('3127832'),
    ('3127834'),('3127838'),('3127840'),('3127844'),('65245'),('69834'),('72873'),
    ('740587'),('N16799'),('N17268'),('N24364'),('2038947'),('2038971'),('3008762'),
    ('3020097'),('3020113'),('3020126'),('3020163'),('3020182'),('3127819'),('3127822'),
    ('3127842'),('69833'),('98363'),('N15838'),('N24349'),('1061077'),('1068303'),
    ('3002657'),('3020079'),('3020086'),('3020096'),('3020120'),('3020132'),('3020184'),
    ('3077257'),('3077264'),('46902'),('1000324'),('3008761'),('3020071'),('3020073'),
    ('3020075'),('3020078'),('3020148'),('3020154'),('3020191'),('3030290'),('3051073'),
    ('3059149'),('3077260'),('3077261'),('3077263'),('3020124'),('3020179'),('3020181'),
    ('3077242'),('3077265'),('3077270'),('3544859'),('C-1158'),('11447'),('3436982')
  ) AS t(part)
)

SELECT
  l.orl_part AS Part,
  trim(cast(l.orl_order AS varchar)) AS PO,
  CAST(l.orl_ordqty AS DOUBLE) AS Ordered,
  CAST(l.orl_recvqty AS DOUBLE) AS Received,
  CAST(l.orl_ordqty AS DOUBLE) - CAST(l.orl_recvqty AS DOUBLE) AS Missing
FROM "andes"."rme-gdl.r5orderlines_apm_na" l
  INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
    ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
WHERE rl.ord_org = 'ILM1'
  AND trim(cast(l.orl_order AS varchar)) IN ('10154440', '10154441', '10154442')
  AND l.orl_part IN (SELECT part FROM tracker_parts)

UNION ALL

SELECT
  l.orl_part AS Part,
  trim(cast(l.orl_order AS varchar)) AS PO,
  CAST(l.orl_ordqty AS DOUBLE) AS Ordered,
  CAST(l.orl_recvqty AS DOUBLE) AS Received,
  CAST(l.orl_ordqty AS DOUBLE) - CAST(l.orl_recvqty AS DOUBLE) AS Missing
FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
  INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
    ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
WHERE rl.ord_org = 'ILM1'
  AND trim(cast(l.orl_order AS varchar)) IN ('10154440', '10154441', '10154442')
  AND l.orl_part IN (SELECT part FROM tracker_parts)

ORDER BY Part, PO;
