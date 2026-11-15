first {
    if ($0 ~ / W: / || $0 ~ /^WARNING:/) next
    if (tolower($0) ~ /error:|error loading|error while running|lua.*error|(module|require).*not found|permission denied|no such file|[.]lua:[0-9]+/) {
        print
        found = 1
        exit
    }
    last = $0
    next
}
END { if (first && !found) print last }
/^(Failure|Error) (->|→)/ {
    if (unit++) exit
    show = 1
}
/^[0-9]+\/[0-9]+ .* (FAIL|ERROR|TIMEOUT)/ {
    if (unit++) exit
    show = 1
}
/^check-lua-compat:.*(FAILED|required but not installed|no Lua interpreter found)/ { print; exit }
/^Error:|^lua\/.*:[0-9]+:/ { show = 1 }
/^--- (PASS|FAIL|SKIP):/ { exit }
/^make(\[[0-9]+\])?:/ && show { exit }
show { print }
