# Page 1 guide: "Executive Overview" (Power BI service, in the browser)

Click-by-click steps for building one report page at
[app.powerbi.com](https://app.powerbi.com), written for a first-time Power BI
user. When you're done, check every number against
[`EXPECTED_VALUES.md`](EXPECTED_VALUES.md).

What the finished page looks like:

```
+------------------------------------------------------------------+
|  [ Year slicer ]          [ Daypart slicer ]                     |
|                                                                  |
|  [Total Sales]  [Orders]  [Avg Order Value]  [Sales YoY %]       |
|                                                                  |
|  [ Monthly Sales vs Sales LY — line chart, full width          ] |
|                                                                  |
|  [ Avg Daily Sales by day of week ]  [ Sales by menu category ]  |
+------------------------------------------------------------------+
```

## Step 0: Before you start

You need the semantic model from [`BUILD_GUIDE.md`](BUILD_GUIDE.md),
steps 1–5: all 7 tables uploaded, `dim_date` marked as the date table (with
`month_name` and `day_of_week` sorted), the 6 relationships, and the 13
measures from [`measures.dax`](measures.dax).

> **If you created the measures before this guide existed:** `Total Sales`
> now sums `fact_order_line`, `Avg Check` changed, and `Avg Daily Sales` is
> new. Re-paste those three from `measures.dax`. Without the new
> `Total Sales`, the Daypart slicer won't change the cards (see
> Troubleshooting).

While you're still in the **semantic model** (Editing mode), set these
properties. Select each item in the **Data pane**, then change it in the
**Properties pane**:

| Item | Property | Set to |
|---|---|---|
| `[Total Sales]`, `[Sales LY]`, `[Avg Order Value]`, `[Avg Daily Sales]` | Format | Currency, 2 decimal places |
| `[Orders]` | Format | Whole number, thousands separator on |
| `[Sales YoY %]` | Format | Percentage, 1 decimal place |
| `dim_date[year]` | Summarize by | None |
| `dim_daypart[daypart]` | Sort by column | `sort_order` |

Why: `year` is a number, so without "Summarize by: None" Power BI would try to
add the years together. Sorting `daypart` by `sort_order` makes the slicer
read Lunch → Afternoon → Dinner → Late instead of alphabetically.

## Step 1: Open a new report and name the page

1. In the semantic model editor's ribbon, select **New report**. A blank
   report opens in a new browser tab.
2. At the bottom of the canvas, double-click the tab named **Page 1**, type
   `Executive Overview`, and press Enter.
3. Get to know the three panes on the right:
   - **Filters**: ignore for now.
   - **Visualizations**: the grid of chart icons. Clicking an icon adds
     that visual. Below the icons are the **field wells** (X-axis, Y-axis,
     Values...) for the selected visual, and a paintbrush icon
     (**Format visual**) for styling it.
   - **Data**: your tables. Click the arrow next to a table to see its
     columns and measures (measures have a calculator icon).

**Tip:** before adding each new visual, click an empty spot on the canvas
first. If a visual is still selected when you click a chart icon, Power BI
*changes that visual's type* instead of adding a new one.

## Step 2: The two slicers

**Year slicer**
1. Click an empty spot on the canvas, then click the **Slicer** icon in
   Visualizations (a funnel over a small list).
2. In the Data pane, expand `dim_date` and tick `year`.
3. If it shows as a sliding range bar instead of a list of years: select the
   slicer → **Format visual** (paintbrush) → **Visual** → **Slicer
   settings** → **Options** → **Style** → choose **Tile** (or Vertical list).
4. Drag it to the top-left and resize it by dragging its corners.

**Daypart slicer**
1. Click an empty spot, add another **Slicer**.
2. Expand `dim_daypart`, tick `daypart`.
3. Style it as **Tile** the same way and place it next to the Year slicer.

To select more than one value in a slicer, hold **Cmd** while clicking.

## Step 3: The four KPI cards

Repeat for each measure: `[Total Sales]`, `[Orders]`, `[Avg Order Value]`,
`[Sales YoY %]`.

1. Click an empty spot, then click the **Card** visual icon (a box with
   "123"). Depending on your Power BI version you may see both **Card** and
   **Card (new)**, or **Card** and **Card (legacy)**. Either works; these
   steps use one measure per card.
2. In the Data pane, tick the measure. `Total Sales` is under
   `fact_order_line`; the others are in the table you created them on.
3. Drag the card into the row under the slicers and resize it.

Power BI shortens big numbers on cards (`$6.65M`). To see the exact value
for checking: select the card → **Format visual** → **Callout value** (or
**Values**) → **Display units** → **None**. You can switch it back later.

## Step 4: Line chart, monthly Sales vs Sales LY

1. Click an empty spot, then click the **Line chart** icon.
2. Drag `dim_date[year_month]` into **X-axis**.
3. Drag `[Total Sales]` into **Y-axis**, then drag `[Sales LY]` into
   **Y-axis** as well (both measures in the same well = two lines).
4. Make sure the months run in date order: hover over the chart → click the
   **...** (More options) in its top-right corner → **Sort axis** →
   **year_month**, then **...** → **Sort axis** → **Sort ascending**.
5. Stretch it across the full width of the page.

The `Sales LY` line only starts in Dec 2024, because the data begins on
23 Dec 2023 and there's no "last year" before that.

## Step 5: Column chart, Avg Daily Sales by day of week

1. Click an empty spot, then click **Clustered column chart** (vertical bars).
2. Drag `dim_date[day_of_week]` into **X-axis**.
3. Drag `[Avg Daily Sales]` into **Y-axis**.
4. Power BI sorts bars tallest-first by default. To get Sunday → Saturday:
   **...** → **Sort axis** → **day_of_week**, then **...** → **Sort axis**
   → **Sort ascending**. This works because `day_of_week` is sorted by
   `day_of_week_num` (done in BUILD_GUIDE step 3).
5. Place it bottom-left.

This uses `[Avg Daily Sales]`, not a plain sum, so each bar shows a *typical*
Monday, Tuesday, etc. A sum would also depend on how many of each weekday
fall in the period.

## Step 6: Bar chart, sales by menu category

1. Click an empty spot, then click **Clustered bar chart** (horizontal bars,
   which suit text labels).
2. Drag `dim_menu_item[category]` into **Y-axis**.
3. Drag `[Total Sales]` into **X-axis**.
4. The default sort (largest first) is what you want: Mains at the top.
5. Place it bottom-right.

## Step 7: Check your numbers

1. With **nothing** selected in either slicer, compare all four cards, a few
   line-chart points (hover over a point to see its values), every weekday
   bar, and every category bar with the "Unfiltered" section of
   [`EXPECTED_VALUES.md`](EXPECTED_VALUES.md).
2. Select **2025** in the Year slicer and **Dinner** in the Daypart slicer.
   Every visual should change. Compare with the "Year = 2025, Daypart =
   Dinner" section.
3. Clear the slicers when you're done: hover over a slicer → eraser icon.

The unfiltered **Sales YoY %** (+64.15%) looks dramatic but isn't meaningful.
It compares 2.6 years of data against a "last year" that only has about 1.6
years in it. That card is meant to be read with a year selected.

## Step 8: Save, screenshot, and add it to the README

1. **File** → **Save** → name it `Restaurant Sales Report` → choose your
   workspace → **Save**.
2. Pick a good view to capture: Year = 2025 with no Daypart selected is a
   clean one.
3. Press **Cmd + Shift + 4**, then drag a box around the report canvas. The
   screenshot lands on your Desktop.
4. Rename it `executive-overview.png` and move it into this repo's
   `powerbi/screenshots/` folder.
5. In `README.md`, find the "Executive Overview screenshot" placeholder and
   replace that line with:

   ```
   ![Executive Overview page](powerbi/screenshots/executive-overview.png)
   ```

6. Commit and push the screenshot and the README change.

## Troubleshooting

| What you see | Likely cause | Fix |
|---|---|---|
| Daypart slicer doesn't change the cards | `Total Sales` still sums `fact_daily_sales` | Re-paste `Total Sales` from `measures.dax` (it should sum `fact_order_line[net_sales]`) |
| `Sales LY` / `Sales YoY %` blank everywhere | `dim_date` not marked as the date table, or the `fact_order_line[date_key]` → `dim_date[date_key]` relationship is missing | BUILD_GUIDE steps 3 and 4 |
| Every bar shows the same total | A relationship is missing, so the dimension can't filter the fact | Check all 6 relationships in **Manage relationships** |
| Weekdays or months in alphabetical order | Sort-by-column not set, or the visual sorted by value | BUILD_GUIDE step 3, then the **Sort axis** steps above |
| Year slicer is a range bar | `year` is numeric | Step 2, point 3 (Style → Tile) |
| Numbers differ only in the last digit | Card rounding | Display units → None, then compare again |
