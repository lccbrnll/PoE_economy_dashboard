[English Version](#english-version) | [Versão em Português](#versão-em-português)

---

## English Version

# Technical Documentation & Logbook

This document details all the steps, logic, and code developed during the creation of the **PoE Economy Dashboard**, documented in chronological order of execution.

### 1. Dimension Creation (Star Schema)
To avoid many-to-many relationships and optimize dashboard filters, I built dimension tables ("bridges") connecting the FACT tables (`fCurrency` and `fItems`).

### 2. League Dimension Table (dleague)
Created in PostgreSQL to centralize the leagues.
```sql
CREATE TABLE dLeague (
    id_league SERIAL PRIMARY KEY,
    league_name VARCHAR(100) NOT NULL
);
```
Then, I used `UNION` to extract the unique values (`DISTINCT`) from both fact tables simultaneously, ensuring a clean list:
```sql
INSERT INTO dLeague (league_name)
SELECT DISTINCT league FROM currency
UNION
SELECT DISTINCT league FROM items;
```

### 3. Continuous Calendar Table (dCalendar)
Created in PostgreSQL to guarantee continuous time intelligence in Power BI. I used the `generate_series()` function combined with `MIN` and `MAX` subqueries extracting data from both fact tables:
```sql
CREATE TABLE dCalendar AS
SELECT
    all_dates::DATE AS date
FROM generate_series(
    (SELECT MIN(date) FROM (SELECT date FROM items UNION ALL SELECT date FROM currency) AS all_dates_min),
    (SELECT MAX(date) FROM (SELECT date FROM items UNION ALL SELECT date FROM currency) AS all_dates_max),
    '1 day'::interval
) AS all_dates;
```
**Why create the table this way?** The code is 100% dynamic. The insertion of future league data will automatically adjust the calendar without the need to refactor the SQL code. `::Date` was used to clean timestamps and prevent relationship bugs in Power BI.

### 4. Performance Optimization (Surrogate Keys)
Initially, the fact tables were related using text names (e.g., "Affliction"). Since the tables have millions of rows, this generated a high computational cost. I altered the database (DDL and DML) by adding `league_id` (INT) columns to the Fact tables, and populated them via an `UPDATE / JOIN` with the `dleague` table.
```sql
ALTER TABLE public.items ADD COLUMN league_id INT;
ALTER TABLE public.currency ADD COLUMN league_id INT;

UPDATE public.items as i
SET league_id = d.id_league
FROM public.dleague as d
WHERE i.league = d.league_name;

UPDATE public.currency as c
SET league_id = d.id_league
FROM public.dleague as d
WHERE c.league = d.league_name;
```
**Result:** Replacing Text keys with Numeric keys reduces RAM consumption and accelerates the processing of filters and visuals.

### 5. Filter Unification & UX (Resolving Non-Conformed Dimensions)
**The Problem:** Because the tables separate conventional items (`fItems`) and currencies (`fCurrency`), creating a global search bar and a single category menu wouldn't work natively in Power BI without generating hierarchy conflicts. For this, I created a consolidated `dProduct` dimension in PostgreSQL to serve as a single bridge.
```sql
CREATE TABLE dproduct (
    product_id SERIAL PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    product_type VARCHAR(100) NOT NULL
);
```
**Data Quality Challenge:** During the `UNION` of raw data, the database threw a `NOT NULL` violation. I identified that the original `.csv` file contained "dirty" records (items with a defined type but no name).
**Action:** I adjusted the extraction query to filter the "garbage" directly at the source, ensuring model integrity:
```sql
INSERT INTO dproduct (product_name, product_type)
SELECT DISTINCT name, type FROM items WHERE name IS NOT NULL
UNION
SELECT DISTINCT get_currency, 'Currency' FROM currency WHERE get_currency IS NOT NULL;
```

### 6. Applying Business Rules (UI/UX in the Database)
**The Problem:** The game has over 30 native item classifications (`product_type`). For the end-user, this clutters the screen. The goal was to replicate the intuitive navigation of the poe.ninja website, which groups these items into 4 main blocks.
**The Solution:** I added a `ui_group` column to the `dProduct` table and built the grouping rule using `CASE WHEN`. Mapping this in the Data Warehouse (instead of Power BI) centralizes the business rule and makes the front-end lighter:
```sql
ALTER TABLE dproduct ADD COLUMN ui_group VARCHAR(100);

UPDATE dproduct
SET ui_group = CASE
    WHEN product_type IN ('Currency', 'KalguuranRune', 'Runegraft', 'AllflameEmber', 'Tattoo', 'Omen', 'DivinationCard', 'Artifact', 'Oil', 'Incubator') THEN 'General'
    WHEN product_type IN ('UniqueWeapon', 'UniqueArmour', 'UniqueAccessory', 'UniqueFlask', 'UniqueJewel', 'UniqueTincture', 'UniqueRelic', 'UniqueIdol', 'SkillGem', 'ClusterJewel') THEN 'Equipment & Gems'
    WHEN product_type IN ('Map', 'BlightedMap', 'BlightRavagedMap', 'UniqueMap', 'DeliriumOrb', 'Invitation', 'Scarab', 'Memory', 'IncursionTemple') THEN 'Atlas'
    WHEN product_type IN ('BaseType', 'Fossil', 'Resonator', 'Beast', 'Essence', 'Vial', 'HelmetEnchant') THEN 'Crafting'
    ELSE 'Other'
END;
```
Finally, I replicated the Surrogate Keys technique from step 4, creating the `product_id` (INT) column in the fact tables for performance optimization.

### 7. Unified Calculations Across Multiple Fact Tables (DAX)
**The Problem:** The central table needed to display the updated price ("Current Price") of any item. Since items and currencies are separated into two fact tables, a simple measure wouldn't work.
**The Solution:** I created a smart measure using the `COALESCE` function, which tries to fetch the last date and value in the items table; if it returns blank, it searches the currency table.
```dax
Current Price (Chaos) = 
VAR LastItemDate = MAX('fItems'[date])
VAR ItemPrice = CALCULATE(
    AVERAGE('fItems'[value]),
    'fItems'[date] = LastItemDate
)

VAR LastCurrencyDate = MAX('fCurrency'[date])
VAR CurrencyPrice = CALCULATE(
    AVERAGE('fCurrency'[value]),
    'fCurrency'[date] = LastCurrencyDate
)

RETURN
COALESCE(ItemPrice, CurrencyPrice)
```

### 8. Time Intelligence & Trends (7-Day Sparklines)
**The Problem:** Power BI's native Sparkline feature draws a line using the entire available data history. The UI goal was to replicate the "Last 7 Days" view starting from the last recorded date of each item.
**The Solution:** I developed a DAX measure with time-window logic. The code sets an anchor on the item's last day, tests if the current X-axis date is within the 7-day window, and returns `BLANK()` for older dates. This "crops" the native Power BI chart, forcing it to display only the recent trend.
```dax
Historical Price (7 days) = 
VAR LastItemDate = CALCULATE(MAX('fItems'[date]), REMOVEFILTERS('dCalendar'))
VAR LastCurrDate = CALCULATE(MAX('fCurrency'[date]), REMOVEFILTERS('dCalendar'))

VAR CurrentSparklineDate = MAX('dCalendar'[date])

VAR IsValidItemDate = CurrentSparklineDate >= (LastItemDate - 6) && CurrentSparklineDate <= LastItemDate
VAR IsValidCurrDate = CurrentSparklineDate >= (LastCurrDate - 6) && CurrentSparklineDate <= LastCurrDate

VAR ItemVal = 
    IF(IsValidItemDate, 
        CALCULATE(AVERAGE('fItems'[value]), ALL('fItems'[confidence])), // ALL quebra o bloqueio visual
        BLANK()
    )
VAR CurrVal = 
    IF(IsValidCurrDate, 
        CALCULATE(AVERAGE('fCurrency'[value]), ALL('fCurrency'[confidence])), // ALL quebra o bloqueio visual
        BLANK()
    )

RETURN COALESCE(ItemVal, CurrVal)
```

### 9. Percentage Change & UI/UX Tricks
**The Mathematical and Visual Challenge:** I needed to calculate the exact weekly growth and group this visually with the sparkline. Power BI does not allow merging header cells.
**The Solution (DAX):** I created a measure retrieving the current value and comparing it with the value from exactly 7 days ago using `CALCULATE`, joining items and currencies with `COALESCE`.
```dax
7 days Change % = 
VAR CurrentVal = [Current Price (Chaos)]

VAR LastItemDate = CALCULATE(MAX('fItems'[date]))
VAR OldItemVal = 
    CALCULATE(
        AVERAGE('fItems'[value]), 
        'fItems'[date] = LastItemDate - 6,
        REMOVEFILTERS('fItems'[confidence])
    )

VAR LastCurrDate = CALCULATE(MAX('fCurrency'[date]))
VAR OldCurrVal = 
    CALCULATE(
        AVERAGE('fCurrency'[value]), 
        'fCurrency'[date] = LastCurrDate - 6,
        REMOVEFILTERS('fCurrency'[confidence])
    )

VAR OldVal = COALESCE(OldItemVal, OldCurrVal)

RETURN
DIVIDE(CurrentVal - OldVal, OldVal)
```
**The Solution (UI/UX):** For the GUI, I applied the "Ghost Header" trick: renamed the percentage column to "Last 7 days" and the sparkline column with a space character (empty). I aligned the values on opposite ends and moved the columns closer, tricking the user's vision into seeing a single grouped section. Lastly, I used Custom conditional formatting (`+#,0%;-#,0%;0%`) to add the "+" sign and green/red colors.

### 10. Source Nomenclature Standardization (Data Cleaning)
**The Problem:** The native game types are in CamelCase format (e.g., `UniqueAccessory`, `SkillGem`), making reading the side menu highly technical and unfriendly.
**The Solution:** Keeping the rule of "transforming the data as close to the source as possible," I added a `display_type` column in the dimension table (`dProduct`) in PostgreSQL. I used a `CASE WHEN` statement to map and translate original terms into formatted plurals with spaces, keeping the front-end lightweight.
```sql
UPDATE dproduct
SET display_type = CASE
    WHEN product_type = 'Currency' THEN 'Currency'
    WHEN product_type = 'KalguuranRune' THEN 'Kalguuran Runes'
    WHEN product_type = 'Essence' THEN 'Essences'
    WHEN product_type = 'Vial' THEN 'Vials'
    WHEN product_type = 'HelmetEnchant' THEN 'Helmet Enchants'
    ELSE product_type
END;
```

### 11. Global Currency Anchor (Filter Context)
**The Problem:** To create a dynamic currency conversion filter (Chaos to Divines), the dashboard needed to know the exact rate of the "Divine Orb" every day. However, calculating this in the central table broke the row context when passing through normal items.
**The Solution:** I created an anchor measure using `REMOVEFILTERS`. This forces Power BI to ignore the specific row the table is reading and fetch the absolute value of the Divine Orb on the most recent available date, serving as a global variable.
```dax
Divine Price in Chaos = 
VAR CurrentDate = CALCULATE(MAX('fCurrency'[date]), REMOVEFILTERS('dproduct'))

RETURN
CALCULATE(
    AVERAGE('fCurrency'[value]),
    'dproduct'[product_name] = "Divine Orb",
    'fCurrency'[date] = CurrentDate,
    REMOVEFILTERS('dproduct')
)
```

### 12. UI Parameters (Disconnected Table)
**The Problem:** I needed to create on-screen buttons for the user to choose the display type ("Adaptive", "Chaos", "Divine"). Since these words represent logical rules and not real database data, creating a native filter wasn't possible.
**The Solution:** I created a Disconnected Table (Parameter Table) called `ValueDisplay` using Power BI's "Enter Data" function. It contains a single column with text options and has no relationship with the model, serving exclusively to capture the user's click via DAX.

### 13. Dynamic Price Logic and Text Formatting
**The Problem:** The price display needed to obey complex rules of the game's economy: dynamic conversion, formatting Chaos as integers and Divines with decimals, inverting logic for cheap currencies, and treating the "Divine Orb" itself as an exception.
**The Solution:** I developed a robust DAX measure combining `SELECTEDVALUE`, fraction math, and the `FORMAT` function. The `SWITCH` statement acts as the final router.
```dax
Dynamic Price (Display) = 
VAR SelectedDisplay = SELECTEDVALUE('_UI_ValueDisplay'[Display Option], "Adaptive")

VAR CurrentItem = MAX('dproduct'[product_name])

VAR PriceInChaos = [Current Price (Chaos)]
VAR DivineAnchor = [Divine Price in Chaos]

VAR PriceInDivines = DIVIDE(PriceInChaos, DivineAnchor) 
VAR AmountPerDivine = DIVIDE(DivineAnchor, PriceInChaos)

VAR IsWholeDivine = ROUND(PriceInDivines, 1) = INT(ROUND(PriceInDivines, 1))
VAR DivineFormat = IF(IsWholeDivine, "#,##0", "#,##0.0")

VAR InvertedPrice = DIVIDE(1, PriceInChaos)
VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR TextChaos = 
    IF(PriceInChaos < 1 && PriceInChaos > 0,
        "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
        FORMAT(PriceInChaos, "#,##0") & " c"
    )

VAR TextDivine = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor,
            FORMAT(PriceInDivines, DivineFormat) & " div",
            "1 div = " & FORMAT(AmountPerDivine, "#,##0")
        )
    )

VAR TextAdaptive = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor, 
            FORMAT(PriceInDivines, DivineFormat) & " div", 
            IF(PriceInChaos < 1 && PriceInChaos > 0,
                "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
                FORMAT(PriceInChaos, "#,##0") & " c"
            )
        )
    )

VAR FinalDisplay = SelectedDisplay

RETURN
SWITCH(
    FinalDisplay,
    "Chaos", TextChaos,
    "Divine", TextDivine,
    "Adaptive", TextAdaptive,
    TextAdaptive
)
```

### 14. UI/UX Tricks: Invisible Sorting and Table Protection
**The Solution (Hidden Sort):** I added the purely mathematical measure (`Current Price (Chaos)`) to the table, sorted descending by it, and then reduced the column width until it disappeared from the screen. I matched the font and background colors to camouflage the last remaining pixel.
**The Solution (Screen Shield):** To prevent users from breaking the sort by clicking other column headers, I inserted a 100% transparent Power BI Rectangle visual over the table header. It acts as a physical barrier in the UI, blocking clicks on titles without hindering table scrolling.

### 15. Advanced Decimal Formatting and Inverse Fractions (UI/UX)
**The Problem:** Standard formatting left an "orphan" decimal point on whole numbers (e.g., "8. div"). Additionally, for very cheap items, showing the direct price doesn't make sense. The math had to be inverted to show "X units per 1 Chaos/Divine".
**The Solution:** I created math checks using `INT(ROUND())` and applied conditional IF blocks to invert the division.
**15.1 - Dynamic Measure:**
```dax
Dynamic Price (Display) = 
VAR SelectedDisplay = SELECTEDVALUE('_UI_ValueDisplay'[Display Option], "Adaptive")

VAR CurrentItem = MAX('dproduct'[product_name])

VAR PriceInChaos = [Current Price (Chaos)]
VAR DivineAnchor = [Divine Price in Chaos]

VAR PriceInDivines = DIVIDE(PriceInChaos, DivineAnchor) 
VAR AmountPerDivine = DIVIDE(DivineAnchor, PriceInChaos)

VAR IsWholeDivine = ROUND(PriceInDivines, 1) = INT(ROUND(PriceInDivines, 1))
VAR DivineFormat = IF(IsWholeDivine, "#,##0", "#,##0.0")

VAR InvertedPrice = DIVIDE(1, PriceInChaos)
VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR TextChaos = 
    IF(PriceInChaos < 1 && PriceInChaos > 0,
        "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
        FORMAT(PriceInChaos, "#,##0") & " c"
    )

VAR TextDivine = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor,
            FORMAT(PriceInDivines, DivineFormat) & " div",
            "1 div = " & FORMAT(AmountPerDivine, "#,##0")
        )
    )

VAR TextAdaptive = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor, 
            FORMAT(PriceInDivines, DivineFormat) & " div", 
            IF(PriceInChaos < 1 && PriceInChaos > 0,
                "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
                FORMAT(PriceInChaos, "#,##0") & " c"
            )
        )
    )

VAR FinalDisplay = SelectedDisplay

RETURN
SWITCH(
    FinalDisplay,
    "Chaos", TextChaos,
    "Divine", TextDivine,
    "Adaptive", TextAdaptive,
    TextAdaptive
)
```
**15.2 - Detail Cards:**
```dax
Detail Card (Divine Price) = 
VAR PriceChaos = [Current Price (Chaos)]
VAR DivineAnchor = [Divine Price in Chaos]

VAR PriceDivine = DIVIDE(PriceChaos, DivineAnchor)
VAR AmountPerDivine = DIVIDE(DivineAnchor, PriceChaos)

VAR CurrentItem = MAX('dproduct'[product_name])

VAR IsWholeDivine = ROUND(PriceDivine, 1) = INT(ROUND(PriceDivine, 1))
VAR DivineFormat = IF(IsWholeDivine, "#,##0", "#,##0.0")

VAR IsWholeAmount = ROUND(AmountPerDivine, 1) = INT(ROUND(AmountPerDivine, 1))
VAR AmountFormat = IF(IsWholeAmount, "#,##0", "#,##0.0")

RETURN
IF(
    CurrentItem = "Divine Orb",
    "1 Divine",
    IF(
        PriceChaos >= DivineAnchor,
        FORMAT(PriceDivine, DivineFormat) & " Divines",
        "1 Divine = " & FORMAT(AmountPerDivine, AmountFormat) & " units"
    )
)
```

### 16. Details Page (Drill-through)
I created a secondary page configured as a Drill-through destination, using the `product_name` column as an anchor with the "Keep all filters" option enabled. I added dynamic title cards using `MAX(product_name)` to update the UI based on the clicked item.

### 17. Temporal Normalization and Dynamic X-Axis (PostgreSQL)
**The Problem:** Path of Exile leagues start on different dates. A standard line chart would create time gaps and prevent visual overlap for comparison.
**The Solution:**
17.1 I used a CTE to find the absolute start date of each league and recorded it in `dleague`.
17.2 In the fact tables, I calculated the day difference (Item Date - League Start Date) + 1, generating the `league_day` column.
17.3 I created a normalized time dimension (`dleagueday`) ensuring the axis adjusts automatically.
```sql
-- CTE for start date
WITH FirstDates AS (
    SELECT league_id, MIN(date) AS first_date
    FROM (
        SELECT league_id, date FROM items UNION ALL SELECT league_id, date FROM currency
    ) AS all_dates GROUP BY league_id
)
UPDATE dleague SET start_date = FirstDates.first_date FROM FirstDates WHERE dleague.id_league = FirstDates.league_id;

-- Days Dimension Creation
CREATE TABLE dleagueday AS
SELECT generate_series(
    1,
    (SELECT MAX(league_day) FROM (SELECT league_day FROM items UNION ALL SELECT league_day FROM currency) AS all_days)
) AS day_index;

ALTER TABLE dleagueday ADD PRIMARY KEY (day_index);
```

### 18. Breaking the Drill-through Lock (League Comparator)
**The Problem:** Because Drill-through locks the entire page to a single league, a native Slicer visual cannot add a second league to the chart.
**The Solution:** I created a fake table named `CompareLeague` using `UNION` and `DISTINCT`. Since it lacks relationships, it's unaffected by page filters. I then created a measure using `REMOVEFILTERS` to bypass the page lock and plot a second Y-axis line.
```dax
CompareLeague =
UNION(
    ROW("league_name", " None"),
    DISTINCT('dleague'[league_name])
)
```
```dax
Compare Price (Chaos) = 
VAR SelectedCompareLeague = SELECTEDVALUE('_UI_CompareLeague'[league_name])

VAR Result = 
CALCULATE(
    [Current Price (Chaos)],
    REMOVEFILTERS('dleague'),
    'dleague'[league_name] = SelectedCompareLeague
)

RETURN
IF(SelectedCompareLeague = " None" || ISBLANK(SelectedCompareLeague), BLANK(), Result)
```

### 19. Senior UX: Smart Filters (Gatekeeper)
**The Problem:** The comparison Dropdown showed leagues where the filtered item didn't even exist, generating "Dead Ends".
**The Solution:** I created an invisible "Support Measure" acting as a boolean rule evaluating if the Dropdown league matches the original page league, and using `COUNTROWS` to check for records. I applied this to the visual filter pane to hide invalid options.
```dax
Filter (Valid Compare League) = 
VAR SlicerLeague = MAX('_UI_CompareLeague'[league_name])
// Captura a liga original que o usuário trouxe pelo Drill-through
VAR OriginalLeague = SELECTEDVALUE('dleague'[league_name])

VAR CheckItems = 
    CALCULATE(
        COUNTROWS('fItems'),
        REMOVEFILTERS('dleague'),
        'dleague'[league_name] = SlicerLeague
    )
    
VAR CheckCurrency = 
    CALCULATE(
        COUNTROWS('fCurrency'),
        REMOVEFILTERS('dleague'),
        'dleague'[league_name] = SlicerLeague
    )

RETURN
IF(
    SlicerLeague = " None", 
    1, 
    IF(
        SlicerLeague = OriginalLeague, // Se for a mesma liga do Drill-through...
        0,                             // ...toma nota 0 e some do Dropdown.
        IF(CheckItems > 0 || CheckCurrency > 0, 1, 0)
    )
)
```

### 20. Historical Trend Analysis (All-Time High / Low)
**The Problem:** Displaying the highest and lowest price an item has ever reached. Basic `MAX()` functions don't work on dynamic measures, and `MIN()` could capture blank days.
**The Solution:** I used iterator functions (`MAXX` and `MINX`) with security layers (`FILTER`) to ignore days without listings.
```dax
Highest Price (Display) = 
VAR MaxPrice = 
    MAXX(
        VALUES('dleagueday'[day_index]),
        [Current Price (Chaos)]
    )
VAR InvertedPrice = DIVIDE(1, MaxPrice)

VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR IsWholePrice = ROUND(MaxPrice, 1) = INT(ROUND(MaxPrice, 1))
VAR PriceFormat = IF(IsWholePrice, "#,##0", "#,##0.0")

RETURN
IF(ISBLANK(MaxPrice), BLANK(),
    IF(
        MaxPrice < 1 && MaxPrice > 0,
        "1 Chaos = " & FORMAT(InvertedPrice, InvertedFormat) & " units",
        FORMAT(MaxPrice, PriceFormat) & " Chaos"
    )
)
```
```dax
Lowest Price (Display) = 
VAR MinPrice = 
    MINX(
        FILTER(
            VALUES('dleagueday'[day_index]),
            NOT ISBLANK([Current Price (Chaos)])
        ),
        [Current Price (Chaos)]
    )
VAR InvertedPrice = DIVIDE(1, MinPrice)

VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR IsWholePrice = ROUND(MinPrice, 1) = INT(ROUND(MinPrice, 1))
VAR PriceFormat = IF(IsWholePrice, "#,##0", "#,##0.0")

RETURN
IF(ISBLANK(MinPrice), BLANK(),
    IF(
        MinPrice < 1 && MinPrice > 0,
        "1 Chaos = " & FORMAT(InvertedPrice, InvertedFormat) & " units",
        FORMAT(MinPrice, PriceFormat) & " Chaos"
    )
)
```

### 21. 3-Day Moving Average (Trading View)
**The Problem:** In-game prices suffer from weekend "noise" (demand spikes).
**The Solution:** I created a DAX "Time Machine." The variable creates a dynamic 3-day window using `FILTER` and `ALL`. Then, `AVERAGEX` calculates the price average for that window.
```dax
Moving Average 3 days (Chaos) = 
VAR CurrentDay = MAX('dleagueday'[day_index])

VAR Window3Days = 
    FILTER(
        ALL('dleagueday'),
        'dleagueday'[day_index] <= CurrentDay &&
        'dleagueday'[day_index] >= CurrentDay - 2
    )

RETURN
AVERAGEX(
    Window3Days,
    [Current Price (Chaos)]
)
```
```dax
Dynamic Moving Average = 
VAR UserChoice = SELECTEDVALUE('_UI_ToggleTrend'[Option], "Hide Trend")

RETURN
IF(
    UserChoice = "Show Trend",
    [Moving Average 3 days (Chaos)],
    BLANK()
)
```

### 22. Data QA and the VertiPaq Engine (The Optimization that didn't happen)
**The Problem/Reflection:** Aiming to optimize VertiPaq RAM consumption, I planned to change the Data Type to Fixed Decimal Number. During QA, I identified scientific notation values (`1E-05`) representing micro-fractions. I maintained the Decimal Number type, prioritizing the mathematical integrity of the economy over memory optimization.

### 23. Dead Link Cleanup (Dynamic UI/UX in Table)
**The Problem:** Creating a button leading to the official PoE Wiki, but many categories or legacy items generated 404 Errors.
**The Solution:** I created an intelligent conditional column in the `dProduct` table using `SUBSTITUTE` and `CONTAINSSTRING` to identify forbidden prefixes or unlinked categories, returning `BLANK()` and dynamically disabling the front-end button.
```dax
Wiki_Link =
VAR ItemName = 'dProduct'[product_name]
VAR IsExcludedCategory = 'dProduct'[display_type] IN {"Cluster Jewels", "Memories", "Temples", "Beasts", "Helmet Enchants"}
VAR IsLegacyGem = CONTAINSSTRING(ItemName, "Anomalous ") || CONTAINSSTRING(ItemName, "Divergent ") || CONTAINSSTRING(ItemName, "Phantasmal ")
RETURN IF(
    IsExcludedCategory || IsLegacyGem,
    BLANK(),
    "[https://www.poewiki.net/wiki/](https://www.poewiki.net/wiki/)" & SUBSTITUTE(ItemName, " ", "_")
)
```

### 24. Custom Tooltips and the Waterfall Problem (Context Direction)
**The Problem:** The Tooltip Date stayed "frozen" on the league's last day.
**The Solution:** Understanding Star Schema "Filter Direction". The X-axis filtered the Fact tables, but didn't flow upstream to the Calendar. I rewrote the Tooltip date to pull directly from the filtered fact tables using `COALESCE`, unfreezing the visual.
```dax
Tooltip Date = 
VAR ItemDate = MAX('fItems'[date])
VAR CurrencyDate = MAX('fCurrency'[date])

VAR CurrentDate = COALESCE(ItemDate, CurrencyDate)

RETURN
IF(
    ISBLANK(CurrentDate), 
    BLANK(), 
    FORMAT(CurrentDate, "ddd MMM dd yyyy")
)
```

### 25. Interaction Control (Shielding Cards)
I used Power BI's "Edit Interactions" feature to build a visual shield, setting the Line Chart interaction to "None" regarding the All-Time High/Low cards. The chart highlights the selected day for micro-analysis, but the cards ignore the click, maintaining macro integrity.

### 26. Table Optimization with Top N (Instant Loading)
Loading thousands of items consumed heavy processing. I applied a native visual "Top 100" filter based on Value. Because Power BI processes Search Slicers before visual filters, global search continues to work instantly (a specific searched item passes the Top 100 filter because 1 < 100), guaranteeing an ultra-light table.

### 27. Smart Slicers and Dynamic Menus (Preventing Empty Clicks)
**The Problem:** Leagues with partial databases (e.g., only currency) still displayed "Gems" in the menu.
**The Solution:** I transformed the text Slicer into a self-aware menu by adding the `Current Price (Chaos)` measure to its visual filter pane, requiring the value to be `is not blank`. Empty categories organically disappear.

### 28. QA Protocol and Performance Analyzer
I implemented a testing flow using the native "Performance Analyzer" tool to record response times to clicks, consolidated with a "Sanity Check" using anchor items (like Headhunter) to validate if the DAX math perfectly matched the pure SQL query outputs.

### 29. Secure Ingestion and Landing Area (Staging Area)
**The Problem:** PostgreSQL threw a missing column error when importing a new league CSV because the Fact table had evolved (`league_id` and `league_day` added).
**The Solution:** Implemented the Staging Area pattern. I created temporary tables matching the CSV, performed a safe `COPY`, and used an `INSERT INTO ... SELECT` command specifying original columns, allowing new columns to remain `NULL` ready for updates.

### 30. Resilience to Schema Drift (The Forbidden Jewels Case)
**The Problem:** The game API changed how it cataloged composite items (splitting type and passive name), causing granularity collisions in Power BI.
**The Solution:** Since the API altered its own structure (Schema Drift), we used SQL to repair data model consistency by concatenating strings directly in the Fact table, keeping the historical series intact.
```sql
UPDATE items 
SET name = variant || ' (' || name || ')'
WHERE type = 'ForbiddenJewel' AND name NOT LIKE 'Forbidden%';
```

### 31. Data Sanitization and Advanced Deduplication
**The Problem:** QA identified "cloned" records from API connection failures.
**The Solution:** Used an advanced "SQL Vacuum" utilizing `ROW_NUMBER()` combined with PostgreSQL's internal physical address (`ctid`) to sweep and delete exact clones, keeping the original row intact.
```sql
DELETE FROM items WHERE ctid IN (
    SELECT ctid FROM (
        SELECT ctid, ROW_NUMBER() OVER (
            PARTITION BY league, date, id, type, name, basetype, variant, links, value, confidence ORDER BY ctid
        ) as row_num FROM items WHERE league = 'Keepers'
    ) clones WHERE clones.row_num > 1
);
```

### 32. Surrogate Keys Bug and Orphaned Relationships
**The Problem:** After ingesting a new league, charts returned Blank Rows because the script didn't stamp the ForeignKey (`product_id`) on the new Fact table rows.
**The Solution:** Refactored the incremental load script via `UPDATE...FROM` to ensure proper routing of numeric IDs.
```sql
UPDATE items i
SET product_id = p.product_id
FROM dproduct p
WHERE i.name = p.product_name AND i.product_id IS NULL;
```

---

## Versão em Português

# Documentação Técnica e Diário de Bordo

Este documento detalha todos os passos, lógicas e códigos desenvolvidos durante a criação do **PoE Economy Dashboard**, documentados em ordem cronológica de execução.

### 1. Criação de Dimensões (Star Schema)
Para evitar relacionamentos de many-to-many e otimizar os filtros do dashboard, construí tabelas de dimensão ("pontes") conectando as tabelas FATO (`fCurrency` e `fItems`).

### 2. Tabela de Dimensão de Ligas (dleague)
Criada no PostgresSQL para centralizar as ligas.
```sql
CREATE TABLE dLeague (
    id_league SERIAL PRIMARY KEY,
    league_name VARCHAR(100) NOT NULL
);
```
Depois, usei `UNION` para extrair os valores únicos (`DISTINCT`) de ambas as tabelas fato simultaneamente, garantindo uma lista limpa:
```sql
INSERT INTO dLeague (league_name)
SELECT DISTINCT league FROM currency
UNION
SELECT DISTINCT league FROM items;
```

### 3. Tabela Calendário Contínua (dCalendar)
Criada no PostgreSQL para garantir a inteligência de tempo contínua no Power BI. Utilizei a função `generate_series()` aliada a subqueries de `MIN` e `MAX` extraindo dados de ambas as tabelas fato:
```sql
CREATE TABLE dCalendar AS
SELECT
    all_dates::DATE AS date
FROM generate_series(
    (SELECT MIN(date) FROM (SELECT date FROM items UNION ALL SELECT date FROM currency) AS all_dates_min),
    (SELECT MAX(date) FROM (SELECT date FROM items UNION ALL SELECT date FROM currency) AS all_dates_max),
    '1 day'::interval
) AS all_dates;
```
**Por que criei a tabela assim?** O código é 100% dinâmico. A inserção de dados de novas ligas futuras ajustará automaticamente o calendário sem necessidade de refatorar o código SQL. O `::Date` foi usado para limpar timestamps e evitar bugs de relacionamento no PowerBI.

### 4. Otimização de Performance (Surrogate Keys)
Inicialmente, as tabelas fato se relacionavam usando nomes em texto (ex: "Affliction"). Como as tabelas possuem milhões de linhas, isso gerava alto custo computacional. Alterei o banco de dados (DDL e DML) adicionando colunas `league_id` (INT) nas tabelas Fato, e populei elas através de um `UPDATE / JOIN` com a tabela `dleague`.
```sql
ALTER TABLE public.items ADD COLUMN league_id INT;
ALTER TABLE public.currency ADD COLUMN league_id INT;

UPDATE public.items as i
SET league_id = d.id_league
FROM public.dleague as d
WHERE i.league = d.league_name;

UPDATE public.currency as c
SET league_id = d.id_league
FROM public.dleague as d
WHERE c.league = d.league_name;
```
**Resultado:** A substituição de chaves em Texto por chaves Numéricas reduz o consumo de memória RAM e acelera o processamento dos filtros e visuais.

### 5. Unificação de Filtros e UX (Resolvendo Dimensão Não Conformada)
**O Problema:** Como as tabelas estão separando itens convencionais (`fItems`) e moedas (`fCurrency`), criar uma barra de pesquisa global e um menu único de categorias não funcionaria nativamente no Power BI sem gerar conflitos de hierarquia. Para isso criei uma dimensão consolidada `dProduct` no PostgreSQL para servir de ponte única.
```sql
CREATE TABLE dproduct (
    product_id SERIAL PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    product_type VARCHAR(100) NOT NULL
);
```
**Desafio de Qualidade de Dados:** Durante a união (`UNION`) dos dados brutos, o banco acusou uma violação de `NOT NULL`. Identifiquei que o arquivo `.csv` original continha registros "sujos" (itens com o tipo definido, mas sem nome).
**Ação:** Ajustei a query de extração para filtrar o "lixo" diretamente na fonte, garantindo a integridade do modelo:
```sql
INSERT INTO dproduct (product_name, product_type)
SELECT DISTINCT name, type FROM items WHERE name IS NOT NULL
UNION
SELECT DISTINCT get_currency, 'Currency' FROM currency WHERE get_currency IS NOT NULL;
```

### 6. Aplicando Regras de Negócio (UI/UX no Banco de Dados)
**O Problema:** O jogo possui mais de 30 classificações nativas de itens (`product_type`). Para o usuário final, isso polui a tela. O objetivo era replicar a navegação intuitiva do site poe.ninja, que agrupa esses itens em 4 grandes blocos.
**A Solução:** Adicionei uma coluna `ui_group` na tabela `dProduct` e construí a regra de agrupamento usando `CASE WHEN`. Mapear isso no Data Warehouse (e não no Power BI) centraliza a regra de negócio e deixa o front-end mais leve:
```sql
ALTER TABLE dproduct ADD COLUMN ui_group VARCHAR(100);

UPDATE dproduct
SET ui_group = CASE
    WHEN product_type IN ('Currency', 'KalguuranRune', 'Runegraft', 'AllflameEmber', 'Tattoo', 'Omen', 'DivinationCard', 'Artifact', 'Oil', 'Incubator') THEN 'General'
    WHEN product_type IN ('UniqueWeapon', 'UniqueArmour', 'UniqueAccessory', 'UniqueFlask', 'UniqueJewel', 'UniqueTincture', 'UniqueRelic', 'UniqueIdol', 'SkillGem', 'ClusterJewel') THEN 'Equipment & Gems'
    WHEN product_type IN ('Map', 'BlightedMap', 'BlightRavagedMap', 'UniqueMap', 'DeliriumOrb', 'Invitation', 'Scarab', 'Memory', 'IncursionTemple') THEN 'Atlas'
    WHEN product_type IN ('BaseType', 'Fossil', 'Resonator', 'Beast', 'Essence', 'Vial', 'HelmetEnchant') THEN 'Crafting'
    ELSE 'Other'
END;
```
Por fim, repliquei a técnica de Surrogate Keys do passo 4, criando a coluna `product_id` (INT) nas tabelas fato para otimização de performance.

### 7. Cálculos Unificados em Múltiplas Tabelas Fato (DAX)
**O Problema:** A tabela central precisava exibir o preço atualizado ("Preço Atual") de qualquer item. Como os itens e as moedas estão separados em duas tabelas fato (`fItems` e `fCurrency`), uma medida simples não funcionaria.
**A Solução:** Criei uma medida inteligente usando a função `COALESCE`, que tenta buscar a última data e o último valor na tabela de itens; se retornar vazio, ela busca na tabela de moedas.
```dax
Current Price (Chaos) = 
VAR LastItemDate = MAX('fItems'[date])
VAR ItemPrice = CALCULATE(
    AVERAGE('fItems'[value]),
    'fItems'[date] = LastItemDate
)

VAR LastCurrencyDate = MAX('fCurrency'[date])
VAR CurrencyPrice = CALCULATE(
    AVERAGE('fCurrency'[value]),
    'fCurrency'[date] = LastCurrencyDate
)

RETURN
COALESCE(ItemPrice, CurrencyPrice)
```

### 8. Inteligência de Tempo e Tendências (Sparklines de 7 Dias)
**O Problema:** O recurso nativo de Minigráfico (Sparkline) do Power BI desenha uma linha usando todo o histórico de dados disponível. O objetivo da UI era replicar a visão de "Últimos 7 Dias" a partir da última data registrada de cada item.
**A Solução:** Desenvolvi uma medida DAX com lógica de janela de tempo. O código cria uma âncora no último dia do item, testa se a data do eixo X atual está dentro da janela de 7 dias e retorna `BLANK()` para datas mais antigas. Isso "corta" o gráfico nativo do Power BI, forçando-o a exibir apenas a tendência recente.
```dax
Historical Price (7 days) = 
VAR LastItemDate = CALCULATE(MAX('fItems'[date]), REMOVEFILTERS('dCalendar'))
VAR LastCurrDate = CALCULATE(MAX('fCurrency'[date]), REMOVEFILTERS('dCalendar'))

VAR CurrentSparklineDate = MAX('dCalendar'[date])

VAR IsValidItemDate = CurrentSparklineDate >= (LastItemDate - 6) && CurrentSparklineDate <= LastItemDate
VAR IsValidCurrDate = CurrentSparklineDate >= (LastCurrDate - 6) && CurrentSparklineDate <= LastCurrDate

VAR ItemVal = 
    IF(IsValidItemDate, 
        CALCULATE(AVERAGE('fItems'[value]), ALL('fItems'[confidence])), // ALL quebra o bloqueio visual
        BLANK()
    )
VAR CurrVal = 
    IF(IsValidCurrDate, 
        CALCULATE(AVERAGE('fCurrency'[value]), ALL('fCurrency'[confidence])), // ALL quebra o bloqueio visual
        BLANK()
    )

RETURN COALESCE(ItemVal, CurrVal)
```

### 9. Variação Percentual e Truques de UI/UX
**O Desafio Matemático e Visual:** Precisava calcular o crescimento exato da semana e agrupar isso visualmente com o minigráfico. O Power BI não permite mesclar células de cabeçalho.
**A Solução (DAX):** Criei uma medida resgatando o valor atual e comparando com o valor de exatos 7 dias atrás usando `CALCULATE`, unindo itens e moedas com `COALESCE`.
```dax
7 days Change % = 
VAR CurrentVal = [Current Price (Chaos)]

VAR LastItemDate = CALCULATE(MAX('fItems'[date]))
VAR OldItemVal = 
    CALCULATE(
        AVERAGE('fItems'[value]), 
        'fItems'[date] = LastItemDate - 6,
        REMOVEFILTERS('fItems'[confidence])
    )

VAR LastCurrDate = CALCULATE(MAX('fCurrency'[date]))
VAR OldCurrVal = 
    CALCULATE(
        AVERAGE('fCurrency'[value]), 
        'fCurrency'[date] = LastCurrDate - 6,
        REMOVEFILTERS('fCurrency'[confidence])
    )

VAR OldVal = COALESCE(OldItemVal, OldCurrVal)

RETURN
DIVIDE(CurrentVal - OldVal, OldVal)
```
**A Solução (UI/UX):** Para a interface gráfica, apliquei o truque do "Cabeçalho Fantasma": renomeei a coluna de porcentagem para "Last 7 days" e a coluna do minigráfico com um caractere de espaço (vazio). Alinhei os valores nas extremidades opostas e aproximei as colunas, enganando a visão do usuário para parecer uma única seção agrupada. Por fim, usei formatação condicional Custom (`+#,0%;-#,0%;0%`) para adicionar o sinal de "+" e as cores verde/vermelho.

### 10. Padronização de Nomenclaturas na Fonte (Data Cleaning)
**O Problema:** Os tipos nativos do jogo estão em formato CamelCase (ex: `UniqueAccessory`, `SkillGem`), o que torna a leitura no menu lateral muito técnica e pouco amigável.
**A Solução:** Mantendo a regra de "transformar o dado o mais próximo da fonte possível", adicionei uma coluna `display_type` na tabela dimensão (`dProduct`) no PostgreSQL. Utilizei uma declaração `CASE WHEN` para mapear e traduzir os termos originais para plurais formatados e com espaços, mantendo o front-end leve.
```sql
UPDATE dproduct
SET display_type = CASE
    WHEN product_type = 'Currency' THEN 'Currency'
    WHEN product_type = 'KalguuranRune' THEN 'Kalguuran Runes'
    WHEN product_type = 'Essence' THEN 'Essences'
    WHEN product_type = 'Vial' THEN 'Vials'
    WHEN product_type = 'HelmetEnchant' THEN 'Helmet Enchants'
    ELSE product_type
END;
```

### 11. Âncora Global de Moeda (Contexto de Filtro)
**O Problema:** Para criar um filtro dinâmico de conversão de moedas (Chaos para Divines), o dashboard precisava saber a cotação exata da "Divine Orb" a cada dia. No entanto, ao calcular isso na tabela central, o contexto de linha quebrava a medida quando ela passava por itens normais (como equipamentos), pois eles não existem na tabela de moedas.
**A Solução:** Criei uma medida âncora utilizando `REMOVEFILTERS`. Isso força o Power BI a ignorar a linha específica que a tabela está lendo e buscar o valor absoluto da Divine Orb na data mais recente disponível, servindo como uma variável global para o dashboard inteiro.
```dax
Divine Price in Chaos = 
VAR CurrentDate = CALCULATE(MAX('fCurrency'[date]), REMOVEFILTERS('dproduct'))

RETURN
CALCULATE(
    AVERAGE('fCurrency'[value]),
    'dproduct'[product_name] = "Divine Orb",
    'fCurrency'[date] = CurrentDate,
    REMOVEFILTERS('dproduct')
)
```

### 12. Parâmetros de UI (Tabela Desconectada)
**O Problema:** Precisava criar botões na tela para o usuário escolher o tipo de exibição ("Adaptive", "Chaos", "Divine"). Como essas palavras representam regras lógicas e não dados reais do banco, não era possível criar um filtro nativo.
**A Solução:** Criei uma Tabela Desconectada (Parameter Table) chamada `ValueDisplay` utilizando a função "Enter Data" do Power BI. Ela contém apenas uma coluna com as opções de texto e não possui relacionamento com o modelo, servindo exclusivamente para capturar o clique do usuário via DAX.

### 13. Lógica Dinâmica de Preço e Formatação de Texto
**O Problema:** A exibição do preço precisava obedecer regras complexas da economia do jogo: converter valores dinamicamente, formatar Chaos inteiros e Divines com decimais, inverter a lógica para moedas baratas e tratar a própria "Divine Orb" como exceção.
**A Solução:** Desenvolvi uma medida DAX robusta combinando `SELECTEDVALUE`, matemática de fração e a função `FORMAT`. O `SWITCH` atua como roteador final.
```dax
Dynamic Price (Display) = 
VAR SelectedDisplay = SELECTEDVALUE('_UI_ValueDisplay'[Display Option], "Adaptive")

VAR CurrentItem = MAX('dproduct'[product_name])

VAR PriceInChaos = [Current Price (Chaos)]
VAR DivineAnchor = [Divine Price in Chaos]

VAR PriceInDivines = DIVIDE(PriceInChaos, DivineAnchor) 
VAR AmountPerDivine = DIVIDE(DivineAnchor, PriceInChaos)

VAR IsWholeDivine = ROUND(PriceInDivines, 1) = INT(ROUND(PriceInDivines, 1))
VAR DivineFormat = IF(IsWholeDivine, "#,##0", "#,##0.0")

VAR InvertedPrice = DIVIDE(1, PriceInChaos)
VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR TextChaos = 
    IF(PriceInChaos < 1 && PriceInChaos > 0,
        "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
        FORMAT(PriceInChaos, "#,##0") & " c"
    )

VAR TextDivine = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor,
            FORMAT(PriceInDivines, DivineFormat) & " div",
            "1 div = " & FORMAT(AmountPerDivine, "#,##0")
        )
    )

VAR TextAdaptive = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor, 
            FORMAT(PriceInDivines, DivineFormat) & " div", 
            IF(PriceInChaos < 1 && PriceInChaos > 0,
                "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
                FORMAT(PriceInChaos, "#,##0") & " c"
            )
        )
    )

VAR FinalDisplay = SelectedDisplay

RETURN
SWITCH(
    FinalDisplay,
    "Chaos", TextChaos,
    "Divine", TextDivine,
    "Adaptive", TextAdaptive,
    TextAdaptive
)
```

### 14. Truques de UI/UX: Ordenação Invisível e Proteção de Tabela
**A Solução (Ordenação Oculta):** Adicionei a medida puramente matemática (`Current Price (Chaos)`) na tabela, ordenei de forma decrescente por ela e, em seguida, reduzi a largura da coluna até ela sumir da tela. Mudei as cores da fonte e fundo dessa coluna esmagada para igualar ao fundo geral.
**A Solução (Escudo de Tela):** Para evitar que os usuários quebrem a ordenação clicando nos cabeçalhos das outras colunas, inseri um visual de Retângulo transparente do Power BI sobre o cabeçalho da tabela, bloqueando os cliques nos títulos sem prejudicar a leitura.

### 15. Formatação Avançada de Decimais e Frações Inversas (UI/UX)
**O Problema:** A formatação padrão deixava um ponto decimal "órfão" em números inteiros (ex: "8. div"). Além disso, para itens muito baratos, mostrar o preço direto não faz sentido. Era necessário inverter a matemática para mostrar "X unidades por 1 Chaos/Divine".
**A Solução:** Criei verificações matemáticas usando `INT(ROUND())`.
**15.1 - Medida Dinâmica:**
```dax
Dynamic Price (Display) = 
VAR SelectedDisplay = SELECTEDVALUE('_UI_ValueDisplay'[Display Option], "Adaptive")

VAR CurrentItem = MAX('dproduct'[product_name])

VAR PriceInChaos = [Current Price (Chaos)]
VAR DivineAnchor = [Divine Price in Chaos]

VAR PriceInDivines = DIVIDE(PriceInChaos, DivineAnchor) 
VAR AmountPerDivine = DIVIDE(DivineAnchor, PriceInChaos)

VAR IsWholeDivine = ROUND(PriceInDivines, 1) = INT(ROUND(PriceInDivines, 1))
VAR DivineFormat = IF(IsWholeDivine, "#,##0", "#,##0.0")

VAR InvertedPrice = DIVIDE(1, PriceInChaos)
VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR TextChaos = 
    IF(PriceInChaos < 1 && PriceInChaos > 0,
        "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
        FORMAT(PriceInChaos, "#,##0") & " c"
    )

VAR TextDivine = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor,
            FORMAT(PriceInDivines, DivineFormat) & " div",
            "1 div = " & FORMAT(AmountPerDivine, "#,##0")
        )
    )

VAR TextAdaptive = 
    IF(CurrentItem = "Divine Orb", 
        TextChaos, 
        IF(PriceInChaos >= DivineAnchor, 
            FORMAT(PriceInDivines, DivineFormat) & " div", 
            IF(PriceInChaos < 1 && PriceInChaos > 0,
                "1 c = " & FORMAT(InvertedPrice, InvertedFormat),
                FORMAT(PriceInChaos, "#,##0") & " c"
            )
        )
    )

VAR FinalDisplay = SelectedDisplay

RETURN
SWITCH(
    FinalDisplay,
    "Chaos", TextChaos,
    "Divine", TextDivine,
    "Adaptive", TextAdaptive,
    TextAdaptive
)
```
**15.2 - Cartões de Detalhes:**
```dax
Detail Card (Divine Price) = 
VAR PriceChaos = [Current Price (Chaos)]
VAR DivineAnchor = [Divine Price in Chaos]

VAR PriceDivine = DIVIDE(PriceChaos, DivineAnchor)
VAR AmountPerDivine = DIVIDE(DivineAnchor, PriceChaos)

VAR CurrentItem = MAX('dproduct'[product_name])

VAR IsWholeDivine = ROUND(PriceDivine, 1) = INT(ROUND(PriceDivine, 1))
VAR DivineFormat = IF(IsWholeDivine, "#,##0", "#,##0.0")

VAR IsWholeAmount = ROUND(AmountPerDivine, 1) = INT(ROUND(AmountPerDivine, 1))
VAR AmountFormat = IF(IsWholeAmount, "#,##0", "#,##0.0")

RETURN
IF(
    CurrentItem = "Divine Orb",
    "1 Divine",
    IF(
        PriceChaos >= DivineAnchor,
        FORMAT(PriceDivine, DivineFormat) & " Divines",
        "1 Divine = " & FORMAT(AmountPerDivine, AmountFormat) & " units"
    )
)
```

### 16. Página de Detalhes (Drill-through)
Criei uma página secundária configurada como destino de Drill-through, utilizando a coluna `product_name` como âncora e a opção "Keep all filters" ativa, adicionando cartões dinâmicos usando `MAX(product_name)` para atualizar a interface conforme o item clicado.

### 17. Normalização Temporal e Eixo X Dinâmico (PostgreSQL)
**O Problema:** As ligas do Path of Exile começam em datas diferentes. Um gráfico de linha convencional criaria buracos temporais e impediria a sobreposição visual para comparação.
**A Solução:**
17.1 Usei uma CTE para descobrir a data absoluta de início de cada liga e gravei em `dleague`.
17.2 Nas tabelas fato, calculei a diferença de dias (Data do Item - Data de Início da Liga) + 1 gerando a coluna `league_day`.
17.3 Criei uma dimensão de tempo normalizada (`dleagueday`) garantindo que a régua se ajuste automaticamente.
```sql
-- CTE para data de início
WITH FirstDates AS (
    SELECT league_id, MIN(date) AS first_date
    FROM (
        SELECT league_id, date FROM items UNION ALL SELECT league_id, date FROM currency
    ) AS all_dates GROUP BY league_id
)
UPDATE dleague SET start_date = FirstDates.first_date FROM FirstDates WHERE dleague.id_league = FirstDates.league_id;

-- Criação da Dimensão de Dias
CREATE TABLE dleagueday AS
SELECT generate_series(
    1,
    (SELECT MAX(league_day) FROM (SELECT league_day FROM items UNION ALL SELECT league_day FROM currency) AS all_days)
) AS day_index;

ALTER TABLE dleagueday ADD PRIMARY KEY (day_index);
```

### 18. Quebrando o Bloqueio do Drill-through (Comparador de Ligas)
**O Problema:** Como o Drill-through trava a página inteira em uma única liga, um visual nativo não consegue adicionar uma segunda liga ao gráfico.
**A Solução:** Criei uma tabela falsa chamada `CompareLeague` usando `UNION` e `DISTINCT`. Como ela não possui relacionamento, não é afetada pelos filtros da página. Usei `REMOVEFILTERS` para buscar o preço exclusivamente dessa nova tabela.
```dax
CompareLeague =
UNION(
    ROW("league_name", " None"),
    DISTINCT('dleague'[league_name])
)
```
```dax
Compare Price (Chaos) = 
VAR SelectedCompareLeague = SELECTEDVALUE('_UI_CompareLeague'[league_name])

VAR Result = 
CALCULATE(
    [Current Price (Chaos)],
    REMOVEFILTERS('dleague'),
    'dleague'[league_name] = SelectedCompareLeague
)

RETURN
IF(SelectedCompareLeague = " None" || ISBLANK(SelectedCompareLeague), BLANK(), Result)
```

### 19. UX Sênior: Filtros Inteligentes (Leão de Chácara)
**O Problema:** O Dropdown de comparação mostrava ligas onde o item filtrado sequer existia, gerando "Caminhos Sem Saída".
**A Solução:** Criei uma "Medida de Suporte" invisível. Ela atua como regra booleana que avalia se a liga é igual à atual, e usa `COUNTROWS` para verificar se existem registros. Apliquei isso nos filtros visuais para ocultar opções inválidas.
```dax
Filter (Valid Compare League) = 
VAR SlicerLeague = MAX('_UI_CompareLeague'[league_name])
// Captura a liga original que o usuário trouxe pelo Drill-through
VAR OriginalLeague = SELECTEDVALUE('dleague'[league_name])

VAR CheckItems = 
    CALCULATE(
        COUNTROWS('fItems'),
        REMOVEFILTERS('dleague'),
        'dleague'[league_name] = SlicerLeague
    )
    
VAR CheckCurrency = 
    CALCULATE(
        COUNTROWS('fCurrency'),
        REMOVEFILTERS('dleague'),
        'dleague'[league_name] = SlicerLeague
    )

RETURN
IF(
    SlicerLeague = " None", 
    1, 
    IF(
        SlicerLeague = OriginalLeague, // Se for a mesma liga do Drill-through...
        0,                             // ...toma nota 0 e some do Dropdown.
        IF(CheckItems > 0 || CheckCurrency > 0, 1, 0)
    )
)
```

### 20. Análise de Tendência Histórica (All-Time High / Low)
**O Problema:** Exibir o maior e o menor preço que um item já atingiu. Como a medida é calculada dinamicamente, funções básicas como `MAX()` não funcionam.
**A Solução:** Utilizei funções iteradoras (`MAXX` e `MINX`) com camadas de segurança (`FILTER`).
```dax
Highest Price (Display) = 
VAR MaxPrice = 
    MAXX(
        VALUES('dleagueday'[day_index]),
        [Current Price (Chaos)]
    )
VAR InvertedPrice = DIVIDE(1, MaxPrice)

VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR IsWholePrice = ROUND(MaxPrice, 1) = INT(ROUND(MaxPrice, 1))
VAR PriceFormat = IF(IsWholePrice, "#,##0", "#,##0.0")

RETURN
IF(ISBLANK(MaxPrice), BLANK(),
    IF(
        MaxPrice < 1 && MaxPrice > 0,
        "1 Chaos = " & FORMAT(InvertedPrice, InvertedFormat) & " units",
        FORMAT(MaxPrice, PriceFormat) & " Chaos"
    )
)
```
```dax
Lowest Price (Display) = 
VAR MinPrice = 
    MINX(
        FILTER(
            VALUES('dleagueday'[day_index]),
            NOT ISBLANK([Current Price (Chaos)])
        ),
        [Current Price (Chaos)]
    )
VAR InvertedPrice = DIVIDE(1, MinPrice)

VAR IsWholeInverted = ROUND(InvertedPrice, 1) = INT(ROUND(InvertedPrice, 1))
VAR InvertedFormat = IF(IsWholeInverted, "#,##0", "#,##0.0")

VAR IsWholePrice = ROUND(MinPrice, 1) = INT(ROUND(MinPrice, 1))
VAR PriceFormat = IF(IsWholePrice, "#,##0", "#,##0.0")

RETURN
IF(ISBLANK(MinPrice), BLANK(),
    IF(
        MinPrice < 1 && MinPrice > 0,
        "1 Chaos = " & FORMAT(InvertedPrice, InvertedFormat) & " units",
        FORMAT(MinPrice, PriceFormat) & " Chaos"
    )
)
```

### 21. A Média Móvel de 3 Dias (Trading View)
**O Problema:** Os preços no jogo sofrem com "ruídos" de fim de semana.
**A Solução:** Criei uma janela dinâmica de 3 dias usando `FILTER` e `ALL`. Em seguida, o `AVERAGEX` calcula a média de preços.
```dax
Moving Average 3 days (Chaos) = 
VAR CurrentDay = MAX('dleagueday'[day_index])

VAR Window3Days = 
    FILTER(
        ALL('dleagueday'),
        'dleagueday'[day_index] <= CurrentDay &&
        'dleagueday'[day_index] >= CurrentDay - 2
    )

RETURN
AVERAGEX(
    Window3Days,
    [Current Price (Chaos)]
)
```
```dax
Dynamic Moving Average = 
VAR UserChoice = SELECTEDVALUE('_UI_ToggleTrend'[Option], "Hide Trend")

RETURN
IF(
    UserChoice = "Show Trend",
    [Moving Average 3 days (Chaos)],
    BLANK()
)
```

### 22. QA de Dados e o Motor VertiPaq (A Otimização que não aconteceu)
**O Problema/Reflexão:** Com o objetivo de otimizar RAM, planejei alterar o Tipo de Dados para Fixed Decimal Number. Ao fazer auditoria (QA), identifiquei valores de notação científica (`1E-05`) das micro-frações. Mantive o Decimal Number, priorizando a integridade matemática da economia acima da otimização de memória.

### 23. Limpeza de Links Mortos (UI/UX Dinâmico na Tabela)
**O Problema:** Criar um botão para a Wiki do jogo, mas muitas categorias ou itens deletados geravam Erro 404.
**A Solução:** Criei uma coluna condicional inteligente na tabela `dProduct` usando `SUBSTITUTE` e `CONTAINSSTRING` para listar categorias sem Wiki, desativando o link no front-end caso necessário.
```dax
Wiki_Link =
VAR ItemName = 'dProduct'[product_name]
VAR IsExcludedCategory = 'dProduct'[display_type] IN {"Cluster Jewels", "Memories", "Temples", "Beasts", "Helmet Enchants"}
VAR IsLegacyGem = CONTAINSSTRING(ItemName, "Anomalous ") || CONTAINSSTRING(ItemName, "Divergent ") || CONTAINSSTRING(ItemName, "Phantasmal ")
RETURN IF(
    IsExcludedCategory || IsLegacyGem,
    BLANK(),
    "[https://www.poewiki.net/wiki/](https://www.poewiki.net/wiki/)" & SUBSTITUTE(ItemName, " ", "_")
)
```

### 24. Tooltips Customizadas e o Problema da Cachoeira (Context Direction)
**O Problema:** A Data ficava "congelada" no último dia da liga dentro da Tooltip.
**A Solução:** O mouse no eixo X filtrava as Tabelas Fato, mas o filtro não subia ("upstream") para a tabela Calendário. Pedi diretamente as datas de dentro das tabelas fato unidas por um `COALESCE` para descongelar.
```dax
Tooltip Date = 
VAR ItemDate = MAX('fItems'[date])
VAR CurrencyDate = MAX('fCurrency'[date])

VAR CurrentDate = COALESCE(ItemDate, CurrencyDate)

RETURN
IF(
    ISBLANK(CurrentDate), 
    BLANK(), 
    FORMAT(CurrentDate, "ddd MMM dd yyyy")
)
```

### 25. Controle de Interações (Blindando Cartões)
Utilizei "Edit Interactions" definindo o gráfico de linhas como "None" em relação aos cartões de histórico, mantendo a integridade da análise macro.

### 26. Otimização de Tabela com Top N (Carregamento Instantâneo)
Carregar milhares de itens consumia muito processamento. Apliquei o filtro de "Top 100". Como o Power BI processa os Slicers de pesquisa antes, a pesquisa global continua funcionando perfeitamente (o item passa no filtro Top N por ser menor que 100 resultados), mantendo a tabela ultra-leve.

### 27. Slicers Inteligentes e Menus Dinâmicos (Prevenção de Cliques Vazios)
**O Problema:** Ligas com bases parciais ainda exibiam categorias vazias no menu.
**A Solução:** Adicionei a medida `Current Price (Chaos)` no painel de "Filtros neste visual" do próprio Slicer com a regra "não está em branco" (`is not blank`). Categorias sem valores registrados desaparecem automaticamente.

### 28. Protocolo de QA e Performance Analyzer
Fluxo de testes usando o "Analisador de Desempenho" (Performance Analyzer) aliado ao "Sanity Check" usando itens-âncora para validar se a matemática do DAX batia perfeitamente com o SQL do PostgreSQL.

### 29. Ingestão Segura e Área de Pouso (Staging Area)
**O Problema:** O PostgreSQL acusou erro de missing column ao importar CSV de nova liga, pois a Fato evoluiu, mas o arquivo original não.
**A Solução:** Implementação do padrão de Staging Area. Criei tabelas temporárias, fiz o `COPY` seguro e usei um comando `INSERT INTO ... SELECT` nomeando as colunas, deixando as novas colunas `NULL` prontas para os cálculos.

### 30. Resiliência a Schema Drift (O Caso das Forbidden Jewels)
**O Problema:** A API mudou a forma de catalogar itens compostos na liga nova (separando tipo e passiva), causando colisão de granularidade.
**A Solução:** Usamos SQL para reparar a consistência do modelo mantendo a identidade dos itens, direto na Fato.
```sql
UPDATE items 
SET name = variant || ' (' || name || ')'
WHERE type = 'ForbiddenJewel' AND name NOT LIKE 'Forbidden%';
```

### 31. Higienização de Dados e Desduplicação Avançada
**O Problema:** Presença de registros "clonados" oriundos de falha na API.
**A Solução:** "Aspirador de Pó SQL" avançado utilizando `ROW_NUMBER()` aliado ao endereço físico interno do PostgreSQL (`ctid`) para varrer e deletar exatamente os clones.
```sql
DELETE FROM items WHERE ctid IN (
    SELECT ctid FROM (
        SELECT ctid, ROW_NUMBER() OVER (
            PARTITION BY league, date, id, type, name, basetype, variant, links, value, confidence ORDER BY ctid
        ) as row_num FROM items WHERE league = 'Keepers'
    ) clones WHERE clones.row_num > 1
);
```

### 32. O Bug das Surrogate Keys e Relacionamentos Órfãos
**O Problema:** Após a ingestão da nova liga, os gráficos pararam de funcionar pois o script não "carimbou" a ForeignKey (`product_id`) nas novas linhas da tabela Fato, quebrando o relacionamento.
**A Solução:** Refatoração do script de carga incremental via `UPDATE...FROM`.
```sql
UPDATE items i
SET product_id = p.product_id
FROM dproduct p
WHERE i.name = p.product_name AND i.product_id IS NULL;
```
