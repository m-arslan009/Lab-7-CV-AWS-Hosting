"""S3-backed Function URL handler. Proposed source; deployment is unverified."""

import base64
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/cv.pdf": ("cv.pdf", "application/pdf"),
}


def lambda_handler(event, context):
    started = time.perf_counter()
    path = event.get("rawPath") or event.get("requestContext", {}).get("http", {}).get("path", "/")
    fn = getattr(context, "function_name", None) or "cv-func-23l-3025"
    response = {"statusCode": 500, "headers": {"Content-Type": "text/plain; charset=utf-8"},
                "body": "Internal server error", "isBase64Encoded": False}
    try:
        if path not in ROUTES:
            response.update(statusCode=404, body="<!doctype html><html><body><h1>404 Not found</h1></body></html>")
            response["headers"]["Content-Type"] = "text/html; charset=utf-8"
        else:
            filename, content_type = ROUTES[path]
            bucket = os.environ["BUCKET"]
            prefix = os.environ["PREFIX"].strip("/")
            key = f"{prefix}/{filename}" if prefix else filename
            obj = s3.get_object(Bucket=bucket, Key=key)
            stream = obj["Body"]
            try:
                data = stream.read()
            finally:
                stream.close()
            binary = filename == "cv.pdf"
            if binary:
                body = base64.b64encode(data).decode("ascii")
            else:
                body = data.decode("utf-8")
                if filename == "index.html":
                    body = body.replace("{{HOSTED_ON}}", "Lambda cv-func-23l-3025")
            response.update(statusCode=200, body=body, isBase64Encoded=binary)
            response["headers"] = {"Content-Type": content_type}
            if filename == "index.html":
                response["headers"]["Cache-Control"] = "max-age=60"
    except ClientError as exc:
        # Without ListBucket, S3 may return AccessDenied for missing objects.
        if exc.response.get("Error", {}).get("Code") in {"NoSuchKey", "NotFound", "404"}:
            response.update(statusCode=404, body="<!doctype html><html><body><h1>404 Not found</h1></body></html>")
            response["headers"]["Content-Type"] = "text/html; charset=utf-8"
    except Exception:
        # Keep internal errors out of the public response; log one request record.
        pass
    finally:
        print(json.dumps({"fn": fn, "path": path, "status": response["statusCode"],
                          "ms": round((time.perf_counter() - started) * 1000, 3)}))
    return response
