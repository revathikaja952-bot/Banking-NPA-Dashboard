"""
Synthetic Bank Loan Portfolio Data Generator
--------------------------------------------
Creates 6 CSV files for a Loan Portfolio & NPA dashboard:
  customers.csv, branches.csv, products.csv, loans.csv, repayments.csv, date_table.csv

Run:  pip install pandas numpy
      python generate_banking_data.py
Output goes to the folder ./banking_data
"""
import os
import numpy as np
import pandas as pd

SEED = 42
N_CUSTOMERS = 8000
START = "2023-01-01"          # first possible disbursal
SNAP_START = "2024-09-30"     # repayment snapshots reported from this month-end
SNAP_END = "2026-08-31"       # last month-end
OUT_DIR = "banking_data"

rng = np.random.default_rng(SEED)
os.makedirs(OUT_DIR, exist_ok=True)

# ---------------------------------------------------------------- BRANCHES
city_info = {   # city: (state, region)
    "Hyderabad": ("Telangana", "South"), "Chennai": ("Tamil Nadu", "South"),
    "Bengaluru": ("Karnataka", "South"), "Kochi": ("Kerala", "South"),
    "Mumbai": ("Maharashtra", "West"), "Pune": ("Maharashtra", "West"),
    "Ahmedabad": ("Gujarat", "West"), "Surat": ("Gujarat", "West"),
    "Delhi": ("Delhi", "North"), "Gurugram": ("Haryana", "North"),
    "Jaipur": ("Rajasthan", "North"), "Lucknow": ("Uttar Pradesh", "North"),
    "Chandigarh": ("Chandigarh", "North"), "Kolkata": ("West Bengal", "East"),
    "Patna": ("Bihar", "East"), "Bhubaneswar": ("Odisha", "East"),
}
areas = ["Main Road", "Central", "Market Square", "Tech Park"]
rows = []
bid = 1
for city, (state, region) in city_info.items():
    for a in areas[: rng.integers(2, 4)]:       # 2-3 branches per city
        rows.append([f"BR{bid:03d}", f"{city} - {a}", city, state, region])
        bid += 1
branches = pd.DataFrame(rows, columns=["branch_id", "branch_name", "city", "state", "region"])

# ---------------------------------------------------------------- PRODUCTS
products = pd.DataFrame({
    "product_id": ["P01", "P02", "P03", "P04"],
    "product_type": ["Home Loan", "Personal Loan", "Auto Loan", "Education Loan"],
})
prod_cfg = {  # amount range, rate range, tenure choices, risk multiplier
    "P01": ((1_500_000, 8_000_000), (8.3, 9.5), [180, 240, 300], 0.5),
    "P02": ((50_000, 1_500_000), (11.0, 16.5), [24, 36, 48, 60], 1.8),
    "P03": ((300_000, 1_800_000), (8.8, 11.5), [36, 48, 60, 84], 1.0),
    "P04": ((200_000, 2_500_000), (9.0, 12.0), [60, 84, 120], 1.2),
}

# --------------------------------------------------------------- CUSTOMERS
income = np.clip(rng.lognormal(mean=13.2, sigma=0.55, size=N_CUSTOMERS), 180_000, 6_000_000).round(-3)
score = np.clip(rng.normal(715, 70, N_CUSTOMERS), 300, 900).round().astype(int)
customers = pd.DataFrame({
    "customer_id": [f"C{i:05d}" for i in range(1, N_CUSTOMERS + 1)],
    "age": rng.integers(21, 66, N_CUSTOMERS),
    "annual_income": income,
    "city": rng.choice(branches["city"], N_CUSTOMERS),
    "credit_score": score,
})
customers["segment"] = pd.cut(customers["annual_income"], [0, 600_000, 1_500_000, 1e9],
                              labels=["Mass", "Affluent", "Premium"]).astype(str)

# ------------------------------------------------------------------- LOANS
n_months = (pd.Timestamp(SNAP_END).year - 2023) * 12 + pd.Timestamp(SNAP_END).month   # month index count
month_ends = pd.date_range(START, SNAP_END, freq="ME")
last_disb_idx = n_months - 3   # leave room for at least 2 EMIs

loan_rows = []
lid = 1
cust_city = dict(zip(customers.customer_id, customers.city))
branch_by_city = branches.groupby("city")["branch_id"].apply(list).to_dict()
for cid, city in cust_city.items():
    for _ in range(rng.choice([1, 2], p=[0.75, 0.25])):
        pid = rng.choice(products.product_id, p=[0.25, 0.35, 0.28, 0.12])
        (a_lo, a_hi), (r_lo, r_hi), tenures, _ = prod_cfg[pid]
        amount = round(rng.uniform(a_lo, a_hi), -4)
        rate = round(rng.uniform(r_lo, r_hi), 2)
        tenure = int(rng.choice(tenures))
        m0 = int(rng.integers(0, last_disb_idx + 1))
        disb = month_ends[m0] - pd.Timedelta(days=int(rng.integers(0, 27)))
        r = rate / 1200
        emi = amount * r * (1 + r) ** tenure / ((1 + r) ** tenure - 1)
        loan_rows.append([f"L{lid:06d}", cid, str(rng.choice(branch_by_city[city])), pid,
                          disb.date(), amount, rate, tenure, round(emi, 2), m0])
        lid += 1
loans = pd.DataFrame(loan_rows, columns=["loan_id", "customer_id", "branch_id", "product_id",
                                         "disbursal_date", "loan_amount", "interest_rate",
                                         "tenure_months", "emi", "m0"])

# ------------------------------------------------------------- REPAYMENTS
score_map = dict(zip(customers.customer_id, customers.credit_score))
region_map = dict(zip(branches.branch_id, branches.region))
snap_start_ts = pd.Timestamp(SNAP_START)
rep_rows = []
closed_ids = set()

for L in loans.itertuples(index=False):
    r = L.interest_rate / 1200
    n = L.tenure_months
    base = 0.03 + max(0, (750 - score_map[L.customer_id])) / 100 * 0.03
    base *= prod_cfg[L.product_id][3]
    # planted insight: Personal Loans in the East region are riskier
    if L.product_id == "P02" and region_map[L.branch_id] == "East":
        base *= 1.7
    dpd, paid_cnt = 0, 0
    for k in range(1, n + 1):
        mi = L.m0 + k
        if mi >= n_months:
            break
        drift = 1 + 0.03 * max(0, mi - 30)          # risk creeping up over time
        p_miss = min(0.9, base * drift) if dpd == 0 else 0.72
        if rng.random() < p_miss:
            paid, dpd = 0.0, min(dpd + 30, 180)
        else:
            paid = L.emi
            paid_cnt += 1
            dpd = 0 if rng.random() < 0.6 else max(dpd - 30, 0)
        bal = L.loan_amount * ((1 + r) ** n - (1 + r) ** paid_cnt) / ((1 + r) ** n - 1)
        me = month_ends[mi]
        if me >= snap_start_ts:
            rep_rows.append([L.loan_id, me.date(), round(L.emi, 2), round(paid, 2), dpd, round(max(bal, 0), 2)])
        if paid_cnt >= n:
            closed_ids.add(L.loan_id)
            break
repayments = pd.DataFrame(rep_rows, columns=["loan_id", "month_end", "emi_due", "emi_paid",
                                             "dpd", "outstanding_balance"])
loans["status"] = np.where(loans.loan_id.isin(closed_ids), "Closed", "Active")
loans = loans.drop(columns="m0")

# ------------------------------------------------------------- DATE TABLE
d = pd.DataFrame({"date": pd.date_range("2023-01-01", "2026-12-31")})
d["year"] = d.date.dt.year
d["quarter"] = "Q" + d.date.dt.quarter.astype(str)
d["month_num"] = d.date.dt.month
d["month_name"] = d.date.dt.strftime("%b")
d["year_month"] = d.date.dt.strftime("%Y-%m")
d["month_end"] = d.date + pd.offsets.MonthEnd(0)

# --------------------------------------- DELIBERATE DATA-QUALITY ISSUES
# (so you can practise cleansing in SQL / Power Query)
dirty = customers.copy()
idx = rng.choice(len(dirty), 80, replace=False)
dirty.loc[idx, "credit_score"] = np.nan                                   # nulls
idx = rng.choice(len(dirty), 60, replace=False)
dirty.loc[idx, "city"] = dirty.loc[idx, "city"].str.upper() + " "         # bad casing + trailing space
dirty = pd.concat([dirty, dirty.sample(40, random_state=SEED)])           # duplicate rows
customers_dirty = dirty.sample(frac=1, random_state=SEED).reset_index(drop=True)

# ------------------------------------------------------------------ SAVE
files = {"customers": customers_dirty, "branches": branches, "products": products,
         "loans": loans, "repayments": repayments, "date_table": d}
for name, df in files.items():
    df.to_csv(os.path.join(OUT_DIR, f"{name}.csv"), index=False)
    print(f"{name:12s} {len(df):>9,} rows")

# --------------------------------------------------------- QUICK SANITY CHECK
last = repayments[repayments.month_end == pd.Timestamp(SNAP_END).date()]
gnpa = last.loc[last.dpd > 90, "outstanding_balance"].sum() / last.outstanding_balance.sum()
print(f"\nGNPA % at {SNAP_END}: {gnpa:.2%}  (realistic range: ~2-8%)")
