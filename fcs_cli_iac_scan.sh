#!/bin/sh
#
# CrowdStrike FCS CLI Downloader and Scanner
#
# This script automatically downloads the latest FCS CLI tool for the current
# platform and executes an Infrastructure as Code (IaC) scan.
#
# Author: Kyle Butler
# Version: 1.3
# Dependencies: curl, jq, tar
#
# Usage:
#   ./fcs_cli_iac_scan.sh [scan_directory] [version_offset]
#
#   scan_directory  - Directory to scan (default: current directory)
#   version_offset  - Version offset from latest (0=latest, 1=n-1, 2=n-2, etc.)
#                    (default: 0)
#
# Examples:
#   ./fcs_cli_iac_scan.sh                           # Scan current dir with latest version
#   ./fcs_cli_iac_scan.sh ./iac_dir               # Scan iac_dir dir with latest version
#   ./fcs_cli_iac_scan.sh ./iac_dir 1             # Scan iac_dir dir with n-1 version
#   ./fcs_cli_iac_scan.sh . 2                       # Scan current dir with n-2 version
#
# Environment Variables:
#   SCAN_PATH        - Override scan directory via environment variable
#   VERSION_OFFSET   - Override version offset via environment variable
#   CS_BASE_API_URL  - CrowdStrike API base URL
#   CS_CLIENT_ID     - CrowdStrike API Client ID
#   CS_CLIENT_SECRET - CrowdStrike API Client Secret
#   GENERATE_SARIF   - Generate SARIF output (default: true)
#   GENERATE_SUMMARY - Generate human-readable summary (default: true)
#   SHOW_FULL_RESULTS - Display full human-readable summary at end (default: false)
#   EXIT_WITH_FCS_CODE - Exit with FCS CLI exit code instead of 0 (default: false)
#   DEBUG            - Enable debug output (default: false)
#
# Proxy Environment Variables (optional - auto-detected):
#   HTTP_PROXY       - HTTP proxy URL (e.g., http://proxy.company.com:8080)
#   HTTPS_PROXY      - HTTPS proxy URL (e.g., http://proxy.company.com:8080)
#   NO_PROXY         - Comma-separated list of hosts to bypass proxy
#   PROXY_USER       - Proxy username (if authentication required)
#   PROXY_PASS       - Proxy password (if authentication required)
#
# Exit Codes:
#   0 - Success (unless EXIT_WITH_FCS_CODE=true)
#   1 - Authentication failure
#   2 - No compatible CLI version found
#   3 - Download failure
#   4 - Missing dependencies
#   5 - Invalid arguments
#   6 - User cancelled input
#   40+ - FCS CLI exit codes (when EXIT_WITH_FCS_CODE=true)
#

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default values - will prompt for input if not set via environment variables
CS_BASE_API_URL="${CS_BASE_API_URL:-}"
CS_CLIENT_ID="${CS_CLIENT_ID:-}"
CS_CLIENT_SECRET="${CS_CLIENT_SECRET:-}"
GENERATE_SARIF="${GENERATE_SARIF:-true}"
GENERATE_SUMMARY="${GENERATE_SUMMARY:-true}"
SHOW_FULL_RESULTS="${SHOW_FULL_RESULTS:-false}"
EXIT_WITH_FCS_CODE="${EXIT_WITH_FCS_CODE:-false}"
DEBUG="${DEBUG:-false}"

# Proxy configuration (optional)
HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"

# Detect current platform
OS_TYPE=$(uname | awk '{print tolower(substr($1,1,1)) substr($1,2)}')
ARCH_TYPE=$(uname -m)
# Fix architecture naming for API compatibility
case "$ARCH_TYPE" in
    x86_64)
        ARCH_TYPE="amd64"
        ;;
    aarch64)
        ARCH_TYPE="arm64"
        ;;
esac

# Global variable to store FCS CLI exit code
FCS_EXIT_CODE=0

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

#
# Parses command line arguments and sets global variables
# Arguments: $@ - All command line arguments
# Sets: SCAN_PATH, VERSION_OFFSET
#
parse_arguments() {
    # Set defaults
    SCAN_PATH="${SCAN_PATH:-$(pwd)}"
    VERSION_OFFSET="${VERSION_OFFSET:-0}"

    # Parse command line arguments
    if [ $# -ge 1 ]; then
        if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
            show_usage
            exit 0
        fi
        SCAN_PATH="$1"
    fi

    if [ $# -ge 2 ]; then
        VERSION_OFFSET="$2"
        # Validate version offset is a number
        case "$VERSION_OFFSET" in
            ''|*[!0-9]*)
                log "ERROR" "Version offset must be a non-negative integer, got: $VERSION_OFFSET"
                exit 5
                ;;
        esac
    fi

    # Validate scan path exists
    if [ ! -d "$SCAN_PATH" ]; then
        log "ERROR" "Scan directory does not exist: $SCAN_PATH"
        exit 5
    fi

    # Convert to absolute path
    SCAN_PATH=$(cd "$SCAN_PATH" && pwd)
}

#
# Shows usage information
#
show_usage() {
    cat << 'EOF'
CrowdStrike FCS CLI Downloader and Scanner

Usage: ./fcs_cli_iac_scan.sh [scan_directory] [version_offset]

Arguments:
  scan_directory   Directory to scan (default: current directory)
  version_offset   Version offset from latest (default: 0)
                   0 = latest version
                   1 = n-1 (previous version)
                   2 = n-2 (two versions back)
                   etc.

Environment Variables:
  SCAN_PATH        Override scan directory
  VERSION_OFFSET   Override version offset
  CS_BASE_API_URL  CrowdStrike API base URL
  CS_CLIENT_ID     CrowdStrike Client ID
  CS_CLIENT_SECRET CrowdStrike Client Secret
  GENERATE_SARIF   Generate SARIF output (default: true)
  GENERATE_SUMMARY Generate human-readable summary (default: true)
  SHOW_FULL_RESULTS Display full human-readable summary at end (default: false)
  EXIT_WITH_FCS_CODE Exit with FCS CLI exit code (default: false)
  DEBUG            Enable debug output (default: false)

Proxy Variables (optional - auto-detected from environment):
  HTTP_PROXY       HTTP proxy URL (e.g., http://proxy.company.com:8080)
  HTTPS_PROXY      HTTPS proxy URL (e.g., http://proxy.company.com:8080)
  NO_PROXY         Hosts to bypass proxy (comma-separated)
  PROXY_USER       Proxy username (if authentication required)
  PROXY_PASS       Proxy password (if authentication required)

Examples:
  ./fcs_cli_iac_scan.sh                    # Scan current directory with latest version
  ./fcs_cli_iac_scan.sh ./iac_dir        # Scan iac_dir directory with latest version
  ./fcs_cli_iac_scan.sh ./iac_dir 1      # Scan iac_dir directory with n-1 version
  ./fcs_cli_iac_scan.sh . 2                # Scan current directory with n-2 version

  # Using environment variables
  SCAN_PATH=./infrastructure VERSION_OFFSET=1 ./fcs_cli_iac_scan.sh

  # Pre-setting credentials
  CS_BASE_API_URL=https://api.us-2.crowdstrike.com \
  CS_CLIENT_ID=your_client_id \
  CS_CLIENT_SECRET=your_client_secret \
  ./fcs_cli_iac_scan.sh

  # Show full human-readable summary at end
  SHOW_FULL_RESULTS=true ./fcs_cli_iac_scan.sh

  # Exit with FCS CLI exit code (useful for CI/CD)
  EXIT_WITH_FCS_CODE=true ./fcs_cli_iac_scan.sh

  # Combine options
  SHOW_FULL_RESULTS=true EXIT_WITH_FCS_CODE=true ./fcs_cli_iac_scan.sh

  # Using proxy
  HTTP_PROXY=http://proxy.company.com:8080 \
  HTTPS_PROXY=http://proxy.company.com:8080 \
  ./fcs_cli_iac_scan.sh

  # Using authenticated proxy
  HTTP_PROXY=http://proxy.company.com:8080 \
  PROXY_USER=username \
  PROXY_PASS=password \
  ./fcs_cli_iac_scan.sh

  # Disable SARIF generation, enable summary only
  GENERATE_SARIF=false GENERATE_SUMMARY=true ./fcs_cli_iac_scan.sh

  # Enable debug output
  DEBUG=true ./fcs_cli_iac_scan.sh

Available CrowdStrike Regions:
  US-1:     https://api.crowdstrike.com
  US-2:     https://api.us-2.crowdstrike.com
  EU-1:     https://api.eu-1.crowdstrike.com
  US-GOV-1: https://api.laggar.gcw.crowdstrike.com
  US-GOV-2: https://api.us-gov-2.crowdstrike.mil

Exit Code Behavior:
  - Default: Script exits with 0 on successful scan completion
  - EXIT_WITH_FCS_CODE=true: Script exits with FCS CLI exit code
    * 0: No issues found
    * 40: Issues found (typical for security findings)
    * Other codes: Various FCS CLI error conditions

Output Options:
  - Default: Shows brief summary with top findings
  - SHOW_FULL_RESULTS=true: Shows complete detailed human-readable summary
EOF
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

#
# Logs messages with timestamp to stderr
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR, DEBUG)
#   $2 - Message to log
#
log() {
    level="$1"
    message="$2"

    # Skip DEBUG messages unless DEBUG is enabled
    if [ "$level" = "DEBUG" ] && [ "$DEBUG" != "true" ]; then
        return
    fi

    printf "[%s] %s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >&2
}

#
# Detects and configures proxy settings
# Sets global variables for curl proxy usage
#
detect_and_configure_proxy() {
    # Check for common proxy environment variables (case-insensitive)
    if [ -z "$HTTP_PROXY" ]; then
        HTTP_PROXY="${http_proxy:-}"
    fi
    if [ -z "$HTTPS_PROXY" ]; then
        HTTPS_PROXY="${https_proxy:-}"
    fi
    if [ -z "$NO_PROXY" ]; then
        NO_PROXY="${no_proxy:-}"
    fi

    # Build curl proxy arguments
    CURL_PROXY_ARGS=""

    if [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ]; then
        log "INFO" "Proxy configuration detected"

        if [ -n "$HTTP_PROXY" ]; then
            log "DEBUG" "HTTP Proxy: $HTTP_PROXY"
            CURL_PROXY_ARGS="$CURL_PROXY_ARGS --proxy $HTTP_PROXY"
        fi

        if [ -n "$HTTPS_PROXY" ] && [ "$HTTPS_PROXY" != "$HTTP_PROXY" ]; then
            log "DEBUG" "HTTPS Proxy: $HTTPS_PROXY"
            # For HTTPS requests, we'll use HTTPS_PROXY
        fi

        if [ -n "$NO_PROXY" ]; then
            log "DEBUG" "No proxy for: $NO_PROXY"
            CURL_PROXY_ARGS="$CURL_PROXY_ARGS --noproxy $NO_PROXY"
        fi

        # Add proxy authentication if provided
        if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
            log "DEBUG" "Using proxy authentication (user: $PROXY_USER)"
            CURL_PROXY_ARGS="$CURL_PROXY_ARGS --proxy-user $PROXY_USER:$PROXY_PASS"
        elif [ -n "$PROXY_USER" ]; then
            log "DEBUG" "Using proxy authentication (user: $PROXY_USER, no password)"
            CURL_PROXY_ARGS="$CURL_PROXY_ARGS --proxy-user $PROXY_USER"
        fi

        log "INFO" "Proxy configuration applied"
    else
        log "DEBUG" "No proxy configuration detected"
    fi
}

#
# Executes curl with appropriate proxy settings
# Arguments: All arguments are passed to curl
# Returns: curl exit code
#
curl_with_proxy() {
    # Determine if this is an HTTPS request
    is_https=0
    for arg in "$@"; do
        case "$arg" in
            https://*)
                is_https=1
                break
                ;;
        esac
    done

    # Use appropriate proxy for HTTPS requests
    proxy_args="$CURL_PROXY_ARGS"
    if [ "$is_https" -eq 1 ] && [ -n "$HTTPS_PROXY" ] && [ "$HTTPS_PROXY" != "$HTTP_PROXY" ]; then
        # Replace HTTP proxy with HTTPS proxy for HTTPS requests
        proxy_args=$(echo "$proxy_args" | sed "s|--proxy $HTTP_PROXY|--proxy $HTTPS_PROXY|")
    fi

    log "DEBUG" "Executing curl with proxy args: $proxy_args"

    # Execute curl with proxy arguments
    if [ -n "$proxy_args" ]; then
        eval "curl $proxy_args \"\$@\""
    else
        curl "$@"
    fi
}

#
# Tests proxy connectivity to CrowdStrike API
# Returns: 0 if successful, 1 if failed
#
test_proxy_connectivity() {
    if [ -n "$CS_BASE_API_URL" ]; then
        log "INFO" "Testing proxy connectivity to CrowdStrike API..."

        # Test basic connectivity
        if curl_with_proxy --silent --connect-timeout 10 --max-time 30 --head "$CS_BASE_API_URL" >/dev/null 2>&1; then
            log "INFO" "Proxy connectivity test successful"
            return 0
        else
            log "WARN" "Proxy connectivity test failed - continuing anyway"
            return 1
        fi
    fi
    return 0
}

#
# Displays full human-readable summary if requested
# Arguments: $1 - Human-readable summary file path
#
show_full_human_results() {
    summary_file="$1"

    if [ "$SHOW_FULL_RESULTS" = "true" ] && [ -f "$summary_file" ]; then
        echo ""
        echo "================================================================================"
        echo "                    COMPLETE DETAILED SCAN RESULTS"
        echo "================================================================================"
        echo ""
        cat "$summary_file"
        echo ""
        echo "================================================================================"
        echo "                      END OF DETAILED RESULTS"
        echo "================================================================================"
        echo ""
    fi
}

#
# Checks if running in GitHub Actions environment
# Returns: 0 if in GitHub Actions, 1 otherwise
#
is_github_actions() {
    [ "${GITHUB_ACTIONS:-}" = "true" ]
}

#
# Checks if running in a non-interactive environment
# Returns: 0 if non-interactive, 1 if interactive
#
is_non_interactive() {
    # Check if stdin is not a terminal or if we're in CI/automated environment
    [ ! -t 0 ] || [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${JENKINS_URL:-}" != "" ]
}

#
# Prompts user for input with a default value
# Arguments:
#   $1 - Prompt message
#   $2 - Default value (optional)
#   $3 - Hide input (for passwords) - set to "hidden" to hide
# Returns: User input via stdout
#
prompt_user() {
    prompt_msg="$1"
    default_val="${2:-}"
    hide_input="${3:-}"

    if [ -n "$default_val" ]; then
        printf "%s [%s]: " "$prompt_msg" "$default_val" >&2
    else
        printf "%s: " "$prompt_msg" >&2
    fi

    if [ "$hide_input" = "hidden" ]; then
        # Hide input for passwords
        stty -echo 2>/dev/null || true
        read -r user_input
        stty echo 2>/dev/null || true
        printf "\n" >&2
    else
        read -r user_input
    fi

    # Use default if no input provided
    if [ -z "$user_input" ] && [ -n "$default_val" ]; then
        user_input="$default_val"
    fi

    printf "%s" "$user_input"
}

#
# Validates that a URL is a valid CrowdStrike API URL
# Arguments: $1 - URL to validate
# Returns: 0 if valid, 1 if invalid
#
validate_api_url() {
    url="$1"
    case "$url" in
        https://api.crowdstrike.com|\
        https://api.us-2.crowdstrike.com|\
        https://api.eu-1.crowdstrike.com|\
        https://api.laggar.gcw.crowdstrike.com|\
        https://api.us-gov-2.crowdstrike.mil)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

#
# Extracts the JSON results file path from FCS CLI output
# Arguments: $1 - FCS CLI output text
# Returns: File path via stdout, or empty if not found
#
extract_results_file_path() {
    scan_output="$1"

    # Method 1: Extract and clean the path
    result=$(printf '%s' "$scan_output" | \
        grep "Results saved to file:" | \
        sed 's/.*Results saved to file: *//' | \
        head -n 1)

    if [ -n "$result" ]; then
        # Clean up the result by extracting only the path up to .json
        # This handles ANSI escape codes and other trailing characters
        cleaned_result=$(printf '%s' "$result" | sed -n 's/^\([^[:space:]]*\.json\).*/\1/p')

        if [ -n "$cleaned_result" ]; then
            printf '%s' "$cleaned_result"
            return
        fi

        # Fallback: more aggressive cleanup
        cleaned_result=$(printf '%s' "$result" | tr -cd '[:print:]' | sed 's/[[:space:]]*$//' | sed 's/\[[0-9;]*m.*$//')

        if [ -n "$cleaned_result" ]; then
            printf '%s' "$cleaned_result"
            return
        fi
    fi
}

#
# Debug function to help troubleshoot file path extraction
#
debug_file_extraction() {
    temp_output="$1"
    log "DEBUG" "=== Debugging file path extraction ==="
    log "DEBUG" "Full output length: $(wc -c < "$temp_output")"
    log "DEBUG" "Lines containing 'Results':"
    grep -n "Results" "$temp_output" >&2 || log "DEBUG" "No lines containing 'Results' found"
    log "DEBUG" "Lines containing 'saved':"
    grep -n "saved" "$temp_output" >&2 || log "DEBUG" "No lines containing 'saved' found"
    log "DEBUG" "Raw extraction attempt:"
    grep "Results saved to file:" "$temp_output" | sed 's/.*Results saved to file: //' | od -c >&2 || log "DEBUG" "No match found"
    log "DEBUG" "=== End debug ==="
}

#
# Generates a human-readable summary from FCS JSON results
# Arguments: $1 - Input JSON file, $2 - Output text file
# Returns: 0 on success, 1 on failure
#
generate_human_readable_summary() {
    input_file="$1"
    output_file="$2"

    if [ ! -f "$input_file" ]; then
        log "ERROR" "Input JSON file not found: $input_file"
        return 1
    fi

    log "INFO" "Generating human-readable summary..."

    # Create human-readable summary
    cat > "$output_file" << EOF
================================================================================
CrowdStrike Falcon Cloud Security - Scan Results Summary
================================================================================

Scan Information:
- Scan UUID: $(jq -r '.scan_uuid' "$input_file")
- Scan Date: $(jq -r '.scan_performed_at' "$input_file")
- Scan Duration: $(jq -r '.scan_duration_seconds' "$input_file") seconds
- FCS Version: $(jq -r '.fcs_version' "$input_file")
- Scan Path: $(jq -r '.path' "$input_file")

Files Scanned:
- Total Files: $(jq -r '.stats.files_stats.total' "$input_file")
- Failed to Scan: $(jq -r '.stats.files_stats.failed_to_scan' "$input_file")
- Skipped: $(jq -r '.stats.files_stats.skipped' "$input_file")

Security Findings Summary:
- Total Issues: $(jq -r '.detection_summary.total' "$input_file")
- High Severity: $(jq -r '.detection_summary.high' "$input_file")
- Medium Severity: $(jq -r '.detection_summary.medium' "$input_file")
- Informational: $(jq -r '.detection_summary.informational' "$input_file")

Rules Executed:
- Total Rules: $(jq -r '.stats.rule_stats.total_rules' "$input_file")
- Rules Enabled: $(jq -r '.stats.rule_stats.rules_enabled' "$input_file")
- Rules Failed: $(jq -r '.stats.rule_stats.rules_failed_to_execute' "$input_file")

================================================================================
DETAILED FINDINGS
================================================================================

EOF

    # Add detailed findings grouped by severity - count individual detections, not rules
    for severity in "High" "Medium" "Informational"; do
        # Count individual detections for this severity level
        count=$(jq -r --arg sev "$severity" '[.rule_detections[] | select(.severity == $sev) | .detections[]] | length' "$input_file")

        if [ "$count" -gt 0 ]; then
            echo "" >> "$output_file"
            echo "=== $severity SEVERITY ISSUES ($count found) ===" >> "$output_file"
            echo "" >> "$output_file"

            # Process each rule and its detections
            jq -r --arg sev "$severity" '
                .rule_detections[] |
                select(.severity == $sev) |
                . as $rule |
                .detections[] |
                "Rule: " + $rule.rule_name + "
Category: " + $rule.rule_category + "
Description: " + $rule.description + "
Platform: " + $rule.platform + " | Cloud Provider: " + $rule.cloud_provider + " | Service: " + ($rule.service // "N/A") + "

Affected Resources:
  • File: " + .file + " (Line " + (.line | tostring) + ")
    Resource: " + (.resource_type // "N/A") + " - " + (.resource_name // "N/A") + "
    Issue: " + .reason + "
    Recommendation: " + .recommendation +
                (if .remediation then "
    Remediation Code: " + .remediation else "" end) + "

" + ("─" * 80) + "
"
            ' "$input_file" >> "$output_file"
        fi
    done

    # Add footer with additional information
    cat >> "$output_file" << EOF

================================================================================
SCAN COMPLETION SUMMARY
================================================================================

This scan was performed using CrowdStrike Falcon Cloud Security.
For more information about remediation steps, consult the CrowdStrike documentation
or contact your security team.

Generated on: $(date)
Report files:
- JSON Results: $(basename "$input_file")
- Human Summary: $(basename "$output_file")
$(if [ "$GENERATE_SARIF" = "true" ]; then echo "- SARIF Results: $(basename "${input_file%.json}.sarif")"; fi)

================================================================================
EOF

    log "INFO" "Human-readable summary generated: $output_file"
    return 0
}

#
# Converts FCS JSON output to SARIF format
# Arguments: $1 - Input JSON file, $2 - Output SARIF file
# Returns: 0 on success, 1 on failure
#
convert_json_to_sarif() {
    input_file="$1"
    output_file="$2"

    if [ ! -f "$input_file" ]; then
        log "ERROR" "Input JSON file not found: $input_file"
        return 1
    fi

    log "INFO" "Converting JSON to SARIF format..."

    # Create SARIF output using jq
    jq --arg tool_version "$FILE_VERSION" '{
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "CrowdStrike FCS",
                        "version": $tool_version,
                        "informationUri": "https://crowdstrike.com",
                        "shortDescription": {
                            "text": "CrowdStrike Falcon Cloud Security - Infrastructure as Code Scanner"
                        },
                        "fullDescription": {
                            "text": "Static analysis tool for Infrastructure as Code security scanning"
                        },
                        "rules": [
                            .rule_detections[]? | {
                                "id": .rule_uuid,
                                "name": .rule_name,
                                "shortDescription": {
                                    "text": .rule_name
                                },
                                "fullDescription": {
                                    "text": .description
                                },
                                "defaultConfiguration": {
                                    "level": (
                                        if .severity == "Critical" then "error"
                                        elif .severity == "High" then "error"
                                        elif .severity == "Medium" then "warning"
                                        elif .severity == "Informational" then "note"
                                        else "note"
                                        end
                                    )
                                },
                                "properties": {
                                    "category": .rule_category,
                                    "platform": .platform,
                                    "cloud_provider": .cloud_provider,
                                    "service": .service,
                                    "rule_type": .rule_type,
                                    "severity": .severity
                                }
                            }
                        ] | unique_by(.id)
                    }
                },
                "results": [
                    .rule_detections[]? as $rule | $rule.detections[]? | {
                        "ruleId": $rule.rule_uuid,
                        "ruleIndex": 0,
                        "message": {
                            "text": .reason,
                            "markdown": ("**Issue:** " + .reason + "\n\n**Recommendation:** " + .recommendation + (if .remediation then "\n\n**Remediation:**\n```\n" + .remediation + "\n```" else "" end))
                        },
                        "level": (
                            if $rule.severity == "Critical" then "error"
                            elif $rule.severity == "High" then "error"
                            elif $rule.severity == "Medium" then "warning"
                            elif $rule.severity == "Informational" then "note"
                            else "note"
                            end
                        ),
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {
                                        "uri": .file,
                                        "uriBaseId": "%SRCROOT%"
                                    },
                                    "region": {
                                        "startLine": (.line // 1),
                                        "startColumn": 1
                                    }
                                }
                            }
                        ],
                        "properties": {
                            "resource_type": .resource_type,
                            "resource_name": .resource_name,
                            "issue_type": .issue_type,
                            "file_sha256": .file_sha256,
                            "remediation_type": .remediation_type,
                            "platform": $rule.platform,
                            "cloud_provider": $rule.cloud_provider,
                            "service": $rule.service,
                            "category": $rule.rule_category
                        },
                        "fixes": [
                            if .remediation then {
                                "description": {
                                    "text": ("Apply " + (.remediation_type // "fix") + " to resolve this issue")
                                },
                                "artifactChanges": [
                                    {
                                        "artifactLocation": {
                                            "uri": .file
                                        },
                                        "replacements": [
                                            {
                                                "deletedRegion": {
                                                    "startLine": (.line // 1),
                                                    "startColumn": 1
                                                },
                                                "insertedContent": {
                                                    "text": .remediation
                                                }
                                            }
                                        ]
                                    }
                                ]
                            } else empty end
                        ],
                        "relatedLocations": []
                    }
                ],
                "properties": {
                    "fcs_version": .fcs_version,
                    "scan_type": .scan_type,
                    "scan_uuid": .scan_uuid,
                    "scan_performed_at": .scan_performed_at,
                    "scan_duration_seconds": .scan_duration_seconds,
                    "detection_summary": .detection_summary,
                    "stats": .stats
                }
            }
        ]
    }' "$input_file" > "$output_file" 2>/dev/null

    if [ $? -eq 0 ] && [ -f "$output_file" ]; then
        log "INFO" "SARIF conversion completed: $output_file"
        log "INFO" "Converted $(jq -r '.runs[0].results | length' "$output_file" 2>/dev/null || echo "unknown") findings to SARIF format"
        return 0
    else
        log "ERROR" "Failed to convert JSON to SARIF"
        return 1
    fi
}

#
# Checks for credentials in multiple locations
# Sets global variables: CS_BASE_API_URL, CS_CLIENT_ID, CS_CLIENT_SECRET
# Returns: 0 if credentials found, 1 if not found
#
get_credentials() {
    # First check environment variables
    if [ -n "$CS_BASE_API_URL" ] && [ -n "$CS_CLIENT_ID" ] && [ -n "$CS_CLIENT_SECRET" ]; then
        log "INFO" "Using credentials from environment variables"
        return 0
    fi

    # Check for config file
    config_file="$HOME/.crowdstrike/fcs.json"
    if [ -f "$config_file" ] && [ -r "$config_file" ]; then
        log "INFO" "Found configuration file: $config_file"

        # Extract credentials from config file
        if ! command -v jq >/dev/null 2>&1; then
            log "ERROR" "jq is required to parse config file"
            return 1
        fi

        # Read values from config file
        local profile_name
        profile_name=$(jq -r '.profile // "default"' "$config_file")

        # Extract credentials from the specified profile
        CS_CLIENT_ID=$(jq -r --arg profile "$profile_name" '.profiles[$profile].client_id // empty' "$config_file")
        CS_CLIENT_SECRET=$(jq -r --arg profile "$profile_name" '.profiles[$profile].client_secret // empty' "$config_file")
        CS_BASE_API_URL=$(jq -r --arg profile "$profile_name" '.profiles[$profile].falcon_domains.api // empty' "$config_file")

        if [ -n "$CS_BASE_API_URL" ] && [ -n "$CS_CLIENT_ID" ] && [ -n "$CS_CLIENT_SECRET" ]; then
            log "INFO" "Using credentials from config file (profile: $profile_name)"
            return 0
        else
            log "WARN" "Config file found but missing required credentials"
        fi
    fi

    # If we get here, no valid credentials were found
    if is_non_interactive; then
        log "ERROR" "No valid credentials found in environment variables or config file"
        log "ERROR" "Please set CS_BASE_API_URL, CS_CLIENT_ID, and CS_CLIENT_SECRET environment variables"
        log "ERROR" "Or provide a valid configuration file at: $config_file"
        return 1
    fi

    # If interactive, prompt for credentials
    log "INFO" "No credentials found, prompting for input..."
    prompt_for_credentials
    return 0
}

#
# Prompts user for CrowdStrike credentials if not already set
# Sets global variables: CS_BASE_API_URL, CS_CLIENT_ID, CS_CLIENT_SECRET
#
prompt_for_credentials() {
    if is_non_interactive; then
        log "ERROR" "Running in non-interactive mode but credentials are not set"
        log "ERROR" "Please set CS_BASE_API_URL, CS_CLIENT_ID, and CS_CLIENT_SECRET environment variables"
        exit 6
    fi

    log "INFO" "CrowdStrike credentials not found in environment variables"
    printf "\nPlease provide your CrowdStrike API credentials:\n\n" >&2

    # Prompt for API URL if not set
    if [ -z "$CS_BASE_API_URL" ]; then
        printf "Select your CrowdStrike region:\n" >&2
        printf "  1) US-1 (Commercial)    - https://api.crowdstrike.com\n" >&2
        printf "  2) US-2 (Commercial)    - https://api.us-2.crowdstrike.com\n" >&2
        printf "  3) EU-1 (Commercial)    - https://api.eu-1.crowdstrike.com\n" >&2
        printf "  4) US-GOV-1 (GovCloud)  - https://api.laggar.gcw.crowdstrike.com\n" >&2
        printf "  5) US-GOV-2 (GovCloud)  - https://api.us-gov-2.crowdstrike.mil\n" >&2
        printf "  6) Custom URL\n\n" >&2

        while true; do
            selection=$(prompt_user "Enter your choice (1-6)" "1")

            case "$selection" in
                1)
                    CS_BASE_API_URL="https://api.crowdstrike.com"
                    break
                    ;;
                2)
                    CS_BASE_API_URL="https://api.us-2.crowdstrike.com"
                    break
                    ;;
                3)
                    CS_BASE_API_URL="https://api.eu-1.crowdstrike.com"
                    break
                    ;;
                4)
                    CS_BASE_API_URL="https://api.laggar.gcw.crowdstrike.com"
                    break
                    ;;
                5)
                    CS_BASE_API_URL="https://api.us-gov-2.crowdstrike.mil"
                    break
                    ;;
                6)
                    while true; do
                        custom_url=$(prompt_user "Enter custom CrowdStrike API URL")
                        if validate_api_url "$custom_url"; then
                            CS_BASE_API_URL="$custom_url"
                            break 2  # Break out of both loops
                        else
                            printf "Invalid API URL. Please enter a valid CrowdStrike API URL.\n" >&2
                        fi
                    done
                    ;;
                *)
                    printf "Invalid selection. Please enter 1-6.\n" >&2
                    ;;
            esac
        done

        log "INFO" "Selected API URL: $CS_BASE_API_URL"
    fi

    # Prompt for Client ID if not set
    if [ -z "$CS_CLIENT_ID" ]; then
        while true; do
            CS_CLIENT_ID=$(prompt_user "Enter CrowdStrike Client ID")
            if [ -n "$CS_CLIENT_ID" ]; then
                break
            fi
            printf "Client ID cannot be empty. Please try again.\n" >&2
        done
    fi

    # Prompt for Client Secret if not set
    if [ -z "$CS_CLIENT_SECRET" ]; then
        while true; do
            CS_CLIENT_SECRET=$(prompt_user "Enter CrowdStrike Client Secret" "" "hidden")
            if [ -n "$CS_CLIENT_SECRET" ]; then
                break
            fi
            printf "Client Secret cannot be empty. Please try again.\n" >&2
        done
    fi

    printf "\n" >&2
    log "INFO" "Credentials collected successfully"
}

#
# Checks if required commands are available
# Exits with code 4 if dependencies are missing
#
check_dependencies() {
    missing_deps=""

    for cmd in curl jq tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            if [ -z "$missing_deps" ]; then
                missing_deps="$cmd"
            else
                missing_deps="$missing_deps $cmd"
            fi
        fi
    done

    if [ -n "$missing_deps" ]; then
        log "ERROR" "Missing required dependencies: $missing_deps"
        exit 4
    fi
}

#
# Sorts version strings in descending order (newest first)
# Reads version strings from stdin, outputs sorted versions to stdout
# POSIX compliant version sorting function
#
version_sort_awk() {
    awk '{
        # Split version into numeric parts
        n = split($0, parts, /\./)
        key = ""
        # Create sortable key by padding numbers with zeros
        for (i = 1; i <= n; i++) {
            key = key sprintf("%05d", parts[i])
        }
        print key " " $0
    }' | sort -k1,1r | cut -d' ' -f2-
}

#
# Gets the nth version from a sorted list (0-indexed)
# Arguments: $1 - offset (0=latest, 1=n-1, etc.)
# Reads sorted versions from stdin
#
get_version_by_offset() {
    offset="$1"
    offset=$((offset + 1))  # Convert to 1-indexed for head/tail
    head -n "$offset" | tail -n 1
}

#
# Maps CrowdStrike API URLs to their corresponding region codes
# Arguments:
#   $1 - Full API URL (e.g., https://api.crowdstrike.com)
# Returns:
#   Region code (US-1, US-2, EU-1, US-GOV-1, US-GOV-2)
# Exit code 1 if URL is not recognized
#
map_api_to_region() {
    hostname="$1"

    # Remove protocol prefix using parameter expansion
    hostname="${hostname#https://}"
    hostname="${hostname#http://}"
    # Remove any path after hostname
    hostname="${hostname%%/*}"

    case "$hostname" in
        "api.crowdstrike.com")           printf "us-1" ;;
        "api.us-2.crowdstrike.com")      printf "us-2" ;;
        "api.eu-1.crowdstrike.com")      printf "eu-1" ;;
        "api.laggar.gcw.crowdstrike.com") printf "us-gov-1" ;;
        "api.us-gov-2.crowdstrike.mil")  printf "us-gov-2" ;;
        *)
            log "ERROR" "Unknown API URL: $hostname"
            return 1
            ;;
    esac
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

#
# Authenticates with CrowdStrike API and retrieves access token
# Sets global variable: CS_TOKEN
# Exits with code 1 on authentication failure
#
authenticate() {
    log "INFO" "Authenticating with CrowdStrike API..."

    oauth_response=$(curl_with_proxy --silent --request POST \
                          --url "$CS_BASE_API_URL/oauth2/token" \
                          --header "Accept: application/json" \
                          --header "Content-Type: application/x-www-form-urlencoded" \
                          --data-raw "client_id=$CS_CLIENT_ID&client_secret=$CS_CLIENT_SECRET")

    CS_TOKEN=$(printf '%s' "$oauth_response" | jq -r '.access_token')

    if [ -z "$CS_TOKEN" ] || [ "$CS_TOKEN" = "null" ]; then
        log "ERROR" "Failed to obtain access token"
        log "ERROR" "Please verify your credentials and API URL are correct"
        if [ -n "$CURL_PROXY_ARGS" ]; then
            log "ERROR" "If using a proxy, verify proxy settings and authentication"
        fi
        exit 1
    fi

    log "INFO" "Authentication successful"
}

#
# Retrieves available FCS CLI files from CrowdStrike
# Sets global variable: DL_ENUMERATE_RESPONSE
#
get_available_files() {
    log "INFO" "Retrieving available FCS CLI files..."

    DL_ENUMERATE_RESPONSE=$(curl_with_proxy --silent --request GET \
                                 --url "$CS_BASE_API_URL/csdownloads/entities/files/enumerate/v1" \
                                 --header "Authorization: Bearer $CS_TOKEN" \
                                 --header "Accept: application/json" \
                                 --header "Content-Type: application/json")
}

#
# Determines the compatible FCS CLI version for current platform based on offset
# Sets global variables: FILE_VERSION, FILE_NAME
# Exits with code 2 if no compatible version is found
#
find_version_by_offset() {
    log "INFO" "Finding FCS CLI versions for $OS_TYPE/$ARCH_TYPE..."

    # Get all available versions for this platform, sorted newest first
    available_versions=$(printf '%s' "$DL_ENUMERATE_RESPONSE" | \
                        jq -r --arg OS_TYPE "$OS_TYPE" --arg ARCH_TYPE "$ARCH_TYPE" \
                        '.resources[] | select(.os == $OS_TYPE) | select(.arch == $ARCH_TYPE) | .version' | \
                        version_sort_awk | uniq)

    if [ -z "$available_versions" ]; then
        log "ERROR" "No supported CLI files found for OS: $OS_TYPE and architecture: $ARCH_TYPE"
        exit 2
    fi

    # Count available versions
    version_count=$(printf '%s' "$available_versions" | wc -l)
    log "INFO" "Found $version_count available versions"

    # Check if requested offset is valid
    if [ "$VERSION_OFFSET" -ge "$version_count" ]; then
        log "ERROR" "Version offset $VERSION_OFFSET is too large. Only $version_count versions available (0-$((version_count-1)))"
        log "INFO" "Available versions:"
        printf '%s' "$available_versions" | awk '{print "  " NR-1 ": " $0}' >&2
        exit 2
    fi

    # Get the version at the specified offset
    FILE_VERSION=$(printf '%s' "$available_versions" | get_version_by_offset "$VERSION_OFFSET")

    if [ -z "$FILE_VERSION" ]; then
        log "ERROR" "Failed to get version at offset $VERSION_OFFSET"
        exit 2
    fi

    FILE_NAME=$(printf '%s' "$DL_ENUMERATE_RESPONSE" | \
                jq -r --arg OS_TYPE "$OS_TYPE" --arg ARCH_TYPE "$ARCH_TYPE" --arg FILE_VERSION "$FILE_VERSION" \
                '.resources[] | select(.os == $OS_TYPE) | select(.arch == $ARCH_TYPE) | select(.version == $FILE_VERSION) | .file_name')

    version_description="latest"
    if [ "$VERSION_OFFSET" -gt 0 ]; then
        version_description="n-$VERSION_OFFSET"
    fi

    log "INFO" "Selected version: $FILE_VERSION ($version_description)"
}

#
# Gets presigned download URL for the FCS CLI file
# Sets global variable: FCS_CLI_PRESIGNED_URL
# Exits with code 3 if presigned URL cannot be obtained
#
get_download_url() {
    log "INFO" "Obtaining download URL for $FILE_NAME..."

    presigned_response=$(curl_with_proxy --silent --request GET \
                              --url "$CS_BASE_API_URL/csdownloads/entities/files/download/v1?file_name=$FILE_NAME&file_version=$FILE_VERSION" \
                              --header "Authorization: Bearer $CS_TOKEN" \
                              --header "Accept: application/json" \
                              --header "Content-Type: application/json")

    FCS_CLI_PRESIGNED_URL=$(printf '%s' "$presigned_response" | jq -r '.resources.download_url')

    if [ -z "$FCS_CLI_PRESIGNED_URL" ] || [ "$FCS_CLI_PRESIGNED_URL" = "null" ]; then
        log "ERROR" "Failed to obtain presigned download URL"
        exit 3
    fi
}

#
# Downloads and extracts the FCS CLI tool
# Creates executable fcs binary in current directory
#
download_and_extract() {
    archive_name="fcs_${FILE_VERSION}_${OS_TYPE}_${ARCH_TYPE}.tar.gz"

    log "INFO" "Downloading FCS CLI v$FILE_VERSION..."

    if ! curl_with_proxy -L --progress-bar -o "$archive_name" "$FCS_CLI_PRESIGNED_URL"; then
        log "ERROR" "Failed to download FCS CLI"
        if [ -n "$CURL_PROXY_ARGS" ]; then
            log "ERROR" "If using a proxy, verify proxy settings allow downloads from AWS S3"
        fi
        exit 3
    fi

    log "INFO" "Extracting archive..."
    tar -xzf "$archive_name"
    chmod +x ./fcs

    # Clean up archive
    rm -f "$archive_name"

    # Try to get version, fallback to generic message if it fails
    version_info=$(./fcs version 2>/dev/null || printf "version unknown")
    log "INFO" "FCS CLI ready: $version_info"
}

#
# Configures FCS CLI with proxy settings if needed
# Creates or updates FCS configuration file
#
configure_fcs_proxy() {
    if [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ]; then
        log "INFO" "Configuring FCS CLI with proxy settings..."

        # Create FCS config directory if it doesn't exist
        mkdir -p "$HOME/.crowdstrike"

        # Create or update FCS config file with proxy settings
        config_file="$HOME/.crowdstrike/config.yaml"

        # Backup existing config if it exists
        if [ -f "$config_file" ]; then
            cp "$config_file" "$config_file.backup.$(date +%s)"
            log "DEBUG" "Backed up existing FCS config"
        fi

        # Write proxy configuration
        cat > "$config_file" << EOF
# FCS CLI Configuration with Proxy Settings
# Auto-generated by FCS downloader script

proxy:
EOF

        if [ -n "$HTTP_PROXY" ]; then
            echo "  http: $HTTP_PROXY" >> "$config_file"
        fi

        if [ -n "$HTTPS_PROXY" ]; then
            echo "  https: $HTTPS_PROXY" >> "$config_file"
        fi

        if [ -n "$NO_PROXY" ]; then
            echo "  no_proxy: $NO_PROXY" >> "$config_file"
        fi

        if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
            echo "  auth:" >> "$config_file"
            echo "    username: $PROXY_USER" >> "$config_file"
            echo "    password: $PROXY_PASS" >> "$config_file"
        fi

        log "INFO" "FCS CLI proxy configuration created: $config_file"
    fi
}

#
# Executes FCS CLI scan on the specified directory
# Uses configured credentials for authentication
# Captures output and processes results files
#
run_scan() {
    log "INFO" "Starting IaC scan on: $SCAN_PATH"

    # Configure FCS CLI with proxy settings if needed
    configure_fcs_proxy

    # Create a temporary file to capture FCS output
    temp_output=$(mktemp)

    # Set proxy environment variables for FCS CLI if configured
    if [ -n "$HTTP_PROXY" ]; then
        export HTTP_PROXY
        export http_proxy="$HTTP_PROXY"
    fi
    if [ -n "$HTTPS_PROXY" ]; then
        export HTTPS_PROXY
        export https_proxy="$HTTPS_PROXY"
    fi
    if [ -n "$NO_PROXY" ]; then
        export NO_PROXY
        export no_proxy="$NO_PROXY"
    fi

    # Run the FCS scan and capture both stdout and stderr
    ./fcs iac scan \
        --client-id "$CS_CLIENT_ID" \
        --client-secret "$CS_CLIENT_SECRET" \
        --falcon-region "$CS_REGION" \
        --path "$SCAN_PATH" \
        --upload-results > "$temp_output" 2>&1

    # Store the FCS CLI exit code
    FCS_EXIT_CODE=$?

    # Display the output
    cat "$temp_output"

    # Debug the file extraction if DEBUG is enabled
    if [ "$DEBUG" = "true" ]; then
        debug_file_extraction "$temp_output"
    fi

    # Extract the results file path from the output
    results_file=$(extract_results_file_path "$(cat "$temp_output")")

    log "DEBUG" "Extracted results file path: '$results_file'"
    log "DEBUG" "FCS CLI exit code: $FCS_EXIT_CODE"

    if [ -n "$results_file" ] && [ -f "$results_file" ]; then
        log "INFO" "Found results file: $results_file"

        # Generate SARIF output if requested
        if [ "$GENERATE_SARIF" = "true" ]; then
            sarif_file="${results_file%.json}.sarif"
            if convert_json_to_sarif "$results_file" "$sarif_file"; then
                log "INFO" "SARIF file generated: $sarif_file"
            else
                log "WARN" "Failed to generate SARIF file"
            fi
        fi

        # Generate human-readable summary if requested
        summary_file=""
        if [ "$GENERATE_SUMMARY" = "true" ]; then
            summary_file="${results_file%.json}-summary.txt"
            if generate_human_readable_summary "$results_file" "$summary_file"; then
                log "INFO" "Human-readable summary generated: $summary_file"

                # Copy to current directory
                cp "$summary_file" "./fcs-scan-summary.txt"
                log "INFO" "Summary copied to: ./fcs-scan-summary.txt"

                # Display key summary information to console (brief version)
                echo ""
                echo "================================================================================"
                echo "                           SCAN RESULTS SUMMARY"
                echo "================================================================================"
                echo ""

                # Extract and display key metrics
                total_issues=$(jq -r '.detection_summary.total' "$results_file")
                high_issues=$(jq -r '.detection_summary.high' "$results_file")
                medium_issues=$(jq -r '.detection_summary.medium' "$results_file")
                info_issues=$(jq -r '.detection_summary.informational' "$results_file")

                echo "Security Findings Summary:"
                echo "- Total Issues: $total_issues"
                echo "- High Severity: $high_issues"
                echo "- Medium Severity: $medium_issues"
                echo "- Informational: $info_issues"
                echo ""

                # Show top 5 most critical findings
                echo "Top Critical Findings:"
                jq -r '.rule_detections[] | select(.severity == "High") | "• " + .rule_name + " (" + (.detections | length | tostring) + " occurrences)"' "$results_file" | head -5
                echo ""

                echo "Full detailed summary available in: ./fcs-scan-summary.txt"
                echo "================================================================================"
                echo ""
            else
                log "WARN" "Failed to generate human-readable summary"
            fi
        fi

        # Copy results to current directory for convenience
        cp "$results_file" "./fcs-scan-results.json"
        log "INFO" "Results copied to: ./fcs-scan-results.json"

        if [ -f "${results_file%.json}.sarif" ]; then
            cp "${results_file%.json}.sarif" "./fcs-scan-results.sarif"
            log "INFO" "SARIF results copied to: ./fcs-scan-results.sarif"
        fi

        # Show full human-readable summary if requested
        if [ -n "$summary_file" ]; then
            show_full_human_results "$summary_file"
        fi

        # Clean up temporary file
        rm -f "$temp_output"

        # Log completion with exit code information
        if [ "$EXIT_WITH_FCS_CODE" = "true" ]; then
            log "INFO" "Scan completed - will exit with FCS CLI exit code: $FCS_EXIT_CODE"
        else
            log "INFO" "Scan completed successfully (FCS CLI exit code: $FCS_EXIT_CODE, script will exit with 0)"
        fi

        return 0
    else
        log "WARN" "Could not locate results file from scan output"
        log "DEBUG" "Looking for results file: '$results_file'"

        # Clean up temporary file
        rm -f "$temp_output"
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"

    log "INFO" "Starting FCS CLI downloader and scanner"
    log "INFO" "Platform: $OS_TYPE/$ARCH_TYPE"
    log "INFO" "Scan directory: $SCAN_PATH"
    log "INFO" "Version offset: $VERSION_OFFSET"
    log "INFO" "Generate SARIF: $GENERATE_SARIF"
    log "INFO" "Generate Summary: $GENERATE_SUMMARY"
    log "INFO" "Show Full Results: $SHOW_FULL_RESULTS"
    log "INFO" "Exit with FCS Code: $EXIT_WITH_FCS_CODE"

    # Detect and configure proxy settings
    detect_and_configure_proxy

    # Get credentials from environment or config file
    if ! get_credentials; then
        exit 1
    fi

    # Test proxy connectivity if configured
    test_proxy_connectivity

    # Determine CrowdStrike region
    CS_REGION=$(map_api_to_region "$CS_BASE_API_URL")
    log "INFO" "CrowdStrike region: $CS_REGION"

    # Validate dependencies
    check_dependencies

    # Download and setup FCS CLI
    authenticate
    get_available_files
    find_version_by_offset
    get_download_url
    download_and_extract

    # Execute scan
    if run_scan; then
        # Determine exit code based on configuration
        if [ "$EXIT_WITH_FCS_CODE" = "true" ]; then
            log "INFO" "Exiting with FCS CLI exit code: $FCS_EXIT_CODE"
            exit $FCS_EXIT_CODE
        else
            log "INFO" "Scan process completed successfully"
            exit 0
        fi
    else
        log "ERROR" "Scan process failed"
        exit 1
    fi
}

# Execute main function
main "$@"
