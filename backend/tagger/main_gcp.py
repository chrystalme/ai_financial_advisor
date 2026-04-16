"""
Cloud Functions (gen2) HTTP entrypoint for the Tagger agent (GCP track).
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

from lambda_handler import process_instruments
from observability import observe

logger = logging.getLogger()
logger.setLevel(logging.INFO)


@functions_framework.http
def handler(request):
    """HTTP Cloud Function entrypoint for the Tagger agent."""
    if request.method != "POST":
        return ({"error": "POST only"}, 405)

    with observe():
        try:
            event = request.get_json(silent=True) or {}
            logger.info(f"Tagger Cloud Function invoked")

            instruments = event.get("instruments", [])
            if not instruments:
                return ({"error": "No instruments provided"}, 400)

            result = asyncio.run(process_instruments(instruments))

            return (
                result,
                200,
                {"Content-Type": "application/json"},
            )

        except Exception as e:
            logger.error(f"Tagger: Error in Cloud Function handler: {e}", exc_info=True)
            return (
                {"error": str(e)},
                500,
                {"Content-Type": "application/json"},
            )
