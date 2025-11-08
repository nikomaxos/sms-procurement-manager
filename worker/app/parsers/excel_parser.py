import io
import pandas as pd

def read_pricelist_bytes(data: bytes, filename: str) -> pd.DataFrame:
    name = filename.lower()
    if name.endswith(".csv"):
        return pd.read_csv(io.BytesIO(data), dtype=str, keep_default_na=False)
    if name.endswith(".xlsx") or name.endswith(".xls"):
        return pd.read_excel(io.BytesIO(data), dtype=str)
    raise ValueError(f"Unsupported file: {filename}")

def normalize_columns(df: pd.DataFrame):
    df.columns = [str(c).strip().lower() for c in df.columns]
    return df
