"""
Olist 数据预处理脚本
====================
用途：把原始 CSV 转换为可直接被 MySQL LOAD DATA 导入的干净版本。

处理内容：
  1. 去除 UTF-8 BOM（否则首列名会带不可见字符）
  2. 将字段内嵌的换行符（\\r\\n / \\n / \\r）替换为空格
     —— 否则 LOAD DATA 会按行切分导致记录错位
  3. 统一输出 UTF-8 编码、LF 换行、标准 CSV 引号规则

输入：db-project/data/*.csv（原始文件，不做任何修改）
输出：db-project/data/import/*.csv（供导入使用）

运行：
  python 00_prepare_data.py
"""

import csv
import os
import sys

# 以脚本所在目录为基准，向上两级到 db-project
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(BASE_DIR, "data")
DST_DIR = os.path.join(BASE_DIR, "data", "import")

FILES = [
    "olist_customers_dataset.csv",
    "olist_geolocation_dataset.csv",
    "olist_order_items_dataset.csv",
    "olist_order_payments_dataset.csv",
    "olist_order_reviews_dataset.csv",
    "olist_orders_dataset.csv",
    "olist_products_dataset.csv",
    "olist_sellers_dataset.csv",
    "product_category_name_translation.csv",
]


def normalize(value: str) -> str:
    """把字段内的换行统一替换为单个空格。"""
    if "\n" in value or "\r" in value:
        return value.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    return value


def process(filename: str) -> None:
    src = os.path.join(SRC_DIR, filename)
    dst = os.path.join(DST_DIR, filename)

    if not os.path.exists(src):
        print(f"  [跳过] 找不到源文件: {filename}")
        return

    rows = 0
    fixed_newlines = 0

    # encoding='utf-8-sig' 会自动吃掉 BOM
    with open(src, encoding="utf-8-sig", newline="") as fh_in:
        reader = csv.reader(fh_in)
        header = next(reader)

        with open(dst, "w", encoding="utf-8", newline="") as fh_out:
            writer = csv.writer(
                fh_out,
                quoting=csv.QUOTE_MINIMAL,
                lineterminator="\n",
            )
            writer.writerow(header)

            for row in reader:
                cleaned = []
                for cell in row:
                    if "\n" in cell or "\r" in cell:
                        fixed_newlines += 1
                    cleaned.append(normalize(cell))
                writer.writerow(cleaned)
                rows += 1

    size_mb = os.path.getsize(dst) / 1024 / 1024
    extra = f"，修正内嵌换行 {fixed_newlines} 处" if fixed_newlines else ""
    print(f"  [完成] {filename:45s} {rows:>8d} 行  {size_mb:6.1f} MB{extra}")


def main() -> None:
    os.makedirs(DST_DIR, exist_ok=True)
    print("开始预处理...")
    print(f"源目录: {SRC_DIR}")
    print(f"输出:   {DST_DIR}")
    print("-" * 78)
    for f in FILES:
        process(f)
    print("-" * 78)
    print("预处理完成。原始文件未做任何修改。")


if __name__ == "__main__":
    main()
