#!/usr/bin/env zsh
# shellcheck disable=SC2296

# RECOVERY LOCK ROTATION

# Copyright 2026 Inetum Polska Sp. z o.o.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Author: Bartłomiej Sojka

# Jamf Pro Recovery Lock rotation — zsh (Ubuntu with zsh installed, or macOS)
# Required: JAMF_URL, JAMF_CLIENT_ID, JAMF_CLIENT_SECRET
# Optional: ROTATION_SCOPE=all, DRY_RUN=false, LOG_LEVEL=info
# Optional: WORDLIST_PATH, WORD_COUNT=4, DELIMITER=-
# Optional: SHOW_PASSWORDS_IN_DRY_RUN=false (only valid when DRY_RUN=true)
# Optional: INVENTORY_ID_BATCH_SIZE=80 (max Jamf Pro Computer IDs per GET …/v3/computers-inventory id=in=(…) filter)

# PREREQUISITES: ———————————————————————————————————————————————————————————————————————————————————

setopt errexit nounset no_nomatch pipefail
# no_nomatch: Safer word splitting / globs for data-only variables

# Script directory: ${0:A} resolves to absolute path; :h is dirname (zsh; works when file is executed, not sourced)
SCRIPT_DIR="${0:A:h}"
[[ -z "${SCRIPT_DIR}" ]] && SCRIPT_DIR="${PWD}"

ROTATION_SCOPE="${ROTATION_SCOPE:-all}"
DRY_RUN="${DRY_RUN:-false}"
SHOW_PASSWORDS_IN_DRY_RUN="${SHOW_PASSWORDS_IN_DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-info}"
WORDLIST_PATH="${WORDLIST_PATH:-${SCRIPT_DIR}/wordlists/eff_large_wordlist.txt}"
WORD_COUNT="${WORD_COUNT:-4}"
DELIMITER="${DELIMITER:--}"
INVENTORY_ID_BATCH_SIZE="${INVENTORY_ID_BATCH_SIZE:-80}"

SOURCE_LIST=""
JAMF_ACCESS_TOKEN=""

# LOGGING (UTC, no secrets): ———————————————————————————————————————————————————————————————————————

function _log() {
	local LEVEL="$1"
	shift
	local TIMESTAMP
	TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf '%s [%s] %s\n' "$TIMESTAMP" "$LEVEL" "$*" >&2
}

function log_error() { _log "ERROR" "$@"; }
function log_warn() { _log "WARN" "$@"; }
function log_info() { _log "INFO" "$@"; }
function log_debug() {
	case "${(L)LOG_LEVEL}" in
		debug) _log "DEBUG" "$@" ;;
	esac
}

# CONFIG VALIDATION (exit 1): ——————————————————————————————————————————————————————————————————————

function validateConfig() {
	local MISSING=0
	local ENV_VAR
	for ENV_VAR in JAMF_URL JAMF_CLIENT_ID JAMF_CLIENT_SECRET; do
		if ! ((${+parameters[$ENV_VAR]})) || [[ -z "${(P)ENV_VAR}" ]]; then
			log_error "Missing required environment variable: ${ENV_VAR}"
			MISSING=1
		fi
	done
	if ((MISSING)); then
		exit 1
	fi

	case "${(L)DRY_RUN}" in
		true | false) ;;
		*)
			log_error "DRY_RUN must be true or false (got: ${DRY_RUN})"
			exit 1
			;;
	esac

	case "${(L)SHOW_PASSWORDS_IN_DRY_RUN}" in
		true | false) ;;
		*)
			log_error "SHOW_PASSWORDS_IN_DRY_RUN must be true or false (got: ${SHOW_PASSWORDS_IN_DRY_RUN})"
			exit 1
			;;
	esac

	if [[ "${(L)SHOW_PASSWORDS_IN_DRY_RUN}" == true && "${(L)DRY_RUN}" != true ]]; then
		log_error "SHOW_PASSWORDS_IN_DRY_RUN=true is only allowed when DRY_RUN=true"
		exit 1
	fi

	case "${(L)LOG_LEVEL}" in
		debug | info | warn | error) ;;
		*)
			log_error "LOG_LEVEL must be one of: debug, info, warn, error (got: ${LOG_LEVEL})"
			exit 1
			;;
	esac

	if [[ ! -r "${WORDLIST_PATH}" ]]; then
		log_error "WORDLIST_PATH is not a readable file: ${WORDLIST_PATH}"
		exit 1
	fi

	if ! [[ "${WORD_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
		log_error "WORD_COUNT must be a positive integer (got: ${WORD_COUNT})"
		exit 1
	fi

	if ! [[ "${INVENTORY_ID_BATCH_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
		log_error "INVENTORY_ID_BATCH_SIZE must be a positive integer (got: ${INVENTORY_ID_BATCH_SIZE})"
		exit 1
	fi

	if [[ -z "${DELIMITER}" ]]; then
		log_error "DELIMITER must be non-empty"
		exit 1
	fi
}

function jamfBaseUrl() {
	local U="${JAMF_URL}"
	U="${U%/}"
	printf '%s' "$U"
}

# WORDLIST → SOURCE_LIST (EFF tab-prefixed or plain one-word-per-line): ————————————————————————————

function loadWordlist() {
	# Match original normalization: letters only, lowercase, unique lines
	SOURCE_LIST="$(
		awk -F'\t' '
			NF >= 2 && $2 != "" { print $2; next }
			{ print $1 }
		' "${WORDLIST_PATH}" | tr -cs 'A-Za-z' '\n' | tr '[:upper:]' '[:lower:]' | tr -d '\r' | sort -u
	)"

	if [[ -z "${SOURCE_LIST}" ]]; then
		log_error "Wordlist produced no usable words: ${WORDLIST_PATH}"
		exit 1
	fi

	local SOURCE_WORD_COUNT
	SOURCE_WORD_COUNT="$(wc -l <<<"${SOURCE_LIST}" | awk '{ print $1 }')"
	if [[ "${SOURCE_WORD_COUNT}" -lt 7776 ]]; then
		log_warn "Source contains only ${SOURCE_WORD_COUNT} unique words, which is below 7776 for maximum passphrase strength"
	fi

	log_info "Loaded ${SOURCE_WORD_COUNT} unique words from wordlist"
}

# Shuffle, take WORD_COUNT, join with DELIMITER (sort -R: macOS & GNU coreutils) + ignore 141 (SIGPIPE)
function generatePassphrase() {
	LC_ALL=C sort -R <<<"${SOURCE_LIST}" |
		head -n "${WORD_COUNT}" |
		paste -sd "${DELIMITER}" - ||
		[[ $? -eq 141 ]]
}

# HTTP WITH RETRIES (exit 2 on hard failure when caller requires): —————————————————————————————————

function jamfHttpRetry() {
	local METHOD="$1"
	local PATH_SUFFIX="$2"
	shift 2
	local ATTEMPT=1 MAX=5 WAIT=2
	local RAW CODE BODY LAST_ERR=""

	while ((ATTEMPT <= MAX)); do
		RAW="$(curl -sS \
			--connect-timeout 30 \
			--max-time 120 \
			-X "${METHOD}" \
			-w '\n%{http_code}' \
			"$@" \
			"$(jamfBaseUrl)${PATH_SUFFIX}" 2>&1)" || {
			LAST_ERR="curl transport error (attempt ${ATTEMPT}/${MAX})"
			log_warn "${LAST_ERR}"
			((ATTEMPT++)) || true
			sleep "${WAIT}"
			WAIT=$((WAIT * 2))
			continue
		}

		CODE="$(printf '%s' "${RAW}" | tail -n 1)"
		BODY="$(printf '%s' "${RAW}" | sed '$d')"

		if [[ "${CODE}" =~ ^2[0-9][0-9]$ ]]; then
			printf '%s' "${BODY}"
			return 0
		fi

		LAST_ERR="HTTP ${CODE} from ${PATH_SUFFIX}"
		if [[ "${CODE}" == 429 || "${CODE}" == 502 || "${CODE}" == 503 || "${CODE}" == 504 ]]; then
			log_warn "${LAST_ERR} — retrying in ${WAIT}s (attempt ${ATTEMPT}/${MAX})"
			sleep "${WAIT}"
			WAIT=$((WAIT * 2))
			((ATTEMPT++)) || true
			continue
		fi

		log_error "${LAST_ERR}"
		return 1
	done

	log_error "${LAST_ERR:-Request failed after ${MAX} attempts}"
	return 1
}

# AUTH: ————————————————————————————————————————————————————————————————————————————————————————————

function authObtainToken() {
	local BODY TOKEN
	log_info "Requesting OAuth access token"
	BODY="$(jamfHttpRetry POST "/api/oauth/token" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_id=${JAMF_CLIENT_ID}" \
		--data-urlencode "client_secret=${JAMF_CLIENT_SECRET}")" || {
		log_error "OAuth token request failed"
		exit 2
	}

	TOKEN="$(printf '%s' "${BODY}" | jq -er '.access_token // empty')" || {
		log_error "OAuth response missing access_token"
		exit 2
	}

	JAMF_ACCESS_TOKEN="${TOKEN}"
	log_info "OAuth token acquired"
}

# shellcheck disable=SC2329 # invoked indirectly in main via trap on EXIT
function authInvalidateToken() {
	if [[ -z "${JAMF_ACCESS_TOKEN:-}" ]]; then
		return 0
	fi
	local RAW CODE
	RAW="$(curl -sS \
		--connect-timeout 30 \
		--max-time 60 \
		-X POST \
		-H "Authorization: Bearer ${JAMF_ACCESS_TOKEN}" \
		-H "Accept: */*" \
		-w '\n%{http_code}' \
		"$(jamfBaseUrl)/api/v1/auth/invalidate-token" 2>/dev/null)" || true
	CODE="$(printf '%s' "${RAW}" | tail -n 1)"
	if [[ "${CODE}" =~ ^2[0-9][0-9]$ ]]; then
		log_debug "Bearer token invalidated"
	else
		log_debug "Token invalidate skipped or unsupported (non-fatal)"
	fi
	JAMF_ACCESS_TOKEN=""
}

# DEVICE DISCOVERY: ————————————————————————————————————————————————————————————————————————————————

# GET /api/v3/computers-inventory — GENERAL only; keeps payloads small.
# Outputs JSON array: [{ "jamfComputerId": "<id>", "managementId": "<uuid>" }, ...]
# Idempotency: unique_by(managementId) deduplicates rows within this run.
function fetchAllComputersInventory() {
	local PAGE=0 PAGE_SIZE=200 COMBINED='[]' CHUNK GOT
	while true; do
		CHUNK="$(jamfHttpRetry GET "/api/v3/computers-inventory?section=GENERAL&page=${PAGE}&page-size=${PAGE_SIZE}" \
			-H "Authorization: Bearer ${JAMF_ACCESS_TOKEN}" \
			-H "Accept: application/json")" || {
			log_error "Failed to fetch computer inventory v3 (page ${PAGE})"
			exit 2
		}

		GOT="$(printf '%s' "${CHUNK}" | jq -r '(.results // []) | length')"
		if [[ "${GOT}" -eq 0 ]]; then
			break
		fi

		local BATCH
		BATCH="$(printf '%s' "${CHUNK}" | jq -c '[(.results // [])[] | select((.general.managementId // "") != "") | {jamfComputerId: (.id | tostring), managementId: (.general.managementId | tostring)}]')"

		COMBINED="$(jq -s '.[0] + .[1]' <(printf '%s' "${COMBINED}") <(printf '%s' "${BATCH}"))"

		if [[ "${GOT}" -lt "${PAGE_SIZE}" ]]; then
			break
		fi
		PAGE=$((PAGE + 1))
	done

	printf '%s' "${COMBINED}" | jq -c 'unique_by(.managementId)'
}

# Input: compact JSON array of Jamf computer ids (e.g. from smart-group membership).
# Batches RSQL id=in=(…) against /api/v3/computers-inventory?section=GENERAL (managementId in general).
function fetchInventoryForComputerIds() {
	local IDS_JSON="$1"
	local COMBINED='[]' LEN OFFSET BATCH_IDS FILTER Q RESP BATCH GOT PSIZE

	LEN="$(printf '%s' "${IDS_JSON}" | jq 'length')"
	if [[ "${LEN}" -eq 0 ]]; then
		printf '%s' '[]'
		return 0
	fi

	PSIZE="${INVENTORY_ID_BATCH_SIZE}"
	[[ "${PSIZE}" -lt 200 ]] && PSIZE=200

	OFFSET=0
	while ((OFFSET < LEN)); do
		BATCH_IDS="$(printf '%s' "${IDS_JSON}" | jq -c --argjson off "${OFFSET}" --argjson sz "${INVENTORY_ID_BATCH_SIZE}" '.[$off:$off+$sz]')"
		GOT="$(printf '%s' "${BATCH_IDS}" | jq 'length')"
		if [[ "${GOT}" -eq 0 ]]; then
			break
		fi

		FILTER="$(printf '%s' "${BATCH_IDS}" | jq -r '"id=in=(" + (map(tostring) | join(",")) + ")"')"
		Q="$(jq -nr --arg f "${FILTER}" '$f|@uri')"
		RESP="$(jamfHttpRetry GET "/api/v3/computers-inventory?section=GENERAL&page=0&page-size=${PSIZE}&filter=${Q}" \
			-H "Authorization: Bearer ${JAMF_ACCESS_TOKEN}" \
			-H "Accept: application/json")" || {
			log_error "Failed v3 inventory lookup for computer id batch (offset ${OFFSET})"
			exit 2
		}

		BATCH="$(printf '%s' "${RESP}" | jq -c '[(.results // [])[] | select((.general.managementId // "") != "") | {jamfComputerId: (.id | tostring), managementId: (.general.managementId | tostring)}]')"
		COMBINED="$(jq -s '.[0] + .[1]' <(printf '%s' "${COMBINED}") <(printf '%s' "${BATCH}"))"
		OFFSET=$((OFFSET + GOT))
	done

	printf '%s' "${COMBINED}" | jq -c 'unique_by(.managementId)'
}

# Smart group name from ROTATION_SCOPE; outputs same JSON array shape as above.
# Resolves group id via GET /api/v2/computer-groups/smart-groups (RSQL name filter),
# then member Jamf computer ids via GET /api/v2/computer-groups/smart-group-membership/{id}.
function fetchSmartGroupDevices() {
	local NAME="$1"
	local FILTER Q RESPONSE TOTAL GROUP_ID MEMBERS_RESP IDS MAP MATCHED EXPECTED MCOUNT

	FILTER="$(jq -nr --arg n "${NAME}" '
		def esc: gsub("\\\\"; "\\\\\\\\") | gsub("\""; "\\\\\"");
		"name==\"" + ($n | esc) + "\""
	')"
	Q="$(jq -nr --arg f "${FILTER}" '$f|@uri')"
	RESPONSE="$(jamfHttpRetry GET "/api/v2/computer-groups/smart-groups?page=0&page-size=100&filter=${Q}" \
		-H "Authorization: Bearer ${JAMF_ACCESS_TOKEN}" \
		-H "Accept: application/json")" || {
		log_error "Failed to search smart computer groups (GET /api/v2/computer-groups/smart-groups)"
		exit 2
	}

	TOTAL="$(printf '%s' "${RESPONSE}" | jq -r '.totalCount // 0')"
	if [[ "${TOTAL}" -eq 0 ]]; then
		log_error "No smart computer group matched RSQL filter: ${FILTER}"
		exit 2
	fi

	if [[ "${TOTAL}" -gt 1 ]]; then
		log_warn "Multiple (${TOTAL}) smart groups matched ${FILTER} — using results[0].id"
	fi

	GROUP_ID="$(printf '%s' "${RESPONSE}" | jq -er '.results[0].id // empty')" || {
		log_error "Smart group search response missing results[0].id"
		exit 2
	}

	log_info "Resolved smart group ID=${GROUP_ID} for name \"${NAME}\""

	MEMBERS_RESP="$(jamfHttpRetry GET "/api/v2/computer-groups/smart-group-membership/${GROUP_ID}" \
		-H "Authorization: Bearer ${JAMF_ACCESS_TOKEN}" \
		-H "Accept: application/json")" || {
		log_error "Failed to fetch smart group membership (GET /api/v2/computer-groups/smart-group-membership/${GROUP_ID})"
		exit 2
	}

	IDS="$(printf '%s' "${MEMBERS_RESP}" | jq -c '(.members // []) | unique')"
	MAP="$(fetchInventoryForComputerIds "${IDS}")"

	MATCHED="$(jq -nc --argjson ids "${IDS}" --argjson map "${MAP}" '
		[ $ids[] as $i
			| ( $map[]
					| select((.jamfComputerId | tostring) == ($i | tostring))
				)
		] | unique_by(.managementId)
	')"
	EXPECTED="$(printf '%s' "${IDS}" | jq 'length')"
	MCOUNT="$(printf '%s' "${MATCHED}" | jq 'length')"
	if [[ "${MCOUNT}" -lt "${EXPECTED}" ]]; then
		log_warn "Smart group membership lists ${EXPECTED} computers, but only ${MCOUNT} matched v3 inventory (GENERAL.managementId present; others skipped)"
	fi
	printf '%s' "${MATCHED}"
}

function fetchDevices() {
	if [[ "${ROTATION_SCOPE}" == all ]]; then
		log_info "Rotation scope: All computers (GET /api/v3/computers-inventory, section=GENERAL, managementId present)"
		fetchAllComputersInventory
	else
		log_info "Rotation scope: Smart Group \"${ROTATION_SCOPE}\""
		fetchSmartGroupDevices "${ROTATION_SCOPE}"
	fi
}

# ROTATION: ————————————————————————————————————————————————————————————————————————————————————————

function rotateRecoveryLock() {
	local MANAGEMENT_ID="$1"
	local PASSPHRASE="$2"
	local JAMF_COMPUTER_ID="${3:-}"
	local PAYLOAD

	case "${(L)DRY_RUN}" in
		true)
			if [[ "${(L)SHOW_PASSWORDS_IN_DRY_RUN}" == true ]]; then
				log_warn "DRY_RUN: would send SET_RECOVERY_LOCK jamfComputerId=${JAMF_COMPUTER_ID:-unknown} managementId=${MANAGEMENT_ID} passphrase=${PASSPHRASE}"
			else
				log_info "DRY_RUN: would send SET_RECOVERY_LOCK for managementId (redacted)"
			fi
			return 0
			;;
	esac

	PAYLOAD="$(jq -n \
		--arg mid "${MANAGEMENT_ID}" \
		--arg pw "${PASSPHRASE}" \
		'{
			clientData: [{ clientType: "COMPUTER", managementId: $mid }],
			commandData: { commandType: "SET_RECOVERY_LOCK", newPassword: $pw }
		}')"

	if jamfHttpRetry POST "/api/v2/mdm/commands" \
		-H "Authorization: Bearer ${JAMF_ACCESS_TOKEN}" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d "${PAYLOAD}" >/dev/null; then
		return 0
	fi
	return 1
}

# REPORTING: ———————————————————————————————————————————————————————————————————————————————————————

function writeGithubOutputs() {
	local ROTATED="$1"
	local FAILED="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			printf 'rotated_count=%s\n' "${ROTATED}"
			printf 'failed_count=%s\n' "${FAILED}"
		} >>"${GITHUB_OUTPUT}"
	fi
}

# MAIN: ————————————————————————————————————————————————————————————————————————————————————————————

function main() {
	validateConfig
	loadWordlist
	log_debug "Starting Jamf Recovery Lock Rotation (WORD_COUNT=${WORD_COUNT})"

	trap 'authInvalidateToken 2>/dev/null || true' EXIT

	authObtainToken

	local DEVICES_JSON DEVICE_COUNT
	DEVICES_JSON="$(fetchDevices)"
	DEVICE_COUNT="$(printf '%s' "${DEVICES_JSON}" | jq 'length')"

	if [[ "${DEVICE_COUNT}" -eq 0 ]]; then
		log_warn "No eligible Mac computers with Management ID in scope"
		writeGithubOutputs 0 0
		exit 0
	fi

	log_info "Mac computers to process: ${DEVICE_COUNT}"

	local ROTATED=0 FAILED=0 IDX=0
	local ROW MANAGEMENT_ID JAMF_ID PASSPHRASE

	while IFS= read -r ROW; do
		((IDX++)) || true
		MANAGEMENT_ID="$(printf '%s' "${ROW}" | jq -r '.managementId')"
		JAMF_ID="$(printf '%s' "${ROW}" | jq -r '.jamfComputerId // empty')"

		if [[ -z "${MANAGEMENT_ID}" || "${MANAGEMENT_ID}" == null ]]; then
			log_warn "Skipping row ${IDX}: missing Management ID"
			((FAILED++)) || true
			continue
		fi

		PASSPHRASE="$(generatePassphrase)"

		log_info "Processing device jamfComputerId=${JAMF_ID:-unknown} (${IDX}/${DEVICE_COUNT})"

		if rotateRecoveryLock "${MANAGEMENT_ID}" "${PASSPHRASE}" "${JAMF_ID}"; then
			((ROTATED++)) || true
			log_info "SET_RECOVERY_LOCK issued for jamfComputerId=${JAMF_ID:-unknown}"
		else
			((FAILED++)) || true
			log_warn "SET_RECOVERY_LOCK failed for jamfComputerId=${JAMF_ID:-unknown}"
		fi
	done < <(printf '%s' "${DEVICES_JSON}" | jq -c '.[]')

	writeGithubOutputs "${ROTATED}" "${FAILED}"

	log_info "Finished: rotated=${ROTATED} failed=${FAILED}"

	if ((FAILED > 0 && ROTATED == 0)); then
		exit 2
	fi
	if ((FAILED > 0)); then
		exit 3
	fi
	exit 0
}

main "$@"
