#!/usr/bin/env bash
# deploy.sh — Build, push, and configure the scraper as a Cloud Run Job
#
# Prerequisites:
#   gcloud CLI installed and authenticated:
#     gcloud auth login
#     gcloud config set project tennis-app-mp-2026
#     gcloud auth configure-docker
#
#   IAM roles needed on your account:
#     - Cloud Run Admin
#     - Cloud Scheduler Admin
#     - Cloud Build Editor
#     - Storage Admin (Cloud Build uses GCS for build artifacts)
#     - Service Account User (on the job's service account)
#     - Artifact Registry Writer (or Container Registry Writer)
#
# Usage:
#   ./deploy.sh              # full deploy (build + push + create/update job + scheduler)
#   ./deploy.sh --run-now    # same, then immediately trigger one execution

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit these if needed
# ---------------------------------------------------------------------------
PROJECT_ID="tennis-app-mp-2026"
REGION="us-central1"
REPO="scraper"                          # Artifact Registry repo name
IMAGE_NAME="league-scraper"
JOB_NAME="league-scraper"
SERVICE_ACCOUNT="scraper-job@${PROJECT_ID}.iam.gserviceaccount.com"

# Cron: every Monday at 06:00 UTC (after weekend matches are posted)
SCHEDULE="0 6 * * 1"
TIMEZONE="America/New_York"

IMAGE_TAG="gcr.io/${PROJECT_ID}/${IMAGE_NAME}:latest"
# Use Artifact Registry instead of GCR if you prefer:
# IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE_NAME}:latest"

RUN_NOW=${1:-""}

# ---------------------------------------------------------------------------
# 1. Enable required APIs (idempotent)
# ---------------------------------------------------------------------------
echo "▶ Enabling APIs..."
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  containerregistry.googleapis.com \
  --project="${PROJECT_ID}" \
  --quiet

# ---------------------------------------------------------------------------
# 2. Create service account if it doesn't exist
# ---------------------------------------------------------------------------
echo "▶ Ensuring service account exists..."
if ! gcloud iam service-accounts describe "${SERVICE_ACCOUNT}" \
    --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "scraper-job" \
    --display-name="League Scraper Cloud Run Job" \
    --project="${PROJECT_ID}"
fi

# Grant it Firestore read/write
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/datastore.user" \
  --quiet

# ---------------------------------------------------------------------------
# 3. Build and push image via Cloud Build (no local Docker required)
# ---------------------------------------------------------------------------
echo "▶ Building and pushing image via Cloud Build..."
gcloud builds submit . \
  --tag="${IMAGE_TAG}" \
  --project="${PROJECT_ID}" \
  --quiet

# ---------------------------------------------------------------------------
# 4. Create or update the Cloud Run Job
# ---------------------------------------------------------------------------
echo "▶ Deploying Cloud Run Job '${JOB_NAME}'..."
gcloud run jobs deploy "${JOB_NAME}" \
  --image="${IMAGE_TAG}" \
  --region="${REGION}" \
  --service-account="${SERVICE_ACCOUNT}" \
  --set-env-vars="FIREBASE_PROJECT_ID=${PROJECT_ID},MATCH_THRESHOLD=75,LOG_LEVEL=INFO" \
  --max-retries=3 \
  --task-timeout=1800 \
  --project="${PROJECT_ID}" \
  --quiet

JOB_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"

# ---------------------------------------------------------------------------
# 5. Create or update the Cloud Scheduler job
# ---------------------------------------------------------------------------
echo "▶ Configuring Cloud Scheduler (${SCHEDULE} ${TIMEZONE})..."

SCHEDULER_SA="${SERVICE_ACCOUNT}"

# Grant the scheduler SA permission to invoke the Cloud Run job
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SCHEDULER_SA}" \
  --role="roles/run.invoker" \
  --quiet

if gcloud scheduler jobs describe "${JOB_NAME}-trigger" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" &>/dev/null; then
  gcloud scheduler jobs update http "${JOB_NAME}-trigger" \
    --location="${REGION}" \
    --schedule="${SCHEDULE}" \
    --time-zone="${TIMEZONE}" \
    --uri="${JOB_URI}" \
    --message-body='{}' \
    --oauth-service-account-email="${SCHEDULER_SA}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  gcloud scheduler jobs create http "${JOB_NAME}-trigger" \
    --location="${REGION}" \
    --schedule="${SCHEDULE}" \
    --time-zone="${TIMEZONE}" \
    --uri="${JOB_URI}" \
    --message-body='{}' \
    --oauth-service-account-email="${SCHEDULER_SA}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

echo "✓ Scheduler configured: ${SCHEDULE} (${TIMEZONE})"

# ---------------------------------------------------------------------------
# 6. Optionally run immediately
# ---------------------------------------------------------------------------
if [[ "${RUN_NOW}" == "--run-now" ]]; then
  echo "▶ Triggering immediate execution..."
  gcloud run jobs execute "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --wait
  echo "✓ Execution complete. Check Firestore 'scraper_runs' for results."
fi

echo ""
echo "✓ Deploy complete."
echo "  Job:       ${JOB_NAME} (${REGION})"
echo "  Schedule:  ${SCHEDULE} ${TIMEZONE}"
echo "  Image:     ${IMAGE_TAG}"
echo ""
echo "Monitor runs:"
echo "  gcloud run jobs executions list --job=${JOB_NAME} --region=${REGION} --project=${PROJECT_ID}"
echo "  gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=${JOB_NAME}' --project=${PROJECT_ID} --limit=50"
