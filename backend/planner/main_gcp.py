"""
Cloud Functions (gen2) HTTP entrypoint for the Planner agent (GCP track).
Coexists with lambda_handler.py (AWS Lambda).
The Cloud Functions buildpack picks this file because the terraform
build_config sets GOOGLE_FUNCTION_SOURCE=main_gcp.py and entry_point=handler.

Env (set by terraform/6_agents_gcp/main.tf):
  CLOUD_PROVIDER, VERTEX_PROJECT, VERTEX_LOCATION, MODEL_ID,
  CLOUDSQL_CONNECTION_NAME, DB_SECRET_NAME, PUBSUB_TOPIC
"""

import json
import asyncio
import logging

import functions_framework

from lambda_handler import run_orchestrator

logger = logging.getLogger()
logger.setLevel(logging.INFO)


@functions_framework.http
def handler(request):
    """HTTP Cloud Function entrypoint for the Planner orchestrator."""
    if request.method != "POST":
        return ({"error": "POST only"}, 405)

    try:
        event = request.get_json(silent=True) or {}
        logger.info(f"Planner Cloud Function invoked with event: {json.dumps(event)[:500]}")

        # Extract job_id - support both Pub/Sub push and direct invocation
        job_id = None

        # Check for Pub/Sub push message format
        if "message" in event:
            import base64
            data = event["message"].get("data", "")
            if data:
                decoded = base64.b64decode(data).decode("utf-8")
                try:
                    body = json.loads(decoded)
                    job_id = body.get("job_id", decoded)
                except json.JSONDecodeError:
                    job_id = decoded
        elif "job_id" in event:
            job_id = event["job_id"]

        if not job_id:
            return ({"error": "No job_id provided"}, 400)

        logger.info(f"Planner: Starting orchestration for job {job_id}")

        # Run the orchestrator (reuses the same async logic as Lambda)
        asyncio.run(run_orchestrator(job_id))

        return (
            {"success": True, "message": f"Analysis completed for job {job_id}"},
            200,
            {"Content-Type": "application/json"},
        )

    except Exception as e:
        logger.error(f"Planner: Error in Cloud Function handler: {e}", exc_info=True)
        return (
            {"success": False, "error": str(e)},
            500,
            {"Content-Type": "application/json"},
        )
