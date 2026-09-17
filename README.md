# Restaurant Sales Forecasting (Portfolio Project)

Data is simulated by [`src/simulate_restaurant_sales.py`](src/simulate_restaurant_sales.py), calibrated to patterns recalled from working as a line cook at a casual-dining restaurant — no real POS or financial data.

## Project goal

Build a complete, interview-ready data analyst portfolio project end to end: a calibrated sales
simulation, exploratory analysis, two forecasting approaches compared on a proper holdout, and a
clean repo structure — demonstrating the full workflow rather than just a polished notebook.

## Repo structure

```
data/           daily_sales.csv, daily_sales.parquet (simulated)
notebooks/      01_eda.ipynb, 02_modeling.ipynb
src/            simulate_restaurant_sales.py
```

## Methodology

1. **Calibration interview** — before writing any simulation code, real-world *patterns* (not
   figures) were gathered: typical weekday vs. weekend volume, average check size, the
   weekend/weekday sales ratio, seasonal shape across the year, weather sensitivity, promo
   frequency/impact, and staffing patterns.
2. **Simulation** — ~940 days of daily data generated with `numpy`/`pandas`: day-of-week effects,
   a custom monthly seasonal curve, a simulated weather variable, promo/special-day flags,
   Poisson-distributed covers, lognormal check sizes, and a small number of intentionally messy
   days (simulated POS outages, partial-field gaps, and real closures) so the analysis notebook
   has genuine cleaning work to do.
3. **Validation** — the simulation script prints the weekend/weekday sales ratio and the
   summer-trough vs. October-peak swing, and checks each against the calibration targets before
   the data is written out.
4. **EDA** — day-of-week and monthly patterns, weather and special-day impact, trend/seasonal
   decomposition, and a missing-data audit.
5. **Forecasting** — SARIMA, XGBoost (with lag/rolling features), and Ridge regression (linear,
   with Fourier seasonality terms) compared on a time-based 90-day holdout (no shuffling).

## Calibration approach

| Parameter | Simulated value | Source |
|---|---|---|
| Weekday sales | ~$5,000-6,000/day | Recalled pattern |
| Weekend sales | ~$10,000-12,000/day | Recalled pattern |
| Weekend/weekday ratio | ~2.0x | Derived from the above, used as a validation target |
| Average check | $25-30/person, bigger on weekends | Recalled pattern |
| Seasonal shape | Summer = yearly low, October = peak, shallow January dip | Recalled pattern (notably *not* the "summer patio bump" often assumed for casual dining) |
| Seasonal swing | ~15-20% (summer trough to October peak) | Estimated via back-of-house staffing headcount ratios (summer staffing ~15-20% lighter than regular season) |
| Weather sensitivity | Rain -5 to -8%, heavy rain -10 to -15%, snow -25 to -35% | Recalled directional pattern ("rain slows people down a bit"), magnitude grounded in [published restaurant industry weather-impact data](https://www.teamupwithliberty.com/post/how-weather-affects-restaurants-sales) for a comparable Pacific-Northwest-style climate |
| Promos | Summer-long deal (diffuse, modest lift), Thanksgiving & Christmas-week turkey dinner (treated as special-day tier), one signature annual promo/charity day (slight YoY uptrend) | Recalled pattern: "not much promo" outside these |
| Labor cost | Managed to a 25-33% of sales target band | Recalled policy; modeled as a noisy target rather than a bottom-up buildup since front-of-house staffing and wage data weren't available (only back-of-house headcount patterns were) |
| Special/closure days | Dec 25 closed every year; Mother's/Father's Day at $20-25k; one-off demand windows for graduation season and a 2026 major sporting event, both anonymized | Recalled pattern |

## Model comparison

Time-based 90-day holdout (2026-04-21 to 2026-07-19), no shuffling:

| Model | MAE | MAPE |
|---|---|---|
| SARIMA (order (1,1,1), weekly seasonal (1,1,1,7)) | $1,445 | 14.4% |
| **XGBoost** (lag 1/7/14/28, rolling means, calendar/weather features) | **$959** | **11.7%** |
| Ridge (linear, Fourier seasonality + lag/rolling features) | $1,012 | 12.4% |

**XGBoost wins**, but only narrowly over Ridge (~6% lower MAE) — both comfortably beat SARIMA by
30%+. The more interesting result is how close Ridge gets: once seasonality is handed to a linear
model explicitly as Fourier terms (instead of relying on the model to infer it), a plain
regularized linear model gets most of the way to tree-based performance. XGBoost's remaining edge
likely comes from modeling interactions for free via splits (e.g. weather effects compounding
differently on weekends vs. weekdays) that a linear model would need explicit interaction terms
to capture. SARIMA lags both because its seasonal term only covers the weekly cycle — a full
annual seasonal order (period=365) is computationally impractical for daily-frequency state-space
SARIMA, so it has no direct way to see the October peak, summer trough, or special-day spikes,
only what differencing and trend infer indirectly. See
[`notebooks/02_modeling.ipynb`](notebooks/02_modeling.ipynb) for the full comparison and forecast
plot.

*Caveat: these MAE/MAPE numbers reflect a simulation with effect sizes chosen by the author — they
demonstrate methodology, not a claim about real-world forecast accuracy for any actual restaurant.*

## Headline findings (simulated data)

- **Weekend sales run ~2x weekday sales**, matching the calibration target derived from recalled
  volume patterns.
- **Summer is the slowest season, not the busiest** — sales trough in July/August and recover to
  a peak in October, a ~15-20% swing, contrary to the "patio season" assumption often made about
  casual dining.
- **XGBoost and Ridge both beat SARIMA by 30%+ MAE** on the holdout because they can directly use
  calendar, weather, and special-day features that a weekly-seasonal SARIMA model can't easily
  represent — and once seasonality is Fourier-encoded, a plain linear model (Ridge) nearly
  matches XGBoost's accuracy.
- **Missing data is structured, not random** — it's concentrated in simulated POS-outage days and
  known annual closures, which changes how it should be handled (explicit zero vs. interpolation)
  rather than being safely ignorable.

## Reproducing

```bash
pip install -r requirements.txt
python src/simulate_restaurant_sales.py   # regenerates data/daily_sales.{csv,parquet}
jupyter nbconvert --to notebook --execute --inplace notebooks/01_eda.ipynb
jupyter nbconvert --to notebook --execute --inplace notebooks/02_modeling.ipynb
```
