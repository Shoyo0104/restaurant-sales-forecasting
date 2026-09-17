# Restaurant Sales Forecasting (Portfolio Project)

Data is simulated by [`src/simulate_restaurant_sales.py`](src/simulate_restaurant_sales.py), calibrated to patterns I picked up working as a line cook at a casual-dining restaurant — no real POS or financial data here.

## Why this project

Wanted something more than a Kaggle dataset + notebook for my portfolio, so I built the whole pipeline myself: calibrate a simulation off real-world patterns, generate the data, explore it, then compare a few forecasting approaches on a proper holdout. Goal was to show the full workflow, not just a chart.

## Repo structure

```
data/           daily_sales.csv, daily_sales.parquet (simulated)
notebooks/      01_eda.ipynb, 02_modeling.ipynb
src/            simulate_restaurant_sales.py
```

## Methodology

Before writing any code I did a calibration pass on myself — what's a slow weekday actually look like, what's a busy weekend, does check size move on weekends or is it just more covers, that kind of thing. Where an answer was vague I pushed for a follow-up instead of just guessing at a number.

From there:
- Generated ~940 days with numpy/pandas — day-of-week effects, a monthly seasonal curve, a weather variable, promo/special days, Poisson covers, lognormal check sizes.
- Threw in some messy days on purpose (a few simulated POS outages, a couple of partial-field gaps, real closures) so there's actual cleaning work to do in the EDA notebook, not a dataset that's already spotless.
- The simulation script checks itself — it prints the weekend/weekday ratio and the summer-vs-October swing and compares them against the targets from the calibration step.
- EDA covers day-of-week/monthly patterns, weather and special-day impact, a trend/seasonal decomposition, and the missing-data situation.
- Forecasting: SARIMA, XGBoost, and Ridge regression, compared on a 90-day time-based holdout (no shuffling — it's daily sequential data).

## Calibration approach

| Parameter | Simulated value | Where it came from |
|---|---|---|
| Weekday sales | ~$5,000-6,000/day | recalled |
| Weekend sales | ~$10,000-12,000/day | recalled |
| Weekend/weekday ratio | ~2.0x | derived from the above, used as the validation target |
| Average check | $25-30/person, bigger on weekends | recalled |
| Seasonal shape | summer = low point of the year, climbs to a peak in October, a shallower dip in January | recalled — honestly the opposite of the "summer patio bump" I expected before asking |
| Seasonal swing | ~15-20%, summer trough to October peak | back-of-house staffing headcount was the best proxy I had — summer schedules run about 15-20% lighter |
| Weather | rain -5 to -8%, heavy rain -10 to -15%, snow -25 to -35% | direction was recalled ("rain slows people down a bit"), magnitude pulled from [published restaurant weather-impact data](https://www.teamupwithliberty.com/post/how-weather-affects-restaurants-sales) for a similar climate |
| Promos | summer-long deal, Thanksgiving/Christmas turkey dinner (special-day tier), one annual signature promo day (slight YoY uptrend) | recalled — not a promo-heavy place outside of these |
| Labor cost | kept to a 25-33% of sales target band | this one's a target-band approximation, not a real buildup — I only had back-of-house headcount, not FOH or wage data |
| Special days / closures | closed every Dec 25, Mother's/Father's Day around $20-25k, plus one-off windows for grad season and a 2026 major sporting event (anonymized) | recalled |

## Model comparison

90-day holdout, 2026-04-21 to 2026-07-19, no shuffling:

| Model | MAE | MAPE |
|---|---|---|
| SARIMA (1,1,1)(1,1,1,7) | $1,445 | 14.4% |
| XGBoost | $959 | 11.7% |
| Ridge (linear + Fourier terms) | $1,012 | 12.4% |

XGBoost comes out on top, but Ridge is only about $50 MAE behind it — closer than I expected going in. Once seasonality is fed to Ridge explicitly as Fourier terms instead of leaving it to figure out on its own, a plain linear model gets most of the way to tree-based accuracy. XGBoost's edge is probably from picking up interactions on its own (e.g. weather hitting weekends differently than weekdays) that Ridge would need hand-built interaction terms for.

SARIMA trails both by a fair bit. Its seasonal term is weekly only (`(1,1,1,7)`) — a full annual seasonal order is not really feasible for daily-frequency SARIMA — so it has no way to directly see the October peak or the summer trough, only whatever trend/differencing happens to pick up. Full comparison and the forecast plot are in [`notebooks/02_modeling.ipynb`](notebooks/02_modeling.ipynb).

(Worth repeating: these are simulated numbers with effect sizes I chose, so treat the MAE/MAPE as a demo of the methodology, not a real accuracy claim.)

## A few things that stood out

- Weekend sales land around 2x weekday sales, matching what I set out to hit.
- Summer is actually the slow season here, not the busy one — sales dip in July/August and climb back up through October. Not what I assumed before doing the calibration interview.
- XGBoost and Ridge both beat SARIMA by 30%+ on MAE, and Ridge gets surprisingly close to XGBoost once seasonality is hand-fed to it as Fourier terms.
- The missing data isn't random — it clusters around a handful of simulated outages and the yearly closures, so the cleaning approach has to treat "closed" (a real zero) differently from "outage" (unknown, needs imputing).

## Reproducing

```bash
pip install -r requirements.txt
python src/simulate_restaurant_sales.py   # regenerates data/daily_sales.{csv,parquet}
jupyter nbconvert --to notebook --execute --inplace notebooks/01_eda.ipynb
jupyter nbconvert --to notebook --execute --inplace notebooks/02_modeling.ipynb
```
