"""
Cloud Functions (gen2) HTTP entrypoint for the Reporter agent (GCP track).
Coexists with lambda_handler.py (AWS Lambda).
The Cloud Functions buildpack picks this file because the terraform
build_config sets GOOGLE_FUNCTION_SOURCE=main_gcp.py and entry_point=handler.

Env (set by terraform/6_agents_gcp/main.tf):
  CLOUD_PROVIDER, VERTEX_PROJECT, VERTEX_LOCATION, MODEL_ID,
  CLOUDSQL_CONNECTION_NAME, DB_SECRET_NAME
"""

import json
import asyncio
import logging

import functions_framework

import os
try:
    from agents import set_tracing_export_api_key
    if _key := os.environ.get("OPENAI_API_KEY"):
        set_tracing_export_api_key(_key)
except Exception:
    pass

from src import Database
from lambda_handler import run_reporter_agent
from observability import observe

logger = logging.getLogger()
logger.setLevel(logging.INFO)


@functions_framework.http
def handler(request):
    """HTTP Cloud Function entrypoint for the Reporter agent."""
    if request.method != "POST":
        return ({"error": "POST only"}, 405)

    with observe() as observability:
        try:
            event = request.get_json(silent=True) or {}
            logger.info(f"Reporter Cloud Function invoked with event: {json.dumps(event)[:500]}")

            if isinstance(event, str):
                event = json.loads(event)

            job_id = event.get("job_id")
            if not job_id:
                return ({"error": "job_id is required"}, 400)

            db = Database()

            portfolio_data = event.get("portfolio_data")
            if not portfolio_data:
                job = db.jobs.find_by_id(job_id)
                if not job:
                    return ({"error": f"Job {job_id} not found"}, 404)

                user_id = job["clerk_user_id"]
                user = db.users.find_by_clerk_id(user_id)
                accounts = db.accounts.find_by_user(user_id)

                portfolio_data = {"user_id": user_id, "job_id": job_id, "accounts": []}
                for account in accounts:
                    positions = db.positions.find_by_account(account["id"])
                    account_data = {
                        "id": account["id"],
                        "name": account["account_name"],
                        "type": account.get("account_type", "investment"),
                        "cash_balance": float(account.get("cash_balance", 0)),
                        "positions": [],
                    }
                    for position in positions:
                        instrument = db.instruments.find_by_symbol(position["symbol"])
                        if instrument:
                            account_data["positions"].append(
                                {
                                    "symbol": position["symbol"],
                                    "quantity": float(position["quantity"]),
                                    "instrument": instrument,
                                }
                            )
                    portfolio_data["accounts"].append(account_data)

            user_data = event.get("user_data", {})
            if not user_data:
                job = db.jobs.find_by_id(job_id)
                if job and job.get("clerk_user_id"):
                    user = db.users.find_by_clerk_id(job["clerk_user_id"])
                    if user:
                        user_data = {
                            "years_until_retirement": user.get("years_until_retirement", 30),
                            "target_retirement_income": float(
                                user.get("target_retirement_income", 80000)
                            ),
                        }
                    else:
                        user_data = {"years_until_retirement": 30, "target_retirement_income": 80000}
                else:
                    user_data = {"years_until_retirement": 30, "target_retirement_income": 80000}

            result = asyncio.run(
                run_reporter_agent(job_id, portfolio_data, user_data, db, observability)
            )

            logger.info(f"Reporter completed for job {job_id}")

            return (
                result,
                200,
                {"Content-Type": "application/json"},
            )

        except Exception as e:
            logger.error(f"Reporter: Error in Cloud Function handler: {e}", exc_info=True)
            return (
                {"success": False, "error": str(e)},
                500,
                {"Content-Type": "application/json"},
            )
