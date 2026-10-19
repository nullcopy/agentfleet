# bash completion for agentctl (agentfleet)
_agentctl() {
    local cur prev words cword
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    cword=$COMP_CWORD
    local cmds="list add edit rm purge start stop restart status reset-config logs matrix secrets"
    local cmd=${COMP_WORDS[1]}

    if (( cword == 1 )); then
        COMPREPLY=($(compgen -W "$cmds --help" -- "$cur"))
        return
    fi

    local names="" opts=""
    case $cmd in
        add)
            opts="--model --description --memory-max --cpu-quota --env --set --set-str --secret --no-prompt --no-start"
            case $prev in
                --model|--description|--memory-max|--cpu-quota|--env|--set|--set-str|--secret) return ;;
            esac
            ;;
        edit)
            opts="--model --description --memory-max --cpu-quota --env --unset-env --set --set-str --unset --no-restart"
            case $prev in
                --model|--description|--memory-max|--cpu-quota|--env|--unset-env|--set|--set-str|--unset) return ;;
            esac
            (( cword == 2 )) && names="$(agentctl names 2>/dev/null) $(agentctl names --removed 2>/dev/null)"
            ;;
        rm)
            opts="--purge --yes"
            names=$(agentctl names 2>/dev/null)
            ;;
        reset-config)
            opts="--yes"
            names="$(agentctl names 2>/dev/null) $(agentctl names --removed 2>/dev/null)"
            ;;
        purge)
            opts="--yes"
            names="$(agentctl names 2>/dev/null) $(agentctl names --removed 2>/dev/null)"
            ;;
        start|stop|restart)
            opts="--all"
            names=$(agentctl names 2>/dev/null)
            ;;
        status|logs)
            [[ $cmd == logs ]] && opts="-f --follow -n --lines"
            [[ $prev == -n || $prev == --lines ]] && return
            names=$(agentctl names 2>/dev/null)
            ;;
        secrets)
            if (( cword == 2 )); then
                COMPREPLY=($(compgen -W "set edit list" -- "$cur"))
                return
            fi
            (( cword == 3 )) && names=$(agentctl names 2>/dev/null)
            ;;
        matrix)
            if (( cword == 2 )); then
                COMPREPLY=($(compgen -W "status check introduce rotate-token start stop restart logs" -- "$cur"))
                return
            fi
            case ${COMP_WORDS[2]} in
                introduce|rotate-token) (( cword == 3 )) && names=$(agentctl names 2>/dev/null) ;;
                logs) opts="-f --follow -n --lines" ;;
            esac
            ;;
    esac

    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts --help" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "$names" -- "$cur"))
    fi
}
complete -F _agentctl agentctl
