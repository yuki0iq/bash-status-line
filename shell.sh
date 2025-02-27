if ! command -v rg > /dev/null; then
    echo "ripgrep is needed for 'shell' to run; nothing applied"
    return 1
fi


START_INVIS="$(echo -ne '\x01')"
END_INVIS="$(echo -ne '\x02')"
ESC="$(echo -ne '\e')"
BEL="$(echo -ne '\a')"
BOLD="$START_INVIS${ESC}[1m$END_INVIS"
RED="$START_INVIS${ESC}[31m$END_INVIS"
GREEN="$START_INVIS${ESC}[32m$END_INVIS"
YELLOW="$START_INVIS${ESC}[33m$END_INVIS"
PURPLE="$START_INVIS${ESC}[35m$END_INVIS"
CYAN="$START_INVIS${ESC}[36m$END_INVIS"
BLUE="$START_INVIS${ESC}[38;2;0;127;240m$END_INVIS"
PINK="$START_INVIS${ESC}[38;2;255;100;203m$END_INVIS"
PYYELLOW="$START_INVIS${ESC}[38;2;255;212;59m$END_INVIS"
LIGHTGREEN="$START_INVIS${ESC}[38;2;100;255;100m$END_INVIS"
LIGHTRED="$START_INVIS${ESC}[38;2;255;80;100m$END_INVIS"
GREY="$START_INVIS${ESC}[38;2;128;128;128m$END_INVIS"
RESET="$START_INVIS${ESC}[0m$END_INVIS"
START_TITLE="$START_INVIS$ESC]0;"
END_TITLE="$BEL$END_INVIS"
CURSOR_SAVE="$START_INVIS${ESC}[s"
CURSOR_RESTORE="$START_INVIS${ESC}[u"
CURSOR_UP="$START_INVIS${ESC}[A"
CURSOR_HOME="$START_INVIS${ESC}[G"

if [ "$PS1_MODE" == "text" ]; then
    BRANCH="on"
    NODE_PACKAGE="node:"
    NODE_INFO="node"
    PYTHON_PACKAGE="py:"
    PYTHON_INFO="py"
    EXEC_DURATION="took"
    RETURN_OK="OK"
    RETURN_FAIL="Failed"
    HOST_TEXT="at"
    USER_TEXT="as"
    READONLY="R/O"
else
    BRANCH=""
    NODE_PACKAGE=""
    NODE_INFO=""
    PYTHON_PACKAGE=""
    PYTHON_INFO=""
    EXEC_DURATION=""
    RETURN_OK="✓"
    RETURN_FAIL="✗"
    DEFAULT_HOST_TEXT="󰒋"
    HOST_TEXT="$((hostnamectl | rg '\s+Chassis: [a-z]+ (.+)' --replace '$1') || echo "$DEFAULT_HOST_TEXT")"
    USER_TEXT=""
    READONLY=""
fi


# How to "colorize" a string
#
# using colors table
#   F   C   A   6   0
# 255 203 153 100   0
# -> scientific "pick" moment
#
# allow (block too dark and too red)
# FCA60 FCA6 FCA60
# FCA60 0 FCA
# 
# block (r06 r00)
# 
# total 115 of 5^3 = 125, ban 10 highest
# store in BGR (ban 00r, 06r)
# 
# then for hash from 0 to 114
# B = hash / 25
# G = hash / 5 % 5
# R = hash % 5
COLOR_TABLE=(255 203 153 100 0)

colorize() {
    if [[ "$1" == "root" ]]; then
        printf "$RED%s$RESET" "$1"
    else
        local hash="$((0x$(sha256sum <<< "$1" | head -c 4) % 115))"
        local _r="$((hash / 25))"
        local _g="$((hash / 5 % 5))"
        local _b="$((hash % 5))"
        local r="${COLOR_TABLE[$_r]}"
        local g="${COLOR_TABLE[$_g]}"
        local b="${COLOR_TABLE[$_b]}"
        local set_color="${ESC}[38;2;${r};${g};${b}m"
        printf "$START_INVIS$set_color$END_INVIS%s$RESET" "$1"
    fi
}

HOSTUSER="$BOLD$YELLOW($HOST_TEXT $(colorize "$HOSTNAME")$BOLD$YELLOW)$RESET $BOLD${BLUE}[$USER_TEXT $(colorize "$USER")$BOLD$BLUE]$RESET"


INVALID_HOMES='^(/$|(/bin|/dev|/proc|/usr|/var)[/$])'

replace_home() {
    while IFS= read -r line; do
        if [[ "$line" =~ ([^:]*):([^:]*:){4}([^:]*):([^:]*) ]]; then
            local homedir="${BASH_REMATCH[3]}"
            local username="${BASH_REMATCH[1]}"
            local userpath="$BOLD$YELLOW~$username$RESET"
            if [[ ! "$homedir" =~ $INVALID_HOMES ]]; then
                local path="$1"
                local stripped_path="${path#"$homedir"}"
                if [[ "$stripped_path" != "$path" ]]; then
                    echo "$userpath$stripped_path"
                    return
                fi
            fi
        fi
    done < /etc/passwd
    echo "$1"
}

upfind() {
    local path="$PWD"
    while [[ "$path" != "/" ]] && [[ ! -e "$path/$1" ]]; do
        path="$(realpath "$path/..")"
    done
    if [[ -e "$path/$1" ]]; then
        echo "$path/$1"
    else
        return 1
    fi
}

get_current_time() {
    date +%s%3N
}

before_command_start() {
    async_prompt_pid=$(cat "/tmp/asyncpromptpid$$" 2>/dev/null)
    if [ -n "$async_prompt_pid" ]; then
        kill "$async_prompt_pid" 2>/dev/null
    fi
    start_time="${start_time:-"$(get_current_time)"}"
}

update_info() {
    command_duration="$(($(get_current_time) - start_time))"
    unset start_time
}

async_prompt() {
    exec >&2

    local gitroot
    gitroot="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$gitroot" ]; then
        # thanks to
        #    https://git-scm.com/docs/git-status
        #    https://github.com/romkatv/powerlevel10k
        # feature[:master] v1^2 *3 ~4 +5 !6 ?7
        #    (feature) Current LOCAL branch   -> # branch.head <name>
        #    (master) Remote branch IF DIFFERENT and not null   -> # branch.upstream <origin>/<name>
        #    1 commit behind, 2 commits ahead   -> # branch.ab +<ahead> -<behind>
        #    3 stashes   -> # stash <count>
        #    4 unmerged   -> XX
        #    5 staged   -> X.
        #    6 unstaged   -> .X
        #    7 untracked   -> ?

        local current=""
        local remote=""
        local behind=0
        local ahead=0
        local stashes=0
        local unmerged=0
        local staged=0
        local unstaged=0
        local untracked=0

        while IFS= read -r line; do
            if [[ "$line" =~ ^'?' ]]; then
                untracked=$((untracked + 1))
            elif [[ "$line" =~ ^u ]]; then
                unmerged=$((unmerged + 1))
            elif [[ "$line" =~ ^[12]\ [MTADRC]\. ]]; then
                staged=$((staged + 1))
            elif [[ "$line" =~ ^[12]\ [\.MTADRCU]{2} ]]; then
                unstaged=$((unstaged + 1))
            elif [[ "$line" =~ ^#\ (.*) ]]; then
                local rest="${BASH_REMATCH[1]}"
                if [[ "$rest" =~ ^stash\ ([0-9]+) ]]; then
                    stashes="${BASH_REMATCH[1]}"
                elif [[ "$rest" =~ ^branch\.([^ ]+)\ (.*) ]]; then
                    local cmd="${BASH_REMATCH[1]}"
                    local arg="${BASH_REMATCH[2]}"
                    if [[ "$cmd" == "head" ]]; then
                        current="$arg"
                    elif [[ "$cmd" == "upstream" ]]; then
                        remote="${arg//[^'/']*'/'/}"
                    elif [[ "$cmd" == "ab" ]] && [[ "$arg" =~ .([0-9]+)\ .([0-9]+) ]]; then
                        ahead="${BASH_REMATCH[1]}"
                        behind="${BASH_REMATCH[2]}"
                    fi
                fi
            fi
        done < <(git status --porcelain=2 --branch --show-stash)

        local gitinfo="$BOLD${PINK}["
        if [[ -n "$current" ]]; then
            local gitinfo="$gitinfo$BRANCH $current"
        fi
        if [[ "$remote" != "$current" && -n "$remote" ]]; then
            local gitinfo="$gitinfo:$remote"
        fi
        if [[ $behind != 0 ]]; then
            local gitinfo="$gitinfo v$behind"
        fi
        if [[ $ahead != 0 ]]; then
            local gitinfo="$gitinfo ^$ahead"
        fi
        if [[ $stashes != 0 ]]; then
            local gitinfo="$gitinfo *$stashes"
        fi
        if [[ $unmerged != 0 ]]; then
            local gitinfo="$gitinfo ~$unmerged"
        fi
        if [[ $staged != 0 ]]; then
            local gitinfo="$gitinfo +$staged"
        fi
        if [[ $unstaged != 0 ]]; then
            local gitinfo="$gitinfo !$unstaged"
        fi
        if [[ $untracked != 0 ]]; then
            local gitinfo="$gitinfo ?$untracked"
        fi
        local gitinfo="$gitinfo]$RESET "
    else
        local gitinfo=""
    fi

    local package_json
    local node_modules
    local nodeinfo
    package_json="$(upfind "package.json")"
    node_modules="$(upfind "node_modules")"
    if [ -n "$package_json" ] || [ -n "$node_modules" ]; then
        local name
        local version
        if [ -n "$package_json" ]; then
            name="$(jq -r .name "$package_json")"
            version=" $(jq -r .version "$package_json")"
        else
            name="unnamed"
            version=""
        fi
        local pkginfo="$BOLD${YELLOW}[$NODE_PACKAGE $name$version]$RESET "
        nodeinfo="$pkginfo$BOLD${GREEN}[$NODE_INFO $(nvm current | sed s/^v//)]$RESET "
    else
        nodeinfo=""
    fi


    local setup_py
    local requirements_txt
    setup_py="$(upfind setup.py)"
    requirements_txt="$(upfind requirements.txt)"
    if [ -n "$setup_py" ] || [ -n "$requirements_txt" ]; then
        local name
        local version
        if [ -n "$setup_py" ]; then
            name="$(rg "name=['\"](.+)['\"]" "$setup_py" -or '$1' -m 1)"
            version=" $(rg "version=['\"](.+)['\"]" "$setup_py" -or '$1' -m 1)"
        else
            name="unnamed"
            version=""
        fi
        local pypkginfo="$BOLD${YELLOW}[$PYTHON_PACKAGE $name$version]$RESET "

        local pyenv_cfg="$VIRTUAL_ENV/pyvenv.cfg"
        local pyversion
        if [ -f "$pyenv_cfg" ]; then
            pyversion="$(rg 'version\s*=\s*' "$pyenv_cfg" -r '' -m 1)"
        else    
            pyversion="system"
        fi
        local pyinfo="$pkginfo$BOLD${PYYELLOW}[$PYTHON_INFO $pyversion]$RESET "
    else
        local pypkginfo=""
        local pyinfo=""
    fi

    local buildinfo=""
    if [ -f CMakeLists.txt ]; then
        local buildinfo="${buildinfo}cmake "
    fi
    if [ -f configure ]; then
        local buildinfo="${buildinfo}./configure "
    fi
    if [ -f Makefile ]; then
        local buildinfo="${buildinfo}make "
    fi
    if [ -f install ]; then
        local buildinfo="${buildinfo}./install "
    fi
    if [ -f jr ]; then
        local buildinfo="${buildinfo}./jr "
    fi
    if compgen -G "*.qbs" > /dev/null; then
        local buildinfo="${buildinfo}qbs "
    fi
    if compgen -G "*.pro" > /dev/null; then
        local buildinfo="${buildinfo}qmake "
    fi
    if [ -n "$(upfind Cargo.toml)" ]; then
        local buildinfo="${buildinfo}cargo "
    fi
    if [ -n "$buildinfo" ]; then
        local buildinfo="$BOLD${PURPLE}[${buildinfo%?}]$RESET "
    fi

    local curdir
    curdir="$(
        ( [[ "$PWD" == "$gitroot" ]] && echo "$PWD/" || echo "$PWD" ) |
        ( if [ -n "$gitroot" ]; then rg "^($gitroot)(.*)" -r "\$1$CYAN\$2$RESET"; else cat; fi ) |
        rg "^$HOME" -r "$BOLD$YELLOW~$RESET" --passthru
    )"
    curdir="$(replace_home "$curdir")"

    if [ ! -w "$PWD" ]; then
        curdir="$RED$READONLY$RESET $curdir"
    fi

    if [[ $command_duration -gt 1000 ]]; then
        local runtime=" $CYAN($EXEC_DURATION $((command_duration / 1000))s)$RESET"
    else
        local runtime=""
    fi

    local cur_date
    cur_date="$(LC_TIME=en_US.UTF-8 date +'%a, %Y-%b-%d, %H:%M:%S in %Z')"

    echo -n "$CURSOR_SAVE$CURSOR_UP$CURSOR_HOME"

    if [ -n "$PS1_PREFIX" ]; then
        echo -n "$BOLD$RED$PS1_PREFIX$RESET "
    fi

    echo -n "$HOSTUSER $gitinfo$nodeinfo$pypkginfo$pyinfo$buildinfo$curdir$runtime"
    echo -n "${ESC}[$((COLUMNS - ${#cur_date}))G$GREY$cur_date$RESET"

    echo -n "$CURSOR_RESTORE"

    rm "/tmp/asyncpromptpid$$"
}

get_shell_ps1() {
    local retcode="$?"

    echo -n "$START_TITLE$PWD$END_TITLE"

    if [[ $retcode -eq 0 ]] || [[ $retcode -eq 130 ]]; then
        local retinfo="$LIGHTGREEN$RETURN_OK$RESET "
    else
        local retinfo="$LIGHTRED$RETURN_FAIL$RESET "
    fi

    if [[ "$UID" == "0" ]]; then
        local cursor="$BOLD$RED#$RESET"
    else
        local cursor="$BOLD$GREEN\$$RESET"
    fi

    # TODO maybe update?
    local jobs
    local jobinfo
    jobs="$(jobs | wc -l)"
    if [[ "$jobs" == "0" ]]; then
        jobinfo=""
    else
        if [[ "$jobs" == "1" ]]; then
            jobinfo="$BOLD${GREEN}[1 job]$RESET "
        else
            jobinfo="$BOLD${GREEN}[$jobs jobs]$RESET "
        fi
    fi

    local cur_date
    cur_date="$(LC_TIME=en_US.UTF-8 date +'%a, %Y-%b-%d, %H:%M:%S in %Z')"
    printf "\n%s\n%s" "$HOSTUSER${ESC}[$((COLUMNS - ${#cur_date}))G$GREY$cur_date$RESET" "$jobinfo$retinfo$cursor "

    async_prompt >/dev/null &
    echo "$!" >"/tmp/asyncpromptpid$$"
}


trap "before_command_start" DEBUG
PROMPT_COMMAND=update_info
PS1="\$(get_shell_ps1)"

export VIRTUAL_ENV_DISABLE_PROMPT=1
