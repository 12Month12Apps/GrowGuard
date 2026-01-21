#!/usr/bin/env python3
"""Migrates the bundled flower.db SQLite database into a Supabase Postgres instance."""

from __future__ import annotations

import argparse
import os
import sqlite3
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Dict, List, Sequence, Tuple

import psycopg2
import psycopg2.extras
from psycopg2 import sql


@dataclass
class TableDefinition:
    name: str
    create_sql: str
    foreign_keys: List[str]


def fetch_sqlite_tables(sqlite_path: str) -> Tuple[List[str], Dict[str, TableDefinition]]:
    conn = sqlite3.connect(sqlite_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute(
        """
        SELECT name, sql
        FROM sqlite_master
        WHERE type = 'table'
          AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
    )
    tables: Dict[str, TableDefinition] = {}
    for row in cur.fetchall():
        table_name = row["name"]
        table_sql = row["sql"]
        fk_cursor = conn.execute(f"PRAGMA foreign_key_list('{table_name}')")
        fk_refs = {fk_row[2] for fk_row in fk_cursor.fetchall()}
        tables[table_name] = TableDefinition(
            name=table_name,
            create_sql=table_sql,
            foreign_keys=sorted(fk_refs),
        )

    conn.close()
    ordered_names = topological_sort_tables(tables)
    return ordered_names, tables


def topological_sort_tables(tables: Dict[str, TableDefinition]) -> List[str]:
    graph = defaultdict(set)
    inverse = defaultdict(set)
    for table, definition in tables.items():
        for dependency in definition.foreign_keys:
            graph[table].add(dependency)
            inverse[dependency].add(table)

    queue = deque([name for name in tables if not graph[name]])
    order = []
    seen = set()

    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        order.append(current)
        seen.add(current)
        for neighbor in inverse[current]:
            graph[neighbor].discard(current)
            if not graph[neighbor]:
                queue.append(neighbor)

    if len(order) != len(tables):
        remaining = set(tables).difference(order)
        order.extend(sorted(remaining))

    return order


def ensure_schema(cur, schema: str) -> None:
    cur.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {};").format(sql.Identifier(schema)))
    cur.execute(sql.SQL("SET search_path TO {};").format(sql.Identifier(schema)))


def drop_tables(cur, schema: str, table_order: Sequence[str]) -> None:
    for table in reversed(table_order):
        cur.execute(
            sql.SQL("DROP TABLE IF EXISTS {}.{} CASCADE;").format(
                sql.Identifier(schema), sql.Identifier(table)
            )
        )


def create_tables(cur, schema: str, table_order: Sequence[str], tables: Dict[str, TableDefinition]) -> None:
    ensure_schema(cur, schema)
    for table in table_order:
        cur.execute("SELECT to_regclass(%s)", (f"{schema}.{table}",))
        exists = cur.fetchone()[0] is not None
        if exists:
            continue
        create_sql = tables[table].create_sql
        if not create_sql:
            raise RuntimeError(f"Table {table} does not have a CREATE statement in sqlite_master")
        cur.execute(create_sql)


def truncate_tables(cur, schema: str, table_order: Sequence[str]) -> None:
    for table in reversed(table_order):
        cur.execute(
            sql.SQL("TRUNCATE TABLE {}.{} RESTART IDENTITY CASCADE;").format(
                sql.Identifier(schema), sql.Identifier(table)
            )
        )


def copy_table_data(
    sqlite_path: str,
    pg_conn,
    schema: str,
    table_order: Sequence[str],
) -> None:
    sqlite_conn = sqlite3.connect(sqlite_path)
    sqlite_conn.row_factory = sqlite3.Row
    sqlite_cur = sqlite_conn.cursor()

    with pg_conn.cursor() as pg_cur:
        ensure_schema(pg_cur, schema)

    for table in table_order:
        sqlite_cur.execute(f'SELECT * FROM "{table}"')
        rows = sqlite_cur.fetchall()
        if not rows:
            continue

        column_names = rows[0].keys()
        values = [tuple(row[col] for col in column_names) for row in rows]
        quoted_columns = ", ".join(f'"{col}"' for col in column_names)
        placeholder_sql = ", ".join(["%s"] * len(column_names))
        insert_sql = f'INSERT INTO "{schema}"."{table}" ({quoted_columns}) VALUES ({placeholder_sql})'
        with pg_conn.cursor() as pg_cur:
            psycopg2.extras.execute_batch(pg_cur, insert_sql, values, page_size=500)

    sqlite_conn.close()



def migrate(sqlite_path: str, pg_dsn: str, schema: str, recreate: bool, truncate: bool) -> None:
    table_order, table_definitions = fetch_sqlite_tables(sqlite_path)
    pg_conn = psycopg2.connect(pg_dsn)
    pg_conn.autocommit = False

    try:
        with pg_conn.cursor() as cur:
            ensure_schema(cur, schema)
            if recreate:
                drop_tables(cur, schema, table_order)
                create_tables(cur, schema, table_order, table_definitions)
            else:
                create_tables(cur, schema, table_order, table_definitions)
            if truncate and not recreate:
                truncate_tables(cur, schema, table_order)
        copy_table_data(sqlite_path, pg_conn, schema, table_order)
        pg_conn.commit()
    except Exception:
        pg_conn.rollback()
        raise
    finally:
        pg_conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Migrate GrowGuard's flower.db into Supabase Postgres")
    parser.add_argument(
        "--sqlite-path",
        default="GrowGuard/flower.db",
        help="Path to the source SQLite database (defaults to GrowGuard/flower.db)",
    )
    parser.add_argument(
        "--pg-dsn",
        default=os.getenv("SUPABASE_DB_URL"),
        help="Postgres DSN/URL, e.g. postgres://user:pass@host:6543/postgres",
    )
    parser.add_argument(
        "--schema",
        default=os.getenv("SUPABASE_SCHEMA", "public"),
        help="Target schema inside Supabase (default: public)",
    )
    parser.add_argument(
        "--recreate",
        action="store_true",
        help="Drop and recreate tables before inserting data",
    )
    parser.add_argument(
        "--truncate",
        action="store_true",
        help="Truncate tables (and reset identities) before inserting",
    )
    args = parser.parse_args()

    if not args.pg_dsn:
        raise SystemExit("Missing Postgres connection string. Pass --pg-dsn or set SUPABASE_DB_URL")

    migrate(
        sqlite_path=args.sqlite_path,
        pg_dsn=args.pg_dsn,
        schema=args.schema,
        recreate=args.recreate,
        truncate=args.truncate,
    )


if __name__ == "__main__":
    main()
