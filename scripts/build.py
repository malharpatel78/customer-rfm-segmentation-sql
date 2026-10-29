"""
Rebuilds this project end to end:

  1. loads the raw CSV file(s) in data/ into a SQLite database (all columns as text)
  2. runs every sql/0*_*.sql file in order (cleaning first, then analysis)
  3. saves each analysis query's output to results/<name>.csv
  4. writes the interactive dashboard to docs/index.html (served by GitHub Pages)

Usage:  python scripts/build.py
Needs:  Python 3.9+ and pandas (pip install pandas)

The SQL files are plain SQLite and also run as-is in DB Browser for SQLite.
Analysis queries are tagged with comment lines that the dashboard reads:

  -- @name: city_counts           (file name for results/ and the dashboard id)
  -- @title: Restaurants by city   (panel heading)
  -- @chart: hbar x=city y=restaurants   (bar | hbar | line | kpi | table)
  -- @insight: one sentence on what the result means
"""
import json
import re
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / "project.json").read_text(encoding="utf-8"))
DB_PATH = ROOT / "data" / CONFIG["database"]


def load_raw(con):
    for src in CONFIG["raw_tables"]:
        path = ROOT / "data" / src["file"]
        opts = src.get("read_csv", {})
        df = pd.read_csv(path, dtype=str, keep_default_na=False, **opts)
        df.columns = [re.sub(r"\W+", "_", c.replace("﻿", "").strip()).strip("_") for c in df.columns]
        df = df.replace({"": None})
        df.to_sql(src["table"], con, if_exists="replace", index=False, chunksize=20000)
        print(f"loaded {len(df):,} rows into {src['table']}")


def parse_blocks(sql_text):
    """Split an analysis file into tagged query blocks."""
    blocks = []
    for chunk in re.split(r"(?m)^(?=-- @name:)", sql_text):
        if not chunk.startswith("-- @name:"):
            continue
        meta, body = {}, []
        for line in chunk.splitlines():
            m = re.match(r"--\s*@(\w+):\s*(.*)", line)
            if m and not body:
                key, val = m.group(1), m.group(2).strip()
                meta[key] = (meta[key] + " " + val) if key in meta and key == "insight" else val
            else:
                body.append(line)
        sql = "\n".join(body).strip()
        sql = re.sub(r"(?s)\n?-- -{3,}.*$", "", sql).strip()  # drop trailing section separators
        meta["sql"] = sql
        blocks.append(meta)
    return blocks


def parse_chart(spec):
    parts = spec.split()
    chart = {"type": parts[0]}
    for p in parts[1:]:
        k, v = p.split("=", 1)
        chart[k] = v.split(",") if k in ("y", "money", "pct") else v
    return chart


def main():
    DB_PATH.parent.mkdir(exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    con = sqlite3.connect(DB_PATH)
    load_raw(con)

    panels = []
    results_dir = ROOT / "results"
    results_dir.mkdir(exist_ok=True)
    for f in sorted((ROOT / "sql").glob("0*_*.sql")):
        text = f.read_text(encoding="utf-8")
        blocks = parse_blocks(text)
        if not blocks:  # cleaning / setup script
            con.executescript(text)
            con.commit()
            print(f"ran {f.name}")
            continue
        for b in blocks:
            df = pd.read_sql_query(b["sql"].rstrip(";"), con)
            df.to_csv(results_dir / f"{b['name']}.csv", index=False)
            panels.append({
                "name": b["name"],
                "section": b.get("section", ""),
                "title": b.get("title", b["name"]),
                "insight": b.get("insight", ""),
                "chart": parse_chart(b.get("chart", "table")),
                "sql": b["sql"],
                "columns": list(df.columns),
                "rows": json.loads(df.to_json(orient="values")),
            })
            print(f"  {b['name']}: {len(df)} rows")
    con.close()

    payload = {k: CONFIG[k] for k in ("title", "subtitle", "dataset", "author", "repo", "currency", "stack") if k in CONFIG}
    payload["panels"] = panels
    template = (ROOT / "scripts" / "dashboard_template.html").read_text(encoding="utf-8")
    html = template.replace("/*__DATA__*/null", json.dumps(payload, ensure_ascii=False).replace("</", "<\\/"))
    html = html.replace("__TITLE__", CONFIG["title"])
    (ROOT / "docs").mkdir(exist_ok=True)
    (ROOT / "docs" / "index.html").write_text(html, encoding="utf-8")
    print("dashboard written to docs/index.html")


if __name__ == "__main__":
    main()
