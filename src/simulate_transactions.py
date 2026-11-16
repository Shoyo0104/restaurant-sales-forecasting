"""
Order-level transaction generator, built on top of data/daily_sales.csv.

ALL DATA PRODUCED BY THIS SCRIPT IS SYNTHETIC — see simulate_restaurant_sales.py
for the disclaimer that applies to this whole project.

Why this script exists: daily_sales.csv has one row per day, which is too
coarse a grain for a star schema (a BI warehouse wants to slice sales by menu
item, daypart, channel, etc.). This script "explodes" each day's covers and
sales total into individual orders and order lines, while staying tied to the
numbers already in daily_sales.csv:
  - the number of covers (guests) served on a day must sum to that day's
    `covers` value exactly
  - the dollar total of all order lines on a day must reconcile to that day's
    `sales` value within $1 (checked in sql/04_quality_checks.sql)
  - closed days and POS-outage days get zero orders, so those gaps are still
    visible downstream instead of being silently backfilled
"""

import numpy as np
import pandas as pd

RNG_SEED = 123  # independent from the daily-sales seed, kept fixed for determinism

# ---------------------------------------------------------------------------
# Menu: ~40 casual-dining items, grouped into categories. Each item has a
# fixed list price and a food cost (used for food-cost-% analysis later).
# Food cost is set to roughly 28-35% of price, the typical casual-dining
# target range, with a little variation so it isn't a flat ratio.
# ---------------------------------------------------------------------------
MENU_ITEMS = [
    # (item_name, category, price, food_cost)
    ("Loaded Potato Skins", "Appetizers", 9.50, 2.80),
    ("Mozzarella Sticks", "Appetizers", 8.75, 2.40),
    ("Buffalo Wings", "Appetizers", 11.50, 3.60),
    ("Spinach Artichoke Dip", "Appetizers", 9.95, 2.70),
    ("Nachos Supreme", "Appetizers", 12.50, 3.90),
    ("Calamari", "Appetizers", 13.50, 4.50),
    ("Classic Cheeseburger", "Burgers", 13.95, 4.10),
    ("Bacon BBQ Burger", "Burgers", 15.50, 4.70),
    ("Mushroom Swiss Burger", "Burgers", 14.75, 4.40),
    ("Veggie Burger", "Burgers", 13.25, 3.80),
    ("Double Stack Burger", "Burgers", 17.50, 5.60),
    ("Spicy Jalapeno Burger", "Burgers", 14.95, 4.30),
    ("Grilled Chicken Breast", "Mains", 17.95, 5.20),
    ("Ribeye Steak", "Mains", 26.50, 9.80),
    ("Fish and Chips", "Mains", 16.95, 5.60),
    ("BBQ Baby Back Ribs", "Mains", 22.50, 8.10),
    ("Chicken Parmesan", "Mains", 18.50, 5.90),
    ("Shrimp Scampi", "Mains", 19.95, 6.70),
    ("Vegetable Stir Fry", "Mains", 15.50, 4.20),
    ("Caesar Salad", "Salads", 11.50, 2.90),
    ("Cobb Salad", "Salads", 13.95, 4.10),
    ("Greek Salad", "Salads", 12.50, 3.40),
    ("Grilled Chicken Salad", "Salads", 14.50, 4.30),
    ("House Garden Salad", "Salads", 9.50, 2.20),
    ("Chocolate Lava Cake", "Desserts", 8.50, 2.10),
    ("New York Cheesecake", "Desserts", 7.95, 1.90),
    ("Apple Pie", "Desserts", 7.50, 1.80),
    ("Ice Cream Sundae", "Desserts", 6.95, 1.50),
    ("Key Lime Pie", "Desserts", 7.95, 1.90),
    ("Soft Drink", "Beverages", 3.25, 0.40),
    ("Iced Tea", "Beverages", 3.25, 0.35),
    ("Coffee", "Beverages", 3.50, 0.50),
    ("Craft Beer", "Beverages", 7.50, 2.20),
    ("House Wine (Glass)", "Beverages", 9.50, 2.80),
    ("Lemonade", "Beverages", 3.50, 0.45),
    ("Sparkling Water", "Beverages", 3.95, 0.60),
    ("Kids Chicken Tenders", "Kids", 7.95, 2.30),
    ("Kids Mac and Cheese", "Kids", 6.95, 1.80),
    ("Kids Mini Burger", "Kids", 7.50, 2.10),
    ("Kids Grilled Cheese", "Kids", 6.50, 1.60),
]

DAYPARTS = ["Lunch", "Afternoon", "Dinner", "Late"]
DAYPART_WEIGHTS = [0.30, 0.12, 0.48, 0.10]
# (start_hour, end_hour) used to draw a random timestamp within the daypart
DAYPART_HOURS = {"Lunch": (11, 14), "Afternoon": (14, 17), "Dinner": (17, 21), "Late": (21, 23.5)}

CHANNELS = ["Dine-in", "Takeout"]
# Dine-in share is highest at Dinner, lowest at Lunch/Late (quick in-and-out meals)
CHANNEL_DINE_IN_PROB = {"Lunch": 0.55, "Afternoon": 0.60, "Dinner": 0.80, "Late": 0.50}

PARTY_SIZE_CHOICES = [1, 2, 3, 4, 5, 6]
PARTY_SIZE_WEIGHTS = [0.20, 0.35, 0.20, 0.15, 0.07, 0.03]

# Entree category weights per daypart: what guests tend to order as their
# main item at that time of day. Beverages and Desserts are deliberately
# excluded here and handled as separate attach-rate draws below — if a
# cheap beverage could be drawn in place of an entree, the average per-guest
# spend comes out far below daily_sales.csv's avg_check, which would force
# an oversized reconciliation scale factor in net_sales and make food cost %
# look artificially low.
ENTREE_CATEGORY_WEIGHTS_BY_DAYPART = {
    "Lunch":     {"Appetizers": 0.08, "Burgers": 0.32, "Mains": 0.30, "Salads": 0.25, "Kids": 0.05},
    "Afternoon": {"Appetizers": 0.25, "Burgers": 0.40, "Mains": 0.20, "Salads": 0.15, "Kids": 0.00},
    "Dinner":    {"Appetizers": 0.08, "Burgers": 0.25, "Mains": 0.52, "Salads": 0.12, "Kids": 0.03},
    "Late":      {"Appetizers": 0.20, "Burgers": 0.60, "Mains": 0.20, "Salads": 0.00, "Kids": 0.00},
}

# Most guests order a drink with their meal, independent of what they ate.
BEVERAGE_ATTACH_PROB = 0.95
BEVERAGE_WEIGHTS = {
    "Soft Drink": 0.22, "Iced Tea": 0.18, "Coffee": 0.15, "Lemonade": 0.15,
    "Sparkling Water": 0.10, "Craft Beer": 0.12, "House Wine (Glass)": 0.08,
}

# Shared, table-level add-ons for bigger parties.
APPETIZER_SHARE_PROB = 0.55  # when party_size >= 2
DESSERT_SHARE_PROB = 0.40    # when party_size >= 2


def _build_menu_frame() -> pd.DataFrame:
    menu = pd.DataFrame(MENU_ITEMS, columns=["item_name", "category", "price", "food_cost"])
    menu.insert(0, "item_id", range(1, len(menu) + 1))
    return menu


def _category_item_pool(menu: pd.DataFrame, cat_weights: dict):
    """Precompute the (item_id array, draw-probability array) used to pick a
    menu item for a single per-guest entree line, given a category-weight
    dict. Items within a category split that category's weight evenly."""
    probs = np.zeros(len(menu))
    for i, row in menu.iterrows():
        cat_w = cat_weights.get(row["category"], 0.0)
        n_in_cat = (menu["category"] == row["category"]).sum()
        probs[i] = cat_w / n_in_cat
    probs = probs / probs.sum()
    return menu["item_id"].values, probs


def _beverage_pool(menu: pd.DataFrame):
    """(item_id array, draw-probability array) over just the Beverages
    category, weighted by BEVERAGE_WEIGHTS (soft drinks ordered more often
    than, say, a glass of wine)."""
    bev = menu[menu["category"] == "Beverages"]
    weights = bev["item_name"].map(BEVERAGE_WEIGHTS).values.astype(float)
    weights = weights / weights.sum()
    return bev["item_id"].values, weights


def _draw_party_sizes(rng: np.random.Generator, covers: int) -> list:
    """Split a day's total covers into a list of order party sizes that sums
    to exactly `covers`, so the orders table always reconciles to the day's
    guest count with no slack."""
    sizes = []
    remaining = covers
    while remaining > 0:
        draw = rng.choice(PARTY_SIZE_CHOICES, p=PARTY_SIZE_WEIGHTS)
        size = min(draw, remaining)  # last order absorbs whatever is left over
        sizes.append(size)
        remaining -= size
    return sizes


def _draw_timestamp(rng: np.random.Generator, date: pd.Timestamp, daypart: str) -> pd.Timestamp:
    start_h, end_h = DAYPART_HOURS[daypart]
    minute_of_day = rng.uniform(start_h * 60, end_h * 60)
    return date + pd.Timedelta(minutes=minute_of_day)


def simulate_transactions(daily_sales: pd.DataFrame, seed: int = RNG_SEED):
    rng = np.random.default_rng(seed)
    menu = _build_menu_frame()
    entree_pools = {dp: _category_item_pool(menu, ENTREE_CATEGORY_WEIGHTS_BY_DAYPART[dp]) for dp in DAYPARTS}
    beverage_pool = _beverage_pool(menu)
    item_lookup = menu.set_index("item_id")[["price", "food_cost"]]

    order_rows = []
    line_rows = []
    order_id = 1
    line_id = 1

    sim_days = daily_sales[~daily_sales["is_closed"] & ~daily_sales["is_pos_outage"]]

    for _, day in sim_days.iterrows():
        date = pd.Timestamp(day["date"])
        covers = int(round(day["covers"]))
        day_sales_target = float(day["sales"])
        if covers <= 0:
            continue  # defensive guard; no valid non-special/outage day should hit this

        party_sizes = _draw_party_sizes(rng, covers)
        day_order_ids = []
        day_line_indices = []  # indices into line_rows added for this day, for the scaling pass below

        for party_size in party_sizes:
            daypart = rng.choice(DAYPARTS, p=DAYPART_WEIGHTS)
            dine_in_prob = CHANNEL_DINE_IN_PROB[daypart]
            channel = rng.choice(CHANNELS, p=[dine_in_prob, 1 - dine_in_prob])
            timestamp = _draw_timestamp(rng, date, daypart)

            order_rows.append({
                "order_id": order_id,
                "date": date,
                "timestamp": timestamp,
                "daypart": daypart,
                "channel": channel,
                "party_size": party_size,
            })
            day_order_ids.append(order_id)

            entree_ids, entree_probs = entree_pools[daypart]

            # One entree line per guest.
            chosen_entrees = rng.choice(entree_ids, size=party_size, p=entree_probs)
            for item_id in chosen_entrees:
                price, food_cost = item_lookup.loc[item_id]
                line_rows.append({
                    "order_line_id": line_id, "order_id": order_id, "item_id": int(item_id),
                    "quantity": 1, "unit_price": price, "food_cost_unit": food_cost,
                })
                day_line_indices.append(len(line_rows) - 1)
                line_id += 1

            # Most guests also order a drink — modeled as an independent
            # per-guest attach rate rather than competing with the entree draw.
            n_beverages = rng.binomial(party_size, BEVERAGE_ATTACH_PROB)
            if n_beverages > 0:
                bev_ids, bev_probs = beverage_pool
                chosen_bevs = rng.choice(bev_ids, size=n_beverages, p=bev_probs)
                for item_id in chosen_bevs:
                    qty = 2 if rng.random() < 0.10 else 1  # occasional refill / second round
                    price, food_cost = item_lookup.loc[item_id]
                    line_rows.append({
                        "order_line_id": line_id, "order_id": order_id, "item_id": int(item_id),
                        "quantity": qty, "unit_price": price, "food_cost_unit": food_cost,
                    })
                    day_line_indices.append(len(line_rows) - 1)
                    line_id += 1

            # Larger parties often add a shared appetizer or dessert on top of
            # individual mains — without this, big tables would under-order.
            if party_size >= 2 and rng.random() < APPETIZER_SHARE_PROB:
                app_ids = menu.loc[menu["category"] == "Appetizers", "item_id"].values
                item_id = rng.choice(app_ids)
                price, food_cost = item_lookup.loc[item_id]
                line_rows.append({
                    "order_line_id": line_id, "order_id": order_id, "item_id": int(item_id),
                    "quantity": 1, "unit_price": price, "food_cost_unit": food_cost,
                })
                day_line_indices.append(len(line_rows) - 1)
                line_id += 1
            if party_size >= 2 and rng.random() < DESSERT_SHARE_PROB:
                dessert_ids = menu.loc[menu["category"] == "Desserts", "item_id"].values
                item_id = rng.choice(dessert_ids)
                price, food_cost = item_lookup.loc[item_id]
                line_rows.append({
                    "order_line_id": line_id, "order_id": order_id, "item_id": int(item_id),
                    "quantity": 1, "unit_price": price, "food_cost_unit": food_cost,
                })
                day_line_indices.append(len(line_rows) - 1)
                line_id += 1

            order_id += 1

        # --- Reconcile this day's line totals to daily_sales.csv's `sales` ---
        # Menu prices are fixed list prices (what dim_menu_item will show), but
        # the day's actual recorded sales total rarely matches "sum(price*qty)"
        # exactly in a real POS either — comps, modifiers, and discounts move
        # the realized total. We model that by scaling each line's raw amount
        # by a single per-day factor so the day ties out to daily_sales.csv,
        # while `food_cost` (a real cost, not a discounted price) is left
        # unscaled. This is exactly what 04_quality_checks.sql verifies.
        raw_amounts = np.array([line_rows[i]["quantity"] * line_rows[i]["unit_price"] for i in day_line_indices])
        day_raw_total = raw_amounts.sum()
        scale = day_sales_target / day_raw_total if day_raw_total > 0 else 1.0

        net_sales = np.round(raw_amounts * scale, 2)
        rounding_gap = round(day_sales_target - net_sales.sum(), 2)
        net_sales[-1] = round(net_sales[-1] + rounding_gap, 2)  # absorb cent-level rounding drift

        for offset, i in enumerate(day_line_indices):
            line_rows[i]["net_sales"] = float(net_sales[offset])
            line_rows[i]["food_cost"] = round(line_rows[i]["quantity"] * line_rows[i]["food_cost_unit"], 2)

    orders = pd.DataFrame(order_rows)
    order_lines = pd.DataFrame(line_rows).drop(columns=["food_cost_unit"])
    return menu, orders, order_lines


def print_validation(daily_sales: pd.DataFrame, orders: pd.DataFrame, order_lines: pd.DataFrame) -> None:
    print("=== Transaction simulation validation (SIMULATED DATA) ===")
    print(f"Orders generated: {len(orders):,}")
    print(f"Order lines generated: {len(order_lines):,}")

    covers_by_day = orders.groupby("date")["party_size"].sum()
    sim_days = daily_sales[~daily_sales["is_closed"] & ~daily_sales["is_pos_outage"]].copy()
    sim_days["date"] = pd.to_datetime(sim_days["date"])
    covers_check = sim_days.set_index("date")["covers"].round().astype(int) - covers_by_day.reindex(sim_days["date"]).fillna(0).astype(int)
    print(f"Days where generated covers != daily_sales.csv covers: {(covers_check != 0).sum()} (expect 0)")

    sales_by_day = order_lines.merge(orders[["order_id", "date"]], on="order_id").groupby("date")["net_sales"].sum()
    sales_check = (sim_days.set_index("date")["sales"] - sales_by_day.reindex(sim_days["date"]).fillna(0)).abs()
    print(f"Max |generated sales - daily_sales.csv sales| per day: ${sales_check.max():.4f} (must be < $1)")

    closed_outage_days = daily_sales[daily_sales["is_closed"] | daily_sales["is_pos_outage"]]
    orphan_orders = orders[orders["date"].isin(pd.to_datetime(closed_outage_days["date"]))]
    print(f"Orders on closed/outage days: {len(orphan_orders)} (expect 0)")


if __name__ == "__main__":
    daily_sales = pd.read_csv("data/daily_sales.csv")
    menu, orders, order_lines = simulate_transactions(daily_sales)
    print_validation(daily_sales, orders, order_lines)

    menu.to_csv("data/menu_items.csv", index=False)
    orders.to_parquet("data/orders.parquet", index=False)
    order_lines.to_parquet("data/order_lines.parquet", index=False)
    print(f"\nWrote {len(menu)} menu items to data/menu_items.csv")
    print(f"Wrote {len(orders):,} orders to data/orders.parquet")
    print(f"Wrote {len(order_lines):,} order lines to data/order_lines.parquet")
