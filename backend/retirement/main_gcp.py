"""
Cloud Functions (gen2) HTTP entrypoint for the Retirement agent (GCP track).
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

from src import Database
from lambda_handler import run_retirement_agent
from observability import observe

logger = logging.getLogger()
logger.setLevel(logging.INFO)


@functions_framework.http
def handler(request):
    """HTTP Cloud Function entrypoint for the Retirement agent."""
    if request.method != "POST":
        return ({"error": "POST only"}, 405)

    with observe():
        try:
            event = request.get_json(silent=True) or {}
            logger.info(f"Retirement Cloud Function invoked with event: {json.dumps(event)[:500]}")

            if isinstance(event, str):
                event = json.loads(event)

            job_id = event.get("job_id")
            if not job_id:
                return ({"error": "job_id is required"}, 400)

            portfolio_data = event.get("portfolio_data")
            if not portfolio_data:
                logger.info(f"Retirement: Loading portfolio data for job {job_id}")
                db = Database()
                job = db.jobs.find_by_id(job_id)
                if not job:
                    return ({"error": f"Job {job_id} not found"}, 404)

                user_id = job["clerk_user_id"]
                user = db.users.find_by_clerk_id(user_id)
                accounts = db.accounts.find_by_user(user_id)

                portfolio_data = {
                    "user_id": user_id,
                    "job_id": job_id,
                    "years_until_retirement": user.get("years_until_retirement", 30) if user else 30,
                    "accounts": [],
                }

                for account in accounts:
                    account_data = {
                        "id": account["id"],
                        "name": account["account_name"],
                        "type": account.get("account_type", "investment"),
                        "cash_balance": float(account.get("cash_balance", 0)),
                        "positions": [],
                    }
                    positions = db.positions.find_by_account(account["id"])
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

                logger.info(f"Retirement: Loaded {len(portfolio_data['accounts'])} accounts")

            result = asyncio.run(run_retirement_agent(job_id, portfolio_data))

            logger.info(f"Retirement completed for job {job_id}")

            return (
                result,
                200,
                {"Content-Type": "application/json"},
            )

        except Exception as e:
            logger.error(f"Retirement: Error in Cloud Function handler: {e}", exc_info=True)
            return (
                {"success": False, "error": str(e)},
                500,
                {"Content-Type": "application/json"},
            )
