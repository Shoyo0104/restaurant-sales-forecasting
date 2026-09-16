"""
Simulated daily sales generator for a casual-dining restaurant.

ALL DATA PRODUCED BY THIS SCRIPT IS SYNTHETIC. No real point-of-sale, financial,
or transaction records are used or reproduced anywhere in this project. Effect
sizes (day-of-week lift, seasonality, weather sensitivity, promo lift, labor
cost target) are calibrated to *rough, order-of-magnitude* patterns recalled
from personal experience working in casual dining, not to any real business's
actual figures. Treat every number below as an illustrative assumption for a
portfolio project, not a factual claim about any specific restaurant.
"""

import numpy as np
import pandas as pd

RNG_SEED = 42
N_DAYS = 940
END_DATE = "2026-07-19"  # covers the 2026 FIFA World Cup window for the event-effect demo

# ---------------------------------------------------------------------------
# Calibration anchors (SIMULATED — see README "Calibration approach" section)
# ---------------------------------------------------------------------------
CHECK_WEEKDAY_MEAN = 26.0     # avg $/cover, weekday
CHECK_WEEKEND_MEAN = 29.0     # avg $/cover, weekend (bigger checks, not just more covers)
CHECK_SIGMA = 0.12            # lognormal sigma for per-day avg check noise

BASE_SALES_WEEKDAY = 5500     # target midpoint of the $5-6k weekday range
BASE_SALES_WEEKEND = 11000    # target midpoint of the $10-12k weekend range

# Monthly seasonal multiplier applied to covers. Shape calibrated to a
# recalled pattern of: summer = yearly low, recovering into an October peak,
# a shallower January dip, then rising again — not the "summer patio bump"
# often assumed for casual dining.
MONTH_SEASONAL_MULT = {
    1: 0.93, 2: 0.95, 3: 0.98, 4: 1.00, 5: 1.03, 6: 0.95,
    7: 0.84, 8: 0.84, 9: 0.93, 10: 1.10, 11: 1.03, 12: 1.05,
}

WEATHER_PROB_BY_MONTH = {
    # (p_clear, p_rain, p_heavy_rain, p_snow) — rough Pacific-Northwest-style climate
    1: (0.35, 0.40, 0.15, 0.10), 2: (0.40, 0.40, 0.15, 0.05),
    3: (0.45, 0.40, 0.13, 0.02), 4: (0.55, 0.35, 0.10, 0.00),
    5: (0.65, 0.28, 0.07, 0.00), 6: (0.72, 0.23, 0.05, 0.00),
    7: (0.85, 0.12, 0.03, 0.00), 8: (0.85, 0.12, 0.03, 0.00),
    9: (0.70, 0.23, 0.07, 0.00), 10: (0.50, 0.35, 0.13, 0.02),
    11: (0.35, 0.42, 0.18, 0.05), 12: (0.30, 0.40, 0.20, 0.10),
}
WEATHER_SALES_MULT = {"clear": 1.00, "rain": 0.94, "heavy_rain": 0.87, "snow": 0.70}

# Labor cost is managed toward a 25-33% of sales target band rather than
# derived bottom-up (front-of-house staffing/wage data wasn't available —
# only back-of-house headcount patterns were, so this is a target-band
# approximation, not a real labor cost buildup).
LABOR_TARGET_LOW = 0.25
LABOR_TARGET_HIGH = 0.33
LABOR_TARGET_MID = (LABOR_TARGET_LOW + LABOR_TARGET_HIGH) / 2

N_POS_OUTAGE_DAYS = 7          # fully missing days (simulated POS outage)
N_PARTIAL_MESSY_DAYS = 6       # days with only some fields missing/corrupted


def _month_day_range(dates, month, day_start, day_end):
    return (dates.month == month) & (dates.day >= day_start) & (dates.day <= day_end)


def _nth_weekday_of_month(year, month, weekday, n):
    """weekday: Monday=0 ... Sunday=6. Returns the date of the n-th such weekday."""
    d = pd.Timestamp(year=year, month=month, day=1)
    offset = (weekday - d.weekday()) % 7
    d = d + pd.Timedelta(days=offset)
    return d + pd.Timedelta(weeks=n - 1)


def build_calendar_flags(dates: pd.DatetimeIndex) -> pd.DataFrame:
    df = pd.DataFrame(index=dates)
    df["is_weekend"] = dates.dayofweek >= 5

    years = sorted(set(dates.year))

    # Mother's Day (2nd Sunday of May), Father's Day (3rd Sunday of June) — major holidays
    major_holiday_dates = set()
    for y in years:
        major_holiday_dates.add(_nth_weekday_of_month(y, 5, 6, 2))   # Sun=6, 2nd
        major_holiday_dates.add(_nth_weekday_of_month(y, 6, 6, 3))   # Sun=6, 3rd
    df["is_major_holiday"] = dates.isin(pd.DatetimeIndex(list(major_holiday_dates)))

    # Signature annual promo/charity day — fixed anchor: first Saturday of June
    signature_dates = {_nth_weekday_of_month(y, 6, 5, 1) for y in years}  # Sat=5, 1st
    df["is_signature_promo_day"] = dates.isin(pd.DatetimeIndex(list(signature_dates)))
    df["signature_promo_year_index"] = 0
    for i, y in enumerate(years):
        mask = dates.isin(pd.DatetimeIndex([d for d in signature_dates if d.year == y]))
        df.loc[mask, "signature_promo_year_index"] = i

    # Canadian Thanksgiving (2nd Monday of October) and Christmas week — treated
    # as "special day" tier per calibration notes, plus Dec 25 closure.
    thanksgiving_dates = {_nth_weekday_of_month(y, 10, 0, 2) for y in years}  # Mon=0, 2nd
    df["is_thanksgiving_special"] = dates.isin(pd.DatetimeIndex(list(thanksgiving_dates)))

    df["is_christmas_week_special"] = False
    df["is_closed"] = False
    for y in years:
        pre_xmas = _month_day_range(dates, 12, 18, 23)
        df.loc[pre_xmas & (dates.year == y), "is_christmas_week_special"] = True
        christmas = (dates.month == 12) & (dates.day == 25) & (dates.year == y)
        df.loc[christmas, "is_closed"] = True

    # Summer-long promo (diffuse, modest lift)
    df["is_summer_deal_active"] = (dates.month >= 6) & (dates.month <= 8)

    # Generic "graduation season" windows (anonymized — nearby university)
    df["is_grad_season"] = _month_day_range(dates, 6, 1, 15) | _month_day_range(dates, 10, 1, 15)

    # 2026 FIFA World Cup demand window (host-city effect, anonymized to "major sporting event")
    df["is_major_sporting_event_window"] = (dates >= "2026-06-11") & (dates <= "2026-07-19")

    df["is_special_day"] = (
        df["is_major_holiday"] | df["is_signature_promo_day"]
        | df["is_thanksgiving_special"] | df["is_christmas_week_special"]
    )
    return df


def simulate(n_days: int = N_DAYS, end_date: str = END_DATE, seed: int = RNG_SEED) -> pd.DataFrame:
    rng = np.random.default_rng(seed)

    dates = pd.date_range(end=end_date, periods=n_days, freq="D")
    flags = build_calendar_flags(dates)

    df = flags.copy()
    df.insert(0, "date", dates)
    df["day_of_week"] = dates.day_name()
    df["month"] = dates.month

    # --- Weather (simulated categorical variable, seasonally weighted) ---
    weather_choices = np.array(["clear", "rain", "heavy_rain", "snow"])
    weather = np.empty(n_days, dtype=object)
    for i, m in enumerate(df["month"].values):
        probs = WEATHER_PROB_BY_MONTH[m]
        weather[i] = rng.choice(weather_choices, p=probs)
    df["weather"] = weather
    weather_mult = df["weather"].map(WEATHER_SALES_MULT).values

    # --- Base covers (traffic) via seasonal + weather + promo multipliers ---
    base_check = np.where(df["is_weekend"], CHECK_WEEKEND_MEAN, CHECK_WEEKDAY_MEAN)
    base_sales = np.where(df["is_weekend"], BASE_SALES_WEEKEND, BASE_SALES_WEEKDAY)
    base_covers_mean = base_sales / base_check

    seasonal_mult = df["month"].map(MONTH_SEASONAL_MULT).values
    summer_deal_mult = np.where(df["is_summer_deal_active"], 1.05, 1.00)
    grad_season_mult = np.where(df["is_grad_season"], 1.08, 1.00)
    sporting_event_mult = np.where(df["is_major_sporting_event_window"], 1.15, 1.00)

    covers_mean = (
        base_covers_mean * seasonal_mult * weather_mult
        * summer_deal_mult * grad_season_mult * sporting_event_mult
    )
    covers_mean = np.clip(covers_mean, 20, None)
    covers = rng.poisson(covers_mean)

    # --- Check size (lognormal noise around weekday/weekend mean) ---
    check_mu = np.log(base_check)
    avg_check = rng.lognormal(mean=check_mu, sigma=CHECK_SIGMA)

    sales = covers * avg_check

    # --- Special days: override with target sales bands, per calibration ---
    is_major_holiday = df["is_major_holiday"].values
    n_holiday = is_major_holiday.sum()
    sales[is_major_holiday] = rng.uniform(20000, 25000, size=n_holiday)
    avg_check[is_major_holiday] = rng.lognormal(mean=np.log(CHECK_WEEKEND_MEAN * 1.05), sigma=CHECK_SIGMA, size=n_holiday)
    covers[is_major_holiday] = np.round(sales[is_major_holiday] / avg_check[is_major_holiday]).astype(int)

    is_sig = df["is_signature_promo_day"].values
    n_sig = is_sig.sum()
    yoy_idx = df.loc[is_sig, "signature_promo_year_index"].values
    sig_low = 25000 + yoy_idx * 300   # slight YoY uptrend across the 3 observed years
    sig_high = 28000 + yoy_idx * 300
    sales[is_sig] = rng.uniform(sig_low, sig_high)
    avg_check[is_sig] = rng.lognormal(mean=np.log(CHECK_WEEKEND_MEAN * 1.05), sigma=CHECK_SIGMA, size=n_sig)
    covers[is_sig] = np.round(sales[is_sig] / avg_check[is_sig]).astype(int)

    # Thanksgiving / Christmas-week turkey dinner — treated as "special day" tier
    is_other_special = (df["is_thanksgiving_special"] | df["is_christmas_week_special"]).values & ~is_major_holiday & ~is_sig
    n_other = is_other_special.sum()
    sales[is_other_special] = rng.uniform(20000, 25000, size=n_other)
    avg_check[is_other_special] = rng.lognormal(mean=np.log(CHECK_WEEKEND_MEAN * 1.05), sigma=CHECK_SIGMA, size=n_other)
    covers[is_other_special] = np.round(sales[is_other_special] / avg_check[is_other_special]).astype(int)

    df["covers"] = covers
    df["avg_check"] = np.round(avg_check, 2)
    df["sales"] = np.round(sales, 2)

    # --- Closure day (Dec 25): zero sales, not "missing" ---
    closed = df["is_closed"].values
    df.loc[closed, ["covers", "avg_check", "sales"]] = 0

    # --- Labor cost: noisy target-band, not a bottom-up buildup ---
    # Slow days push toward the high end of the band (fixed minimum staffing
    # costs more, % of sales); high-volume/special days push toward the low end.
    sales_for_norm = df["sales"].replace(0, np.nan)
    day_type_mean = np.where(df["is_weekend"], BASE_SALES_WEEKEND, BASE_SALES_WEEKDAY)
    relative_volume = (sales_for_norm / day_type_mean).clip(0.4, 2.5)
    labor_center = LABOR_TARGET_MID - 0.03 * (relative_volume - 1.0)
    labor_center = labor_center.clip(LABOR_TARGET_LOW, LABOR_TARGET_HIGH)
    labor_noise = rng.normal(0, 0.015, size=n_days)
    df["labor_cost_pct"] = np.round((labor_center + labor_noise).clip(0.20, 0.40), 4)
    df.loc[closed, "labor_cost_pct"] = np.nan

    # --- Messy/missing data: simulated POS outages + partial data issues ---
    df["is_pos_outage"] = False
    non_closed_idx = df.index[~closed]
    outage_idx = rng.choice(non_closed_idx, size=N_POS_OUTAGE_DAYS, replace=False)
    df.loc[outage_idx, ["covers", "avg_check", "sales", "labor_cost_pct"]] = np.nan
    df.loc[outage_idx, "is_pos_outage"] = True

    remaining_idx = df.index.difference(outage_idx).difference(df.index[closed])
    partial_idx = rng.choice(remaining_idx, size=N_PARTIAL_MESSY_DAYS, replace=False)
    for idx in partial_idx:
        field = rng.choice(["avg_check", "labor_cost_pct", "covers"])
        df.loc[idx, field] = np.nan

    df = df.drop(columns=["signature_promo_year_index"])
    return df.reset_index(drop=True)


def print_validation(df: pd.DataFrame, target_ratio: float = 2.0) -> None:
    clean = df[~df["is_special_day"] & ~df["is_closed"] & ~df["is_pos_outage"] & df["sales"].notna()]
    weekday_mean = clean.loc[~clean["is_weekend"], "sales"].mean()
    weekend_mean = clean.loc[clean["is_weekend"], "sales"].mean()
    ratio = weekend_mean / weekday_mean

    print("=== Simulation validation (SIMULATED DATA) ===")
    print(f"Mean weekday sales (non-special days): ${weekday_mean:,.0f}")
    print(f"Mean weekend sales (non-special days): ${weekend_mean:,.0f}")
    print(f"Weekend/weekday ratio: {ratio:.2f}  (calibration target: ~{target_ratio:.1f})")
    ok = abs(ratio - target_ratio) / target_ratio < 0.15
    print("Within 15% of calibration target:", "PASS" if ok else "CHECK — investigate")

    summer = clean.loc[clean["month"].isin([7, 8]), "sales"].mean()
    october = clean.loc[clean["month"] == 10, "sales"].mean()
    swing = (october - summer) / october
    print(f"\nMean summer (Jul/Aug) sales: ${summer:,.0f}")
    print(f"Mean October sales: ${october:,.0f}")
    print(f"Summer-trough vs October-peak swing: {swing:.1%}  (calibration target: ~15-20%)")


if __name__ == "__main__":
    data = simulate()
    print_validation(data)

    out_csv = "data/daily_sales.csv"
    out_parquet = "data/daily_sales.parquet"
    data.to_csv(out_csv, index=False)
    data.to_parquet(out_parquet, index=False)
    print(f"\nWrote {len(data)} rows to {out_csv} and {out_parquet}")
