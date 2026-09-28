#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
serial="${ANDROID_SERIAL:?Set ANDROID_SERIAL to an authorized Android device}"
apk="${APK_PATH:-${root_dir}/sample/androidApp/build/outputs/apk/debug/androidApp-debug.apk}"
output_dir="${OUTPUT_DIR:-${root_dir}/captures/local/android-device-compatibility}"
load_timeout_seconds="${LOAD_TIMEOUT_SECONDS:-180}"
visual_settle_seconds="${VISUAL_SETTLE_SECONDS:-4}"
visual_timeout_seconds="${VISUAL_TIMEOUT_SECONDS:-60}"
minimum_capture_bytes="${MINIMUM_CAPTURE_BYTES:-24000}"
content_luma_threshold="${CONTENT_LUMA_THRESHOLD:-220}"
skip_install="${SKIP_INSTALL:-false}"
visual_case_ids="${VISUAL_CASE_IDS:-\
prod_flowchart_shape_catalog_network_control,\
prod_sequence_arrow_matrix_workflow,\
prod_state_markdown_metadata_compliance,\
prod_gantt_compact_links_certification,\
prod_mindmap_configured_theme_readiness,\
prod_sankey_beta_compact,\
prod_agentflow_responsive_handoff,\
prod_architecture_accessible_unicode,\
prod_zenuml_documented_context}"
package_name="${PACKAGE_NAME:-com.swithun.cmpmermaid.sample}"
activity_name="${ACTIVITY_NAME:-com.swithun.cmpmermaid.debugui.MermaidDebugActivity}"
load_failure_marker="CMP_MERMAID_LOAD_TEST_FAILED"
visual_failure_marker="CMP_MERMAID_VISUAL_TEST_FAILED"

if [[ -n "${ANDROID_HOME:-}" && -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    adb="${ANDROID_HOME}/platform-tools/adb"
else
    adb="$(command -v adb)"
fi

for command_name in ffmpeg jq node; do
    if ! command -v "${command_name}" >/dev/null; then
        echo "${command_name} is required." >&2
        exit 2
    fi
done
if [[ ! -f "${apk}" ]]; then
    echo "APK not found: ${apk}" >&2
    exit 2
fi

mkdir -p "${output_dir}/visual"
"${adb}" -s "${serial}" wait-for-device
"${adb}" -s "${serial}" shell input keyevent KEYCODE_WAKEUP </dev/null >/dev/null
"${adb}" -s "${serial}" shell wm dismiss-keyguard </dev/null >/dev/null 2>&1 || true
if [[ "${skip_install}" != true ]]; then
    "${adb}" -s "${serial}" install -r -t "${apk}" </dev/null >/dev/null
fi

getprop_value() {
    "${adb}" -s "${serial}" shell getprop "$1" </dev/null | tr -d '\r'
}

read_pss_kb() {
    "${adb}" -s "${serial}" shell dumpsys meminfo "${package_name}" </dev/null |
        awk '
            /TOTAL PSS:/ { print $3; exit }
            /^[[:space:]]*TOTAL[[:space:]]/ { print $2; exit }
        ' |
        tr -d '\r'
}

capture_has_content() {
    local path="$1"
    local bytes
    local minimum_luma

    bytes="$(stat -f%z "${path}")"
    if ((bytes < minimum_capture_bytes)); then
        return 1
    fi
    minimum_luma="$(
        ffmpeg \
            -hide_banner \
            -loglevel error \
            -i "${path}" \
            -vf "crop=iw:ih-200:0:100,signalstats,metadata=print:file=-" \
            -frames:v 1 \
            -f null \
            - |
            awk -F= '/lavfi.signalstats.YMIN/ { print $2; exit }'
    )"
    [[ -n "${minimum_luma}" && "${minimum_luma}" -lt "${content_luma_threshold}" ]]
}

app_crash_count() {
    "${adb}" -s "${serial}" logcat -d -b crash </dev/null |
        grep -Ec "FATAL EXCEPTION|Fatal signal" ||
        true
}

app_anr_count() {
    "${adb}" -s "${serial}" logcat -d -b events </dev/null |
        grep -F "am_anr" |
        grep -Fc "${package_name}" ||
        true
}

read_visual_tree() {
    local path="$1"
    local remote_path="/sdcard/cmp-mermaid-audit-window.xml"

    "${adb}" -s "${serial}" shell uiautomator dump "${remote_path}" \
        </dev/null \
        >/dev/null 2>&1 || return 1
    "${adb}" -s "${serial}" exec-out cat "${remote_path}" \
        </dev/null \
        > "${path}"
}

read -r case_count last_case_id < <(
    node --input-type=module -e \
        "import { cases } from '${root_dir}/tools/official-reference/production-corpus.mjs'; console.log(cases.length, cases.at(-1)?.id)"
)
completion_marker="CMP_MERMAID_LOAD_TEST_COMPLETE ${last_case_id}"
manufacturer="$(getprop_value ro.product.manufacturer)"
market_name="$(getprop_value ro.product.marketname)"
model="$(getprop_value ro.product.model)"
android_version="$(getprop_value ro.build.version.release)"
sdk="$(getprop_value ro.build.version.sdk)"
abi="$(getprop_value ro.product.cpu.abi)"
screen_size="$(
    "${adb}" -s "${serial}" shell wm size </dev/null |
        awk -F': ' '/Physical size:/ { print $2; exit }' |
        tr -d '\r'
)"
density="$(
    "${adb}" -s "${serial}" shell wm density </dev/null |
        awk -F': ' '/Physical density:/ { print $2; exit }' |
        tr -d '\r'
)"

"${adb}" -s "${serial}" shell am force-stop "${package_name}" </dev/null
"${adb}" -s "${serial}" logcat -c </dev/null
"${adb}" -s "${serial}" shell am start -W \
    -n "${package_name}/${activity_name}" \
    --ez openLoadTest true \
    --ez autoRunLoadTest true \
    </dev/null \
    >/dev/null

load_started_at="${SECONDS}"
peak_pss_kb=0
load_complete=false
load_failed=false
process_alive=true
while ((SECONDS - load_started_at <= load_timeout_seconds)); do
    current_pss_kb="$(read_pss_kb)"
    if [[ "${current_pss_kb}" =~ ^[0-9]+$ ]] &&
        ((current_pss_kb > peak_pss_kb)); then
        peak_pss_kb="${current_pss_kb}"
    fi
    load_log="$(
        "${adb}" -s "${serial}" logcat -d \
            -s System.out:I AndroidRuntime:E '*:S' \
            </dev/null
    )"
    if grep -Fq "${completion_marker}" <<< "${load_log}"; then
        load_complete=true
        break
    fi
    if grep -Fq "${load_failure_marker}" <<< "${load_log}"; then
        load_failed=true
        break
    fi
    if grep -Fq "FATAL EXCEPTION" <<< "${load_log}"; then
        process_alive=false
        break
    fi
    if ! "${adb}" -s "${serial}" shell pidof "${package_name}" </dev/null |
        grep -q '[0-9]'; then
        process_alive=false
        break
    fi
    sleep 1
done

load_seconds="$((SECONDS - load_started_at))"
load_crash_count="$(app_crash_count)"
load_anr_count="$(app_anr_count)"
final_pss_kb="$(read_pss_kb)"
final_pss_kb="${final_pss_kb:-0}"
"${adb}" -s "${serial}" exec-out screencap -p \
    </dev/null \
    > "${output_dir}/load-test-final.png"
load_screenshot_valid=false
if capture_has_content "${output_dir}/load-test-final.png"; then
    load_screenshot_valid=true
fi

visual_passed=0
visual_failed=0
IFS=',' read -r -a visual_cases <<< "${visual_case_ids}"
for case_id in "${visual_cases[@]}"; do
    case_id="${case_id//[[:space:]]/}"
    [[ -n "${case_id}" ]] || continue
    "${adb}" -s "${serial}" shell am force-stop "${package_name}" </dev/null
    "${adb}" -s "${serial}" logcat -c </dev/null
    "${adb}" -s "${serial}" shell am start \
        -n "${package_name}/${activity_name}" \
        --es auditDemoId "${case_id}" \
        --es auditPreview Native \
        --es auditLayout dagre \
        </dev/null \
        >/dev/null
    sleep "${visual_settle_seconds}"

    screenshot="${output_dir}/visual/${case_id}.png"
    tree_path="${output_dir}/visual/${case_id}.xml"
    case_alive=false
    case_crashed=true
    case_anr=true
    case_render_failed=true
    case_ready=false
    case_visible=false
    visual_started_at="${SECONDS}"
    while ((SECONDS - visual_started_at <= visual_timeout_seconds)); do
        if read_visual_tree "${tree_path}" &&
            grep -Fq "cmp-mermaid-audit:ready:" "${tree_path}"; then
            case_ready=true
            break
        fi
        if "${adb}" -s "${serial}" logcat -d </dev/null |
            grep -Fq "${visual_failure_marker}"; then
            break
        fi
        if ! "${adb}" -s "${serial}" shell pidof "${package_name}" </dev/null |
            grep -q '[0-9]'; then
            break
        fi
        sleep 1
    done
    if "${adb}" -s "${serial}" shell pidof "${package_name}" </dev/null |
        grep -q '[0-9]'; then
        case_alive=true
    fi
    if [[ "$(app_crash_count)" == "0" ]]; then
        case_crashed=false
    fi
    if [[ "$(app_anr_count)" == "0" ]]; then
        case_anr=false
    fi
    if ! "${adb}" -s "${serial}" logcat -d </dev/null |
        grep -Fq "${visual_failure_marker}"; then
        case_render_failed=false
    fi
    if [[
        "${case_alive}" == true &&
        "${case_crashed}" == false &&
        "${case_anr}" == false &&
        "${case_render_failed}" == false
    ]]; then
        "${adb}" -s "${serial}" exec-out screencap -p \
            </dev/null \
            > "${screenshot}"
        if capture_has_content "${screenshot}"; then
            case_visible=true
        fi
    fi

    if [[
        "${case_alive}" == true &&
        "${case_crashed}" == false &&
        "${case_anr}" == false &&
        "${case_render_failed}" == false &&
        "${case_ready}" == true &&
        "${case_visible}" == true
    ]]; then
        visual_passed="$((visual_passed + 1))"
        echo "PASS visual ${case_id}"
    else
        visual_failed="$((visual_failed + 1))"
        echo \
            "FAIL visual ${case_id}" \
            "alive=${case_alive}" \
            "crashed=${case_crashed}" \
            "anr=${case_anr}" \
            "renderFailed=${case_render_failed}" \
            "ready=${case_ready}" \
            "visible=${case_visible}" \
            >&2
    fi
done

overall_pass=false
if [[
    "${load_complete}" == true &&
    "${load_failed}" == false &&
    "${process_alive}" == true &&
    "${load_crash_count}" == "0" &&
    "${load_anr_count}" == "0" &&
    "${load_screenshot_valid}" == true &&
    "${visual_failed}" == "0"
]]; then
    overall_pass=true
fi

jq -n \
    --arg manufacturer "${manufacturer}" \
    --arg marketName "${market_name}" \
    --arg model "${model}" \
    --arg androidVersion "${android_version}" \
    --arg sdk "${sdk}" \
    --arg abi "${abi}" \
    --arg screenSize "${screen_size}" \
    --arg density "${density}" \
    --argjson caseCount "${case_count}" \
    --argjson loadSeconds "${load_seconds}" \
    --argjson peakPssKb "${peak_pss_kb}" \
    --argjson finalPssKb "${final_pss_kb}" \
    --argjson loadCrashCount "${load_crash_count}" \
    --argjson loadAnrCount "${load_anr_count}" \
    --argjson visualPassed "${visual_passed}" \
    --argjson visualFailed "${visual_failed}" \
    --argjson loadComplete "${load_complete}" \
    --argjson loadFailed "${load_failed}" \
    --argjson processAlive "${process_alive}" \
    --argjson loadScreenshotValid "${load_screenshot_valid}" \
    --argjson passed "${overall_pass}" \
    '{
        schemaVersion: 1,
        device: {
            manufacturer: $manufacturer,
            marketName: $marketName,
            model: $model,
            androidVersion: $androidVersion,
            sdk: ($sdk | tonumber),
            abi: $abi,
            screenSize: $screenSize,
            densityDpi: ($density | tonumber)
        },
        load: {
            caseCount: $caseCount,
            complete: $loadComplete,
            failed: $loadFailed,
            processAlive: $processAlive,
            seconds: $loadSeconds,
            peakPssKb: $peakPssKb,
            finalPssKb: $finalPssKb,
            crashCount: $loadCrashCount,
            anrCount: $loadAnrCount,
            screenshotValid: $loadScreenshotValid
        },
        visual: {
            passed: $visualPassed,
            failed: $visualFailed
        },
        passed: $passed
    }' |
    tee "${output_dir}/metrics.json"

[[ "${overall_pass}" == true ]]
