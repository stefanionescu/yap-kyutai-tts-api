#!/bin/bash
set -euo pipefail

# Build and push Yap Kyutai TTS Docker image
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# From docker/scripts → repo root
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Default values
DOCKER_REPO="${DOCKER_REPO:-sionescu/kyutai-tts}"
TAG="${TAG:-latest}"
PUSH="${PUSH:-true}"

echo "Building Yap Kyutai TTS Docker image..."
echo "Repository: $DOCKER_REPO"
echo "Tag: $TAG"
echo "Push to hub: $PUSH"

# Build the image for x86_64 (cloud providers)
cd "$REPO_ROOT"
docker build --platform linux/amd64 -f docker/Dockerfile -t "$DOCKER_REPO:$TAG" .

if [ "$PUSH" = "true" ]; then
    echo "Pushing to Docker Hub..."
    docker push "$DOCKER_REPO:$TAG"
    echo "✅ Image pushed: $DOCKER_REPO:$TAG"
else
    echo "✅ Image built locally: $DOCKER_REPO:$TAG"
    echo "To push: PUSH=true ./docker/build.sh"
fi

echo ""
echo "🚀 To run locally:"
echo "docker run --gpus all -p 8089:8089 -e HUGGING_FACE_HUB_TOKEN=\$HF_TOKEN $DOCKER_REPO:$TAG"
echo ""
echo "🌐 To use in RunPod:"
echo "1. Use image: $DOCKER_REPO:$TAG"
echo "2. Set environment: HUGGING_FACE_HUB_TOKEN"
echo "3. Expose port: 8089"
echo "4. Test: curl http://localhost:8089/api/build_info"
