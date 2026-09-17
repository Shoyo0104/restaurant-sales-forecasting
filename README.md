# Restaurant Sales Forecasting (Portfolio Project)

Data is simulated by [`src/simulate_restaurant_sales.py`](src/simulate_restaurant_sales.py), calibrated to patterns from working as a line cook at a casual-dining restaurant. No real POS or financial data.

## Project goal

End-to-end portfolio project: calibrated sales simulation, EDA, and a forecasting model comparison on a proper holdout.

## Repo structure

```
data/           daily_sales.csv, daily_sales.parquet (simulated)
notebooks/      01_eda.ipynb, 02_modeling.ipynb
src/            simulate_restaurant_sales.py
```

## Methodology

Calibration is based on personal experience working as a line cook at a casual-dining restaurant: weekday vs. weekend volume, check size, seasonal slow/busy periods, weather and promo impact, staffing patterns.

- ~940 days generated with numpy/pandas: day-of-week effects, monthly seasonal curve, weather variable, promo/special days, Poisson covers, lognormal check sizes.
- A handful of incomplete days (simulated POS outages, partial-field gaps, real closures) included for the cleaning step.
- Simulation script validates itself — prints the weekend/weekday ratio and the summer-vs-October swing against the calibration targets.
- EDA: day-of-week/monthly patterns, weather and special-day impact, trend/seasonal decomposition, missing-data handling.
- Forecasting: SARIMA, XGBoost, and Ridge regression, compared on a 90-day time-based holdout (no shuffling).

## Calibration approach

| Parameter | Simulated value | Source |
|---|---|---|
| Weekday sales | ~$5,000-6,000/day | Recalled |
| Weekend sales | ~$10,000-12,000/day | Recalled |
| Weekend/weekday ratio | ~2.0x | Derived, used as validation target |
| Average check | $25-30/person, bigger on weekends | Recalled |
| Seasonal shape | Summer = low point, climbs to a peak in October, shallower dip in January | Recalled |
| Seasonal swing | ~15-20%, summer trough to October peak | Estimated from back-of-house staffing headcount (summer schedules ~15-20% lighter) |
| Weather | Rain -5 to -8%, heavy rain -10 to -15%, snow -25 to -35% | Direction recalled; magnitude from [published restaurant weather-impact data](https://www.teamupwithliberty.com/post/how-weather-affects-restaurants-sales) for a similar climate |
| Promos | Summer-long deal, Thanksgiving/Christmas turkey dinner (special-day tier), one annual signature promo day (slight YoY uptrend) | Recalled |
| Labor cost | 25-33% of sales target band | Target-band approximation — only back-of-house headcount was available, not FOH or wage data |
| Special days / closures | Closed every Dec 25, Mother's/Father's Day at $20-25k, one-off windows for grad season and a 2026 major sporting event (anonymized) | Recalled |

## Model comparison

90-day holdout, 2026-04-21 to 2026-07-19, no shuffling:

| Model | MAE | MAPE |
|---|---|---|
| SARIMA (1,1,1)(1,1,1,7) | $1,445 | 14.4% |
| XGBoost | $959 | 11.7% |
| Ridge (linear + Fourier terms) | $1,012 | 12.4% |

XGBoost has the lowest error, with Ridge close behind. Ridge gets most of the way to XGBoost's accuracy once seasonality is fed in explicitly as Fourier terms — the remaining gap is likely XGBoost picking up interactions (e.g. weather affecting weekends and weekdays differently) that Ridge would need explicit interaction terms for.

SARIMA trails both. Its seasonal term is weekly only (`(1,1,1,7)`); a full annual seasonal order isn't practical for daily-frequency SARIMA, so it has no direct way to see the October peak or summer trough. Full comparison and forecast plot in [`notebooks/02_modeling.ipynb`](notebooks/02_modeling.ipynb).

These are simulated numbers with effect sizes chosen by the author — the comparison demonstrates methodology, not real-world forecast accuracy.

## Findings

- Weekend sales ~2x weekday sales.
- Summer is the slow season, not the busy one — sales dip in July/August, recover through October.
- XGBoost and Ridge both beat SARIMA by 30%+ MAE; Ridge nearly matches XGBoost once seasonality is Fourier-encoded.
- Missing data clusters around simulated outages and yearly closures, not randomly — cleaning needs to treat "closed" (true zero) differently from "outage" (needs imputing).

## Reproducing

```bash
pip install -r requirements.txt
python src/simulate_restaurant_sales.py   # regenerates data/daily_sales.{csv,parquet}
jupyter nbconvert --to notebook --execute --inplace notebooks/01_eda.ipynb
jupyter nbconvert --to notebook --execute --inplace notebooks/02_modeling.ipynb
```
