# Sourced by ~/.zshenv / ~/.profile / ~/.bashrc.
# Loads /state/env.local: one KEY=value per line. Blank lines and lines
# starting with # are ignored. Values are NOT shell-expanded — no $VAR or
# command substitution. Keys protecting the execution chain are rejected.

if [ -r /state/env.local ]; then
    __sb_cr=$(printf '\r')
    __sb_tab=$(printf '\t')
    while IFS= read -r __sb_line || [ -n "$__sb_line" ]; do
        # Tolerate CRLF line endings (Windows / cross-edit).
        __sb_line=${__sb_line%"$__sb_cr"}
        # Trim leading spaces / tabs on the whole line.
        while :; do
            case "$__sb_line" in
                ' '*|"$__sb_tab"*) __sb_line=${__sb_line#?} ;;
                *) break ;;
            esac
        done
        case "$__sb_line" in
            ''|\#*) continue ;;
            *=*) ;;
            *)
                printf 'env-loader: skip malformed line: %s\n' "$__sb_line" >&2
                continue
                ;;
        esac
        __sb_name=${__sb_line%%=*}
        __sb_value=${__sb_line#*=}
        # Trim trailing spaces / tabs on name (so `FOO =bar` works); leave
        # value untouched — trailing whitespace there is the user's data.
        while :; do
            case "$__sb_name" in
                *' '|*"$__sb_tab") __sb_name=${__sb_name%?} ;;
                *) break ;;
            esac
        done
        case "$__sb_name" in
            ''|*[!A-Za-z0-9_]*|[0-9]*)
                printf 'env-loader: invalid name: %s\n' "$__sb_name" >&2
                continue
                ;;
            PATH|HOME|SHELL|USER|UID|LOGNAME|PWD|OLDPWD)
                printf 'env-loader: refusing to override reserved key: %s\n' "$__sb_name" >&2
                continue
                ;;
        esac
        export "$__sb_name=$__sb_value"
    done < /state/env.local
    unset __sb_line __sb_name __sb_value __sb_cr __sb_tab
fi
