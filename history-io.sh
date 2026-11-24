# Called with sh and separate path arguments. The wire format is shared with the Windows reader.
set -eu
operation=$1
shift
prefix() {
    if [ -f "$1" ] && [ ! -L "$1" ]; then
        head -c 32768 "$1" 2>/dev/null | base64 | tr -d '\r\n'
    fi
    printf '\n'
}
case "$operation" in
    archive)
        case "$PT_ARCHIVE_BATCH" in ''|*[!0-9a-f]*) exit 1 ;; esac
        [ "${#PT_ARCHIVE_BATCH}" -eq 64 ] || exit 1
        mkdir -p "$PT_ARCHIVE_DIR"
        target="$PT_ARCHIVE_DIR/$PT_ARCHIVE_BATCH.set"
        [ ! -f "$target" ] || exit 0
        tmp=$(mktemp "$PT_ARCHIVE_DIR/.batch.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp"
        mv -f "$tmp" "$target" ;;
    list)
        root=$1
        if [ "$#" -gt 1 ] && [ -d "$2" ]; then root=$2/sessions; fi
        [ -e "$root" ] || exit 0
        [ -d "$root" ] && [ -r "$root" ] || exit 1
        if [ "$(uname -s)" = Darwin ]; then
            find "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -exec sh -c '
                for file do
                    meta=$(stat -f '%m %z' "$file") || continue
                    printf "%s\t%s\t%s\000" "${meta% *}" "${meta#* }" "$file"
                done' sh {} +
        else
            find "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%T@\t%s\t%p\0'
        fi ;;
    read) xargs -0 sh "$0" read-batch ;;
    read-batch) for file do printf ':'; prefix "$file"; done ;;
    check) if [ -d "$2" ]; then prefix "$1"; else printf 'missing-cwd'; fi ;;
esac
