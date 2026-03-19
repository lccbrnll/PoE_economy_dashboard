/*
  =============================================================================
  PoE Economy Dashboard - Database Schema & ETL Scripts
  Backend: PostgreSQL
  =============================================================================
*/

-- 1. STAGING AREA (Área de Ingestão de Dados Brutos)
CREATE TABLE IF NOT EXISTS items_staging (
    league VARCHAR(50),
    date DATE,
    item_id INT,
    type VARCHAR(50),
    name VARCHAR(255),
    basetype VARCHAR(255),
    variant VARCHAR(255),
    links VARCHAR(50),
    value NUMERIC,
    confidence VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS currency_staging (
    league VARCHAR(50),
    date DATE,
    get_currency VARCHAR(255),
    pay_currency VARCHAR(255),
    value NUMERIC,
    confidence VARCHAR(50)
);

-- 2. MODELO DIMENSIONAL (Star Schema)

-- 2.1 Dimensão dLeague
CREATE TABLE IF NOT EXISTS dLeague (
    id_league SERIAL PRIMARY KEY,
    league_name VARCHAR(100) NOT NULL,
    start_date DATE
);

INSERT INTO dLeague (league_name)
SELECT DISTINCT league FROM currency_staging
UNION
SELECT DISTINCT league FROM items_staging;

-- CTE para calcular a data de início (MIN date)
WITH FirstDates AS (
    SELECT league_id, MIN(date) AS first_date
    FROM (
        SELECT league_id, date FROM items UNION ALL SELECT league_id, date FROM currency
    ) AS all_dates GROUP BY league_id
)
UPDATE dLeague SET start_date = FirstDates.first_date 
FROM FirstDates WHERE dLeague.id_league = FirstDates.league_id;

-- 2.2 Dimensão dProduct 
CREATE TABLE IF NOT EXISTS dproduct (
    product_id SERIAL PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    product_type VARCHAR(100) NOT NULL,
    ui_group VARCHAR(100),
    display_type VARCHAR(100)
);

INSERT INTO dproduct (product_name, product_type)
SELECT DISTINCT name, type FROM items_staging WHERE name IS NOT NULL
UNION
SELECT DISTINCT get_currency, 'Currency' FROM currency_staging WHERE get_currency IS NOT NULL;

-- 2.3 Dimensão dCalendar (Calendário Dinâmico via generate_series)
CREATE TABLE dCalendar AS
SELECT all_dates::DATE AS date
FROM generate_series(
    (SELECT MIN(date) FROM (SELECT date FROM items_staging UNION ALL SELECT date FROM currency_staging) AS min_dates),
    (SELECT MAX(date) FROM (SELECT date FROM items_staging UNION ALL SELECT date FROM currency_staging) AS max_dates),
    '1 day'::interval
) AS all_dates;

ALTER TABLE dCalendar ADD PRIMARY KEY (date);

-- 3. DATA CLEANING & REGRAS DE NEGÓCIO (ETL)

UPDATE dproduct
SET ui_group = CASE
    WHEN product_type IN ('Currency', 'KalguuranRune', 'Runegraft', 'AllflameEmber', 'Tattoo', 'Omen', 'DivinationCard', 'Artifact', 'Oil', 'Incubator') THEN 'General'
    WHEN product_type IN ('UniqueWeapon', 'UniqueArmour', 'UniqueAccessory', 'UniqueFlask', 'UniqueJewel', 'UniqueTincture', 'UniqueRelic', 'UniqueIdol', 'SkillGem', 'ClusterJewel') THEN 'Equipment & Gems'
    WHEN product_type IN ('Map', 'BlightedMap', 'BlightRavagedMap', 'UniqueMap', 'DeliriumOrb', 'Invitation', 'Scarab', 'Memory', 'IncursionTemple') THEN 'Atlas'
    WHEN product_type IN ('BaseType', 'Fossil', 'Resonator', 'Beast', 'Essence', 'Vial', 'HelmetEnchant') THEN 'Crafting'
    ELSE 'Other'
END;

-- Resiliência a Schema Drift (Tratamento Forbidden Jewels)
UPDATE items 
SET name = variant || ' (' || name || ')'
WHERE type = 'ForbiddenJewel' AND name NOT LIKE 'Forbidden%';

-- Deduplicação Avançada via Window Functions (ctid Method)
DELETE FROM items
WHERE ctid IN (
    SELECT ctid FROM (
        SELECT ctid, ROW_NUMBER() OVER (
            PARTITION BY league, date, id, type, name, basetype, variant, links, value, confidence ORDER BY ctid
        ) as row_num FROM items
    ) clones WHERE clones.row_num > 1
);

-- 4. OTIMIZAÇÃO DE PERFORMANCE (Surrogate Keys e Normalização Temporal)

ALTER TABLE items_staging ADD COLUMN league_id INT;
ALTER TABLE currency_staging ADD COLUMN league_id INT;
ALTER TABLE items_staging ADD COLUMN league_day INT;
ALTER TABLE currency_staging ADD COLUMN league_day INT;

UPDATE items_staging AS i
SET league_id = d.id_league
FROM dLeague AS d
WHERE i.league = d.league_name;

UPDATE currency_staging AS c
SET league_id = d.id_league
FROM dLeague AS d
WHERE c.league = d.league_name;

-- Cálculo do Eixo X Dinâmico
UPDATE items_staging AS i
SET league_day = (i.date - d.start_date) + 1
FROM dLeague AS d
WHERE i.league_id = d.id_league;

UPDATE currency_staging AS c
SET league_day = (c.date - d.start_date) + 1
FROM dLeague AS d
WHERE c.league_id = d.id_league;

-- Roteamento final de Surrogate Key de Produto
UPDATE items i
SET product_id = p.product_id
FROM dproduct p
WHERE i.name = p.product_name AND i.product_id IS NULL;
