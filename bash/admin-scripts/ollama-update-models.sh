#!/usr/bin/env bash
# update-ollama-models.sh - Pull latest versions of all locally installed Ollama models

set -euo pipefail

# Check if ollama is available
if ! command -v ollama &> /dev/null; then
    echo "Error: 'ollama' command not found. Please install ollama first." >&2
    exit 1
fi

echo "Fetching list of installed models..."
# Extract model names from `ollama list`, skipping the header line
model_list=$(ollama list | awk 'NR>1 {print $1}')

if [[ -z "$model_list" ]]; then
    echo "No models found. Nothing to update."
    exit 0
fi

echo "The following models will be updated:"
echo "$model_list"
echo ""

# Loop through each model and pull the latest version
while IFS= read -r model; do
    echo "Updating model: $model"
    if ollama pull "$model"; then
        echo "Successfully updated: $model"
    else
        echo "Warning: Failed to update model: $model" >&2
    fi
    echo ""
done <<< "$model_list"

echo "All updates completed."