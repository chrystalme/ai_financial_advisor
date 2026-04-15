"""
Cloud Functions (gen2) HTTP entrypoint for the GCP track.
Coexists with `ingest_s3vectors.py` (AWS Lambda) and a future Azure entrypoint.
The Cloud Functions buildpack picks this file because the terraform
build_config sets GOOGLE_FUNCTION_SOURCE=main_gcp.py and entry_point=handler.

Env (set by terraform/3_ingestion_gcp/main.tf):
  GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_REGION
  VECTOR_INDEX_ID                (full resource name)
  VECTOR_INDEX_ENDPOINT_ID       (full resource name)
  DEPLOYED_INDEX_ID              (short id, e.g. alex_docs_v1)
  EMBEDDING_MODEL                (default: text-embedding-005)
"""

import os
import uuid
from functools import lru_cache

import functions_framework
from google import genai
from google.cloud import aiplatform_v1

PROJECT = os.environ["GOOGLE_CLOUD_PROJECT"]
REGION = os.environ["GOOGLE_CLOUD_REGION"]
INDEX = os.environ["VECTOR_INDEX_ID"]
INDEX_ENDPOINT = os.environ["VECTOR_INDEX_ENDPOINT_ID"]
DEPLOYED_INDEX_ID = os.environ["DEPLOYED_INDEX_ID"]
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "text-embedding-005")

API_ENDPOINT = f"{REGION}-aiplatform.googleapis.com"
CLIENT_OPTIONS = {"api_endpoint": API_ENDPOINT}


@lru_cache(maxsize=1)
def _genai_client():
    return genai.Client(vertexai=True, project=PROJECT, location=REGION)


@lru_cache(maxsize=1)
def _index_client():
    return aiplatform_v1.IndexServiceClient(client_options=CLIENT_OPTIONS)


@lru_cache(maxsize=1)
def _match_client():
    # Query path uses the deployed endpoint's dedicated public domain, not the
    # regional API endpoint — resolve it once per instance.
    ep_client = aiplatform_v1.IndexEndpointServiceClient(client_options=CLIENT_OPTIONS)
    ep = ep_client.get_index_endpoint(name=INDEX_ENDPOINT)
    public_domain = ep.public_endpoint_domain_name
    if not public_domain:
        raise RuntimeError(
            "Index endpoint has no public domain — is the index deployed?"
        )
    return aiplatform_v1.MatchServiceClient(
        client_options={"api_endpoint": public_domain}
    )


def _embed(texts):
    r = _genai_client().models.embed_content(model=EMBEDDING_MODEL, contents=texts)
    return [e.values for e in r.embeddings]


def _ingest(payload):
    text = payload.get("text")
    if not text:
        return {"error": "text is required"}, 400
    doc_id = payload.get("document_id") or str(uuid.uuid4())
    metadata = payload.get("metadata") or {}

    [vec] = _embed([text])

    restricts = [
        aiplatform_v1.IndexDatapoint.Restriction(namespace=k, allow_list=[str(v)])
        for k, v in metadata.items()
        if isinstance(v, (str, int, float))
    ]
    dp = aiplatform_v1.IndexDatapoint(
        datapoint_id=doc_id, feature_vector=vec, restricts=restricts
    )
    _index_client().upsert_datapoints(
        request=aiplatform_v1.UpsertDatapointsRequest(index=INDEX, datapoints=[dp])
    )
    return {"document_id": doc_id, "dimensions": len(vec)}, 200


def _search(payload):
    query = payload.get("query")
    if not query:
        return {"error": "query is required"}, 400
    top_k = int(payload.get("top_k", 5))

    [vec] = _embed([query])

    req = aiplatform_v1.FindNeighborsRequest(
        index_endpoint=INDEX_ENDPOINT,
        deployed_index_id=DEPLOYED_INDEX_ID,
        queries=[
            aiplatform_v1.FindNeighborsRequest.Query(
                datapoint=aiplatform_v1.IndexDatapoint(feature_vector=vec),
                neighbor_count=top_k,
            )
        ],
    )
    resp = _match_client().find_neighbors(req)
    hits = [
        {"id": n.datapoint.datapoint_id, "distance": n.distance}
        for n in resp.nearest_neighbors[0].neighbors
    ]
    return {"query": query, "hits": hits}, 200


@functions_framework.http
def handler(request):
    if request.method != "POST":
        return ({"error": "POST only"}, 405)

    path = (request.path or "").rstrip("/")
    payload = request.get_json(silent=True) or {}

    if path.endswith("/ingest"):
        body, status = _ingest(payload)
    elif path.endswith("/search"):
        body, status = _search(payload)
    else:
        body, status = {"error": f"unknown path: {path}"}, 404

    return (body, status, {"Content-Type": "application/json"})
