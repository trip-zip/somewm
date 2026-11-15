#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

legs=()
for file in tests/distro/*.Dockerfile; do
    leg=${file##*/}
    legs+=("${leg%.Dockerfile}")
done
jobs=3
if [[ ${1:-} == -j ]]; then
    jobs=${2:-}
    shift $(( $# >= 2 ? 2 : 1 ))
fi
if [[ ! $jobs =~ ^[1-9][0-9]{0,8}$ ]] || (( $# == 0 )); then
    printf 'Usage: %s [-j N] <leg>... | all\nLegs: %s\n' "$0" "${legs[*]}" >&2
    exit 1
fi
if [[ $* == all ]]; then
    set -- "${legs[@]}"
fi
for leg in "$@"; do
    if [[ ! $leg =~ ^[a-z0-9][a-z0-9.-]*$ || ! -f tests/distro/$leg.Dockerfile ]]; then
        printf 'Unknown leg: %s\nLegs: %s\n' "$leg" "${legs[*]}" >&2
        exit 1
    fi
done
selected=("$@")
if (( ${#selected[@]} == 1 )); then
    jobs=1
fi
cpus=("")
if (( jobs > 1 )); then
    if split=$(python3 tests/distro/cpu-split.py "$jobs" 2>/dev/null); then
        mapfile -t cpus <<< "$split"
    else
        printf 'Cannot split whole CPU cores, falling back to -j 1\n' >&2
        jobs=1
    fi
fi
free_slots=("${!cpus[@]}")
slots=()

docker info >/dev/null || exit 1
if [[ ! -c /dev/udmabuf ]]; then
    printf 'Missing /dev/udmabuf, cannot run distro tests\n' >&2
    exit 1
fi
mkdir -p build-distro
snapshot=$(mktemp -d)
run_id="somewm-distro-$$-${snapshot##*.}"
declare -A active=()
mkfifo "$snapshot/completed"
exec {events}<> "$snapshot/completed"
names=()
for index in "${!selected[@]}"; do
    names+=("$run_id-$index" "$run_id-$index-passwd")
done
cleanup() {
    trap '' INT TERM
    local pid
    for pid in "${active[@]}"; do
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    docker rm -f "${names[@]}" >/dev/null 2>&1 || true
    for pid in "${active[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$snapshot"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Each worker and its Docker clients share a process group for cancellation.
set -m
record() {
    local line c_ok table=false
    while IFS= read -r line || [[ -n $line ]]; do
        printf '%s\n' "$line" >> "$log"
        case $line in
            VERSIONS) table=true; continue ;;
            'END VERSIONS') table=false ;;
            'STEP SKIP '* | 'STEP PASS '* | smoke* | wraps* | 'busted Lua:'* | *' successes / '* | $'ok\t'* | $'FAIL\t'*) printf '%s\n' "$line" ;;
            Ok:*) c_ok=$line ;;
            Fail:*) printf 'C tests: %s, %s\n' "$c_ok" "$line" ;;
        esac
        if $table; then printf '%s\n' "$line"; fi
    done
}
run_leg() {
    local index=$1 leg=$2 started=$SECONDS log step status source_dir lock
    local result failure output test_name
    local -a user
    local container="$run_id-$index"
    local -a affinity=()
    if [[ -n $3 ]]; then
        affinity=(--cpuset-cpus "$3")
        printf 'CPUs %s: %s\n' "$leg" "$3"
    fi
    # Hold the lock until the container exits so runners cannot overwrite its logs or rebuild its image.
    exec {lock}> "build-distro/$leg.lock"
    flock "$lock"
    log=build-distro/$leg.log
    step=image
    if docker build --pull -t "somewm-distro:$leg" \
        -f "tests/distro/$leg.Dockerfile" tests/distro/ > "$log" 2>&1 &&
        docker run --rm --name "$container-passwd" "somewm-distro:$leg" cat /etc/passwd > "$snapshot/$leg.passwd" 2>> "$log"; then
        if ! awk -F: -v uid="$(id -u)" '$3 == uid { found=1 } END { exit !found }' "$snapshot/$leg.passwd"; then
            printf 'distro:x:%s:%s::/tmp:/bin/bash\n' "$(id -u)" "$(id -g)" >> "$snapshot/$leg.passwd"
        fi
        source_dir=$(mktemp -d "$snapshot/$leg.XXXXXX")
        declare -A deleted=()
        while IFS= read -r -d '' file; do
            deleted["$file"]=1
        done < <(git ls-files -z --deleted)
        # New files count before they are staged. Ignored files do not.
        git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' file; do
            if [[ ! ${deleted[$file]+yes} ]]; then printf '%s\0' "$file"; fi
        done | tar --null -T - -cf - | tar -xf - -C "$source_dir"
        user=(--user "$(id -u):$(id -g)" --group-add "$(stat -c %g /dev/udmabuf)")
        if [[ $(docker image inspect -f '{{index .Config.Labels "somewm.distro.user"}}' "somewm-distro:$leg") == root ]]; then
            user=(-e "OWNER=$(id -u):$(id -g)")
        fi
        status=0
        # dbus-run-session uses the mounted /etc/passwd because the image may lack the host UID.
        # somewm needs --group-add to open /dev/udmabuf because Docker does not preserve the host ACL.
        docker run --rm -i --name "$container" "${affinity[@]}" -e LANG=C.UTF-8 \
            -e "STEPS=${STEPS-}" -e "TEST=${TEST:-}" --device /dev/udmabuf "${user[@]}" -e HOME=/tmp \
            --mount "type=bind,src=$snapshot/$leg.passwd,dst=/etc/passwd,readonly" \
            --mount "type=bind,src=$source_dir,dst=/src" \
            --mount "type=bind,src=$PWD/build-distro,dst=/logs" \
            -e "SOMEWM_TEST_LOG_DIR=/logs/$leg-tests" \
            "somewm-distro:$leg" bash -c 'cat > /tmp/distro.sh && exec bash /tmp/distro.sh "$@"' bash "$leg" \
            < tests/distro/container.sh 2>&1 | record || status=$?
        step=$(awk '/^STEP FAIL / { print $3 }' "$log" | paste -sd, -)
        if (( status )) && [[ -z $step ]]; then step=container; fi
    fi
    if [[ -n $step ]]; then
        result="FAIL $leg ($step)"
        failed=1
        if [[ $step == image || $step == container ]]; then
            tail -n 30 "$log"
        else
            while read -r failure; do
                output=build-distro/$leg-$failure-step.log
                awk '/^COMMAND:/ { command=$0 } END { print command }' "$output"
                if grep -q '^ERROR:' "$output" && [[ $failure != smoke ]]; then
                    grep '^ERROR:' "$output" | head -n 5
                elif [[ $failure == unit || $failure == integration ]]; then
                    awk -f tests/distro/failure.awk "$output"
                    test_name=$(awk '/^--- FAIL:/ { print $3; exit }' "$output")
                    if [[ -n $test_name && -f build-distro/$leg-tests/$test_name.log ]]; then
                        printf 'First integration failure: %s\n' "$test_name"
                        awk -v first=1 -f tests/distro/failure.awk "build-distro/$leg-tests/$test_name.log"
                    fi
                else
                    awk -v first=1 -f tests/distro/failure.awk "$output"
                fi
            done < <(awk '/^STEP FAIL / { print $3 }' "$log")
        fi
    else
        result="PASS $leg"
    fi
    result+=" ($((SECONDS - started))s)"
    printf '%s\n' "$result"
    printf '%s\n' "$result" > "$snapshot/$index.result"
    return "$failed"
}

results=()
failed=0
next=0
while (( next < ${#selected[@]} || ${#active[@]} )); do
    while (( next < ${#selected[@]} && ${#active[@]} < jobs )); do
        slot=${free_slots[0]}
        free_slots=("${free_slots[@]:1}")
        slots[$next]=$slot
        (
            set +m
            index=$next
            trap 'code=$?; printf "%s %s\n" "$index" "$code" >&"$events"' EXIT
            failed=0
            if (( jobs == 1 )); then
                run_leg "$next" "${selected[$next]}" "${cpus[$slot]}"
            else
                run_leg "$next" "${selected[$next]}" "${cpus[$slot]}" > "$snapshot/$next.output" 2>&1
            fi
        ) &
        active[$next]=$!
        next=$((next + 1))
    done
    read -r index status <&"$events"
    wait "${active[$index]}" || true
    unset 'active[$index]'
    free_slots+=("${slots[$index]}")
    if (( jobs > 1 )); then cat "$snapshot/$index.output"; fi
    if [[ -f $snapshot/$index.result ]]; then
        results[$index]=$(cat "$snapshot/$index.result")
    else
        results[$index]="FAIL ${selected[$index]} (runner)"
        printf '%s\n' "${results[$index]}"
        status=1
    fi
    if (( status )); then failed=1; fi
done
printf '\nSummary\n'
printf '%s\n' "${results[@]}"
exit "$failed"
