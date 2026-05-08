# Sourced by ~/.zshenv / ~/.profile / ~/.bashrc.
# Loads /state/env.local: one KEY=value per line. Blank lines and lines
# starting with # are ignored. Values are NOT shell-expanded — no $VAR or
# command substitution. Keys protecting the execution chain are rejected.

if [ -r /state/env.local ]; then
    while IFS= read -r __sb_line || [ -n "$__sb_line" ]; do
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
    unset __sb_line __sb_name __sb_value
fi
