"""
Cloud SQL Client — provides the same interface as DataAPIClient (client.py)
but connects via psycopg through the Cloud SQL Auth Proxy Unix socket.

On Cloud Run / Cloud Functions the built-in proxy exposes a Unix socket at
/cloudsql/<CLOUDSQL_CONNECTION_NAME>.  Locally you run cloud-sql-proxy on
localhost:5432.
"""

import json
import os
import logging
from typing import List, Dict, Any, Optional
from datetime import date, datetime
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)


class _Pg8000Wrapper:
    """Wraps a pg8000 connection to provide the context-manager and cursor
    interface that the rest of this module expects (similar to psycopg)."""

    def __init__(self, conn):
        self._conn = conn
        self.autocommit = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if not any(exc):
            self._conn.commit()
        self._conn.close()

    def cursor(self):
        return _Pg8000CursorWrapper(self._conn.cursor())

    def close(self):
        self._conn.close()


class _Pg8000CursorWrapper:
    def __init__(self, cur):
        self._cur = cur
        self.description = None
        self.rowcount = -1

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        pass

    def execute(self, sql, params=None):
        if params and isinstance(params, dict):
            for k, v in params.items():
                sql = sql.replace(f"%({k})s", "%s")
            params = list(params.values())
        self._cur.execute(sql, params)
        self.description = self._cur.description
        self.rowcount = self._cur.rowcount

    def fetchall(self):
        rows = self._cur.fetchall()
        if self.description:
            cols = [d[0] for d in self.description]
            return [{c: v for c, v in zip(cols, row)} for row in rows]
        return rows

    def fetchone(self):
        row = self._cur.fetchone()
        if row and self.description:
            cols = [d[0] for d in self.description]
            return {c: v for c, v in zip(cols, row)}
        return row


class CloudSQLClient:
    """Drop-in replacement for DataAPIClient that uses psycopg + Cloud SQL."""

    def __init__(self, connection_name: str = None, db_name: str = None,
                 db_user: str = None, db_password: str = None):
        connection_name = connection_name or os.environ.get("CLOUDSQL_CONNECTION_NAME", "")
        db_name = db_name or os.environ.get("DB_NAME", "alex")
        db_user = db_user or os.environ.get("DB_USER", "alex_app")
        db_password = db_password or os.environ.get("DB_PASSWORD", "")

        if not db_password:
            secret_name = os.environ.get("DB_SECRET_NAME", "")
            if secret_name:
                db_password = self._load_secret(secret_name)

        self._db_name = db_name
        self._db_user = db_user
        self._db_password = db_password
        self._connection_name = connection_name

        socket_dir = f"/cloudsql/{connection_name}"
        if connection_name and os.path.exists("/cloudsql"):
            self._mode = "socket"
            self._conninfo = f"host={socket_dir} dbname={db_name} user={db_user} password={db_password}"
        elif connection_name and not os.environ.get("DB_HOST"):
            self._mode = "connector"
        else:
            self._mode = "tcp"
            host = os.environ.get("DB_HOST", "127.0.0.1")
            port = os.environ.get("DB_PORT", "5432")
            self._conninfo = f"host={host} port={port} dbname={db_name} user={db_user} password={db_password}"

        self.database = db_name

    @staticmethod
    def _load_secret(secret_name: str) -> str:
        from google.cloud import secretmanager
        client = secretmanager.SecretManagerServiceClient()
        project = os.environ.get("VERTEX_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT", "")
        name = f"projects/{project}/secrets/{secret_name}/versions/latest"
        response = client.access_secret_version(name=name)
        data = json.loads(response.payload.data.decode("utf-8"))
        return data.get("password", "")

    def _conn(self):
        if self._mode == "connector":
            from google.cloud.sql.connector import Connector
            connector = Connector()
            conn = connector.connect(
                self._connection_name,
                "pg8000",
                user=self._db_user,
                password=self._db_password,
                db=self._db_name,
            )
            return _Pg8000Wrapper(conn)
        return psycopg.connect(self._conninfo, row_factory=dict_row)

    # -- public interface (mirrors DataAPIClient) ----------------------------

    def execute(self, sql: str, parameters: List[Dict] = None) -> Dict:
        named, sql_pg = self._convert_params(sql, parameters)
        with self._conn() as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(sql_pg, named or None)
                result: Dict[str, Any] = {"numberOfRecordsUpdated": cur.rowcount}
                if cur.description:
                    result["columnMetadata"] = [{"name": d.name} for d in cur.description]
                    rows = cur.fetchall()
                    result["records"] = [self._row_to_record(row, cur.description) for row in rows]
                return result

    def query(self, sql: str, parameters: List[Dict] = None) -> List[Dict]:
        response = self.execute(sql, parameters)
        if "records" not in response:
            return []
        columns = [col["name"] for col in response.get("columnMetadata", [])]
        results = []
        for record in response["records"]:
            row = {}
            for i, col in enumerate(columns):
                row[col] = self._extract_value(record[i])
            results.append(row)
        return results

    def query_one(self, sql: str, parameters: List[Dict] = None) -> Optional[Dict]:
        results = self.query(sql, parameters)
        return results[0] if results else None

    def insert(self, table: str, data: Dict, returning: str = None) -> Any:
        columns = list(data.keys())
        placeholders = []
        for col in columns:
            if isinstance(data[col], (dict, list)):
                placeholders.append(f"%({col})s::jsonb")
            elif isinstance(data[col], Decimal):
                placeholders.append(f"%({col})s::numeric")
            elif isinstance(data[col], date) and not isinstance(data[col], datetime):
                placeholders.append(f"%({col})s::date")
            elif isinstance(data[col], datetime):
                placeholders.append(f"%({col})s::timestamp")
            else:
                placeholders.append(f"%({col})s")

        sql = f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join(placeholders)})"
        if returning:
            sql += f" RETURNING {returning}"

        params = self._data_to_psycopg(data)
        with self._conn() as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(sql, params)
                if returning and cur.description:
                    row = cur.fetchone()
                    return list(row.values())[0] if row else None
        return None

    def update(self, table: str, data: Dict, where: str, where_params: Dict = None) -> int:
        set_parts = []
        for col, val in data.items():
            if isinstance(val, (dict, list)):
                set_parts.append(f"{col} = %({col})s::jsonb")
            elif isinstance(val, Decimal):
                set_parts.append(f"{col} = %({col})s::numeric")
            elif isinstance(val, date) and not isinstance(val, datetime):
                set_parts.append(f"{col} = %({col})s::date")
            elif isinstance(val, datetime):
                set_parts.append(f"{col} = %({col})s::timestamp")
            else:
                set_parts.append(f"{col} = %({col})s")

        # Convert :param placeholders in the WHERE clause to %(param)s
        where_pg = where
        all_data = {**data, **(where_params or {})}
        for key in (where_params or {}):
            where_pg = where_pg.replace(f":{key}", f"%({key})s")

        sql = f"UPDATE {table} SET {', '.join(set_parts)} WHERE {where_pg}"
        params = self._data_to_psycopg(all_data)
        with self._conn() as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(sql, params)
                return cur.rowcount

    def delete(self, table: str, where: str, where_params: Dict = None) -> int:
        where_pg = where
        for key in (where_params or {}):
            where_pg = where_pg.replace(f":{key}", f"%({key})s")
        params = self._data_to_psycopg(where_params) if where_params else None
        sql = f"DELETE FROM {table} WHERE {where_pg}"
        with self._conn() as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(sql, params)
                return cur.rowcount

    # -- parameter conversion ------------------------------------------------

    @staticmethod
    def _convert_params(sql: str, parameters: List[Dict] = None):
        """Convert Data API params ([{'name':'x','value':{'stringValue':'v'}}])
        to psycopg named params (%(x)s) and rewrite :x placeholders in SQL."""
        if not parameters:
            return {}, sql
        named = {}
        for p in parameters:
            name = p["name"]
            val_dict = p.get("value", {})
            if val_dict.get("isNull"):
                named[name] = None
            elif "booleanValue" in val_dict:
                named[name] = val_dict["booleanValue"]
            elif "longValue" in val_dict:
                named[name] = val_dict["longValue"]
            elif "doubleValue" in val_dict:
                named[name] = val_dict["doubleValue"]
            elif "stringValue" in val_dict:
                named[name] = val_dict["stringValue"]
            else:
                named[name] = None
            sql = sql.replace(f":{name}", f"%({name})s")
        return named, sql

    @staticmethod
    def _data_to_psycopg(data: Dict) -> Dict:
        if not data:
            return {}
        out = {}
        for k, v in data.items():
            if isinstance(v, (dict, list)):
                out[k] = json.dumps(v)
            else:
                out[k] = v
        return out

    @staticmethod
    def _row_to_record(row: Dict, description) -> List[Dict]:
        """Convert a psycopg dict row to Data API record format."""
        record = []
        for desc in description:
            val = row[desc.name]
            if val is None:
                record.append({"isNull": True})
            elif isinstance(val, bool):
                record.append({"booleanValue": val})
            elif isinstance(val, int):
                record.append({"longValue": val})
            elif isinstance(val, float):
                record.append({"doubleValue": val})
            elif isinstance(val, Decimal):
                record.append({"stringValue": str(val)})
            elif isinstance(val, (date, datetime)):
                record.append({"stringValue": val.isoformat()})
            elif isinstance(val, (dict, list)):
                record.append({"stringValue": json.dumps(val)})
            else:
                record.append({"stringValue": str(val)})
        return record

    def _extract_value(self, field: Dict) -> Any:
        if field.get("isNull"):
            return None
        elif "booleanValue" in field:
            return field["booleanValue"]
        elif "longValue" in field:
            return field["longValue"]
        elif "doubleValue" in field:
            return field["doubleValue"]
        elif "stringValue" in field:
            value = field["stringValue"]
            if value and value[0] in ["{", "["]:
                try:
                    return json.loads(value)
                except json.JSONDecodeError:
                    pass
            return value
        return None
