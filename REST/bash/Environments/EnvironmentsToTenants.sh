#!/usr/bin/env bash
set -euo pipefail

# Define working variables
octopusUrl="https://tam.octopus.app"
octopusApiKey=${OCTOPUS_TAM_API_KEY}
spaceName="Applied"
projectName="Parallel"

# Provide target environment names; one tenant will be created per environment.
environmentNames=("Dev-CA" "Dev-OR" "Dev-WA")

# Optional tenant tags to apply to all generated tenants.
tenantTags=("Env/Dev" "Region/Pacific")

deleteEnvironments=false

usage() {
  cat <<'EOF'
Usage: $(basename "$0") [-u octopusUrl] [-s spaceName] [-p projectName] [-e environmentNames] [-t tenantTags] [-d deleteEnvironments] [-h]

Create one tenant for each environment listed in environmentNames.

Options:
  -u octopusUrl     Override the default Octopus server URL.
  -s spaceName      Override the default space name.
  -p projectName    Override the default project name.
  -e environmentNames
                    Comma-separated list of environment names to create tenants for.
  -t tenantTags     Comma-separated list of tenant tags to apply to each created tenant.
  -d deleteEnvironments
                    Delete environments after successful tenant creation when set to true or 1.
  -h                Show this help message and exit.
EOF
}

while getopts ":u:s:p:e:t:d:h" opt; do
  case "$opt" in
    u) octopusUrl="$OPTARG" ;;
    s) spaceName="$OPTARG" ;;
    p) projectName="$OPTARG" ;;
    e)
      IFS=',' read -r -a environmentNames <<< "$OPTARG"
      ;;
    t)
      IFS=',' read -r -a tenantTags <<< "$OPTARG"
      ;;
    d)
      delete_value=$(printf '%s' "$OPTARG" | tr '[:upper:]' '[:lower:]')
      case "$delete_value" in
        true|1)
          deleteEnvironments=true
          ;;
        false|0)
          deleteEnvironments=false
          ;;
        *)
          echo "Error: -d value must be true, false, 1, or 0." >&2
          usage
          exit 1
          ;;
      esac
      ;;
    h)
      usage
      exit 0
      ;;
    :) echo "Error: -$OPTARG requires an argument." >&2
       usage
       exit 1
      ;;
    \?) echo "Error: invalid option: -$OPTARG" >&2
       usage
       exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

# Utility: convert bash array to JSON array for jq.
array_to_json() {
  if [ $# -eq 0 ]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

contains_element() {
  local needle="$1"
  shift
  local item
  if [ $# -eq 0 ]; then
    return 1
  fi

  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done

  return 1
}

contains_element_in_multiline() {
  local needle="$1"
  local haystack="$2"
  local item

  while IFS= read -r item; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done <<EOF
$haystack
EOF

  return 1
}

ensure_tagset_tags() {
  local tagsetName="$1"
  local desiredTags=()
  local fullTag
  local tagName

  for fullTag in "${tenantTags[@]}"; do
    if [ "${fullTag%%/*}" = "$tagsetName" ]; then
      tagName="${fullTag#*/}"
      desiredTags+=("$tagName")
    fi
  done

  local encodedName
  encodedName=$(printf '%s' "$tagsetName" | jq -sRr @uri)
  local tagset_response
  tagset_response=$(curl -s -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/tagsets?partialName=$encodedName")
  local tagset_id
  tagset_id=$(echo "$tagset_response" | jq -r --arg name "$tagsetName" '.Items[] | select(.Name==$name) | .Id' | head -n 1)

  if [ -z "$tagset_id" ] || [ "$tagset_id" = "null" ]; then
    printf 'Creating tagset %s with tags: %s\n' "$tagsetName" "${desiredTags[*]}"
    local tags_json
    tags_json=$(printf '%s\n' "${desiredTags[@]}" | jq -R . | jq -s 'map({Id: null, Name: ., Color: "", Description: "", CanonicalTagName: null})')
    local payload
    payload=$(jq -n --arg name "$tagsetName" --arg desc "Created by script" --argjson tags "$tags_json" '{Name: $name, Description: $desc, Tags: $tags}')
    curl -s -S -X POST -H "X-Octopus-ApiKey: $octopusApiKey" -H "Content-Type: application/json" "$octopusUrl/api/$space_id/tagsets" -d "$payload" >/dev/null
    return
  fi

  local current_tags
  current_tags=$(curl -s -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/tagsets/$tagset_id" | jq -r '.Tags[].Name')
  local missingTags=()
  for tagName in "${desiredTags[@]}"; do
    if ! contains_element_in_multiline "$tagName" "$current_tags"; then
      missingTags+=("$tagName")
    fi
  done

  if [ ${#missingTags[@]} -eq 0 ]; then
    printf 'Tagset %s already contains all tenant tags\n' "$tagsetName"
    return
  fi

  printf 'Adding missing tags to tagset %s: %s\n' "$tagsetName" "${missingTags[*]}"
  local new_tags_json
  new_tags_json=$(printf '%s\n' "${missingTags[@]}" | jq -R . | jq -s 'map({Id: null, Name: ., Color: "", Description: "", CanonicalTagName: null})')
  local updated_payload
  updated_payload=$(curl -s -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/tagsets/$tagset_id" | jq --argjson newTags "$new_tags_json" '.Tags += $newTags')
  curl -s -S -X PUT -H "X-Octopus-ApiKey: $octopusApiKey" -H "Content-Type: application/json" "$octopusUrl/api/$space_id/tagsets/$tagset_id" -d "$updated_payload" >/dev/null
}

ensure_tagsets_exist() {
  local uniqueTagsets=()
  local fullTag
  local tagsetName

  for fullTag in "${tenantTags[@]}"; do
    if [[ "$fullTag" != */* ]]; then
      echo "ERROR: tenant tag '$fullTag' must be in TagSet/Tag format" >&2
      exit 1
    fi
    tagsetName="${fullTag%%/*}"
    if ! contains_element "$tagsetName" "${uniqueTagsets[@]}"; then
      uniqueTagsets+=("$tagsetName")
    fi
  done

  for tagsetName in "${uniqueTagsets[@]}"; do
    ensure_tagset_tags "$tagsetName"
  done
}

# Get space
printf 'Getting space %s\n' "$spaceName"
spaces=$(curl -s -H "X-Octopus-ApiKey: $octopusApiKey" -X GET "$octopusUrl/api/spaces" -G --data-urlencode "partialName=$spaceName")
space_id=$(echo "$spaces" | jq -r ".Items[] | select(.Name==\"${spaceName}\") | .Id")
if [ -z "$space_id" ] || [ "$space_id" == "null" ]; then
  echo "ERROR: space '$spaceName' not found"
  exit 1
fi

# Get project
printf 'Getting project %s\n' "$projectName"
project=$(curl -s -L -X GET -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/projects?skip=0&take=1" -G --data-urlencode "partialName=$projectName" -H "accept: application/json")
project_id=$(echo "$project" | jq -r 'first(.Items[]).Id')
if [ -z "$project_id" ] || [ "$project_id" == "null" ]; then
  echo "ERROR: project '$projectName' not found in space '$spaceName'"
  exit 1
fi

if [ ${#tenantTags[@]} -gt 0 ]; then
  printf 'Ensuring tenant tagsets and tags exist\n'
  ensure_tagsets_exist
fi

# Get all existing tenants once so we can skip duplicate names.
printf 'Fetching existing tenants in space %s\n' "$spaceName"
tenants=$(curl -s -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/tenants/all")

tenant_tags_json=$(array_to_json "${tenantTags[@]}")

for environmentName in "${environmentNames[@]}"; do
  printf '\nProcessing environment: %s\n' "$environmentName"

  existingTenantId=$(echo "$tenants" | jq -r --arg name "$environmentName" '.[] | select(.Name==$name) | .Id' | head -n 1)
  if [ -n "$existingTenantId" ]; then
    echo "Skipping creation: tenant already exists with name '$environmentName' (ID: $existingTenantId)"
    continue
  fi

  printf 'Resolving environment %s\n' "$environmentName"
  environment=$(curl -s -L -X GET -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/environments?skip=0&take=1" -G --data-urlencode "partialName=$environmentName" -H "accept: application/json" | jq 'first(.Items[])' -r)
  environment_id=$(echo "$environment" | jq -r .Id)

  if [ -z "$environment_id" ] || [ "$environment_id" == "null" ]; then
    echo "WARNING: environment '$environmentName' not found; skipping"
    continue
  fi

  printf 'Creating tenant for environment %s (ID: %s)\n' "$environmentName" "$environment_id"

  project_environments=$(jq -n --arg projectId "$project_id" --arg environmentId "$environment_id" '{($projectId): [$environmentId]}')
  tenant_payload=$(jq -n \
    --arg name "$environmentName" \
    --arg spaceId "$space_id" \
    --argjson tenantTags "$tenant_tags_json" \
    --argjson projectEnvironments "$project_environments" \
    '{Name: $name, SpaceId: $spaceId, TenantTags: $tenantTags, ProjectEnvironments: $projectEnvironments}')

  response=$(curl -s -S -X POST -H "X-Octopus-ApiKey: $octopusApiKey" -H "Content-Type: application/json" "$octopusUrl/api/$space_id/tenants" -d "$tenant_payload")
  echo "Tenant creation response for '$environmentName':"
  echo "$response" | jq .

  if [ "$deleteEnvironments" = true ]; then
    printf 'Deleting environment %s (ID: %s)\n' "$environmentName" "$environment_id"
    delete_response=$(curl -s -S -X DELETE -H "X-Octopus-ApiKey: $octopusApiKey" "$octopusUrl/api/$space_id/environments/$environment_id")
    echo "Delete response for environment '$environmentName':"
    echo "$delete_response" | jq .
  fi
done
