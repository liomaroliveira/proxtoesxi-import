#!/usr/bin/env bash
# ==============================================================================
# Proxmox VM Exporter & Migrator - V5
# ==============================================================================

# ==============================================================================
# 1. Gestão de Dependências
# ==============================================================================
DEPENDENCIES=("sshpass" "pv" "rsync")
MISSING_DEPS=()
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &> /dev/null; then MISSING_DEPS+=("$dep"); fi
done
if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "[!] Instalando dependências ausentes: ${MISSING_DEPS[*]}..."
    apt-get update -qq && apt-get install -y -qq "${MISSING_DEPS[@]}" > /dev/null 2>&1
fi

# ==============================================================================
# Variáveis de Estado Global
# ==============================================================================
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/pve_export_interativo_${TIMESTAMP}.log"
TEMP_DIR="/tmp/pve_export_$$"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no"

IS_CRON_MODE=0
TARGET_IP=""
TARGET_USER=""
TARGET_PASS=""
ACTION_IN_PROGRESS=0
TEMP_BACKUP_FILE=""
CURRENT_TARGET_VMID=""

mkdir -p "$TEMP_DIR"

# ==============================================================================
# Funções de Log e Tratamento de Interrupção
# ==============================================================================
log() {
    local MSG="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$MSG" | tee -a "$LOG_FILE"
}

rollback() {
    log "⚠️ INICIANDO ROLLBACK..."
    if [[ $ACTION_IN_PROGRESS -eq 1 ]]; then
        if [[ -n "$TEMP_BACKUP_FILE" && -f "$TEMP_BACKUP_FILE" ]]; then
            log "Limpando backup local incompleto: $TEMP_BACKUP_FILE"
            rm -f "$TEMP_BACKUP_FILE"
        fi
        if [[ -n "$CURRENT_TARGET_VMID" && -n "$TARGET_IP" ]]; then
            log "Tentando limpar VM $CURRENT_TARGET_VMID órfã no destino ($TARGET_IP)..."
            sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qm destroy $CURRENT_TARGET_VMID --purge 1 >/dev/null 2>&1 || true; rm -f /var/lib/vz/dump/*${CURRENT_TARGET_VMID}* >/dev/null 2>&1 || true"
        fi
    fi
    ACTION_IN_PROGRESS=0
}

handle_interrupt() {
    echo ""
    log "⛔ INTERRUPÇÃO DETECTADA (Ctrl+C ou Erro)."
    rollback
    echo "----------------------------------------------------------"
    read -p "Pressione ENTER para retornar ao Menu Principal ou digite 'q' para sair: " ans
    if [[ "$ans" == "q" || "$ans" == "Q" ]]; then
        rm -rf "$TEMP_DIR"
        exit 1
    else
        main_menu
    fi
}
trap 'handle_interrupt' SIGINT SIGTERM

# ==============================================================================
# Gerenciamento de Cron Jobs Existentes e Fluxo Inicial
# ==============================================================================
manage_existing_crons() {
    clear
    echo "=========================================================="
    echo " GERENCIADOR DE AGENDAMENTOS (CRON)"
    echo "=========================================================="
    
    local cron_files=(/etc/cron.d/pve_export_*)
    if [[ -e "${cron_files[0]}" ]]; then
        echo "Agendamentos ativos encontrados:"
        echo -e "ID\tARQUIVO"
        local count=1
        declare -A cron_map
        for file in "${cron_files[@]}"; do
            echo -e "[$count]\t$(basename "$file")"
            cron_map[$count]="$file"
            ((count++))
        done
        
        echo ""
        read -p "Digite o ID para excluir, 'todos' para limpar, ou ENTER para ignorar: " cron_choice
        
        if [[ "$cron_choice" == "todos" ]]; then
            rm -f /etc/cron.d/pve_export_*
            echo "Todos os agendamentos foram removidos."
            sleep 2
        elif [[ -n "${cron_map[$cron_choice]}" ]]; then
            rm -f "${cron_map[$cron_choice]}"
            echo "Agendamento ${cron_map[$cron_choice]} removido."
            sleep 2
        fi
    else
        echo "Nenhum agendamento ativo encontrado."
        echo "----------------------------------------------------------"
    fi
}

ask_execution_mode() {
    echo ""
    read -p "Deseja gerar um agendamento (Cron) para execução autônoma? (s/N): " cron_ans
    if [[ "$cron_ans" == "s" || "$cron_ans" == "S" ]]; then
        IS_CRON_MODE=1
        log "Modo selecionado: CRIAÇÃO DE AGENDAMENTO (Wizard)."
    else
        IS_CRON_MODE=0
        log "Modo selecionado: EXECUÇÃO INTERATIVA."
    fi
}

ask_credentials() {
    if [[ -z "$TARGET_IP" ]]; then
        echo ""
        read -p "IP do Servidor Destino: " TARGET_IP
        read -p "Usuário SSH (ex: root): " TARGET_USER
        read -s -p "Senha SSH: " TARGET_PASS
        echo ""
        log "Testando conectividade..."
        if sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "exit" &>/dev/null; then
            log "✅ Conexão SSH estabelecida."
        else
            log "❌ Falha na conexão. Abortando."
            exit 1
        fi
    fi
}

# ==============================================================================
# Helpers de Automação (Origem e Destino)
# ==============================================================================
get_source_vms() {
    log "Mapeando VMs locais..."
    local vms=$(qm list | awk 'NR>1 {print $1, $2, $3}')
    local count=1
    declare -A vm_map
    echo -e "ID\tVMID\tNOME\t\tSTATUS"
    while read -r vmid name status; do
        echo -e "[$count]\t$vmid\t$name\t\t$status"
        vm_map[$count]="$vmid"
        ((count++))
    done <<< "$vms"
    echo ""
    read -p "Selecione as VMs a processar (separe por espaço, ex: 1 3): " vm_selections
    SELECTED_VMS=()
    for sel in $vm_selections; do
        if [[ -n "${vm_map[$sel]}" ]]; then SELECTED_VMS+=("${vm_map[$sel]}"); fi
    done
    if [ ${#SELECTED_VMS[@]} -eq 0 ]; then
        log "Nenhuma VM válida. Retornando..."
        handle_interrupt
    fi
}

get_local_storage_for_backup() {
    log "Mapeando storages locais com suporte a backup (vzdump)..."
    local storages=$(pvesm status -content backup | awk 'NR>1 {print $1, $2, $4}')
    local count=1
    declare -A st_map
    echo -e "ID\tNOME_ORIGEM\tTIPO\tLIVRE"
    while read -r name type free_bytes; do
        local free_gb=$((free_bytes / 1024 / 1024 / 1024))
        echo -e "[$count]\t$name\t\t$type\t${free_gb}GB"
        st_map[$count]="$name|$free_gb"
        ((count++))
    done <<< "$storages"
    echo ""
    read -p "Selecione o storage para o backup temporário: " st_sel
    local sel_data=${st_map[$st_sel]}
    if [[ -z "$sel_data" ]]; then handle_interrupt; fi
    LOCAL_STORAGE_NAME=$(echo "$sel_data" | cut -d'|' -f1)
    log "Selecionado: $LOCAL_STORAGE_NAME"
}

get_target_storages() {
    log "Mapeando storages no destino ($TARGET_IP)..."
    local storages=$(sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "pvesm status -content images | awk 'NR>1 {print \$1, \$2, \$4}'")
    local count=1
    declare -A st_map
    echo -e "ID\tNOME_DESTINO\tTIPO\tLIVRE"
    while read -r name type free_bytes; do
        local free_gb=$((free_bytes / 1024 / 1024 / 1024))
        echo -e "[$count]\t$name\t\t$type\t${free_gb}GB"
        st_map[$count]="$name"
        ((count++))
    done <<< "$storages"
    echo ""
    read -p "Selecione o storage remoto para restaurar as VMs: " st_sel
    TARGET_STORAGE=${st_map[$st_sel]}
    if [[ -z "$TARGET_STORAGE" ]]; then handle_interrupt; fi
    log "Selecionado remoto: $TARGET_STORAGE"
}

# ==============================================================================
# Execução Lógica (Backup SCP / Pipe)
# ==============================================================================
execute_backup_scp() {
    get_source_vms
    get_local_storage_for_backup
    get_target_storages

    if [[ $IS_CRON_MODE -eq 1 ]]; then
        generate_cron_script "scp"
        return
    fi

    for SRC_VMID in "${SELECTED_VMS[@]}"; do
        ACTION_IN_PROGRESS=1
        CURRENT_TARGET_VMID=$(sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "pvesh get /cluster/nextid")
        
        log "--------------------------------------------------------"
        log "Iniciando Backup Local da VM $SRC_VMID..."
        if ! vzdump $SRC_VMID --storage $LOCAL_STORAGE_NAME --compress zstd --mode snapshot > "$TEMP_DIR/dump.log" 2>&1; then
            log "❌ Falha no vzdump."
            cat "$TEMP_DIR/dump.log" >> "$LOG_FILE"
            handle_interrupt
        fi
        
        TEMP_BACKUP_FILE=$(grep "creating archive" "$TEMP_DIR/dump.log" | awk -F"'" '{print $2}')
        log "✅ Backup gerado: $TEMP_BACKUP_FILE. Transferindo..."

        sshpass -p "$TARGET_PASS" rsync -a --info=progress2 "$TEMP_BACKUP_FILE" ${TARGET_USER}@${TARGET_IP}:/var/lib/vz/dump/ | while read line; do
            echo -ne "$line\r"
            if [[ "$line" =~ (10%|20%|30%|40%|50%|60%|70%|80%|90%|100%) ]]; then
                echo "[Rsync] $line" >> "$LOG_FILE"
            fi
        done
        echo ""

        REMOTE_FILE="/var/lib/vz/dump/$(basename "$TEMP_BACKUP_FILE")"
        log "Restaurando $REMOTE_FILE no destino como ID $CURRENT_TARGET_VMID..."
        
        if ! sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qmrestore $REMOTE_FILE $CURRENT_TARGET_VMID --storage $TARGET_STORAGE"; then
            log "❌ Falha no qmrestore remoto."
            handle_interrupt
        fi

        log "Limpando artefatos..."
        rm -f "$TEMP_BACKUP_FILE"
        sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "rm -f $REMOTE_FILE"
        ACTION_IN_PROGRESS=0
        log "🎉 VM $SRC_VMID exportada com sucesso."
    done
}

execute_direct_pipe() {
    get_source_vms
    get_target_storages

    if [[ $IS_CRON_MODE -eq 1 ]]; then
        generate_cron_script "pipe"
        return
    fi

    for SRC_VMID in "${SELECTED_VMS[@]}"; do
        ACTION_IN_PROGRESS=1
        CURRENT_TARGET_VMID=$(sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "pvesh get /cluster/nextid")
        
        log "--------------------------------------------------------"
        log "Iniciando Pipe Direto: VM $SRC_VMID -> Destino ID $CURRENT_TARGET_VMID..."
        
        vzdump $SRC_VMID --stdout --mode snapshot 2>>"$LOG_FILE" | pv -pteb | sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qmrestore - $CURRENT_TARGET_VMID --storage $TARGET_STORAGE"
        local STATUS=("${PIPESTATUS[@]}")
        
        if [[ ${STATUS[0]} -eq 0 && ${STATUS[2]} -eq 0 ]]; then
            log "🎉 VM $SRC_VMID exportada com sucesso."
        else
            log "❌ Erro no Pipe. vzdump=${STATUS[0]}, pv=${STATUS[1]}, ssh=${STATUS[2]}"
            handle_interrupt
        fi
        ACTION_IN_PROGRESS=0
    done
}

# ==============================================================================
# Geração de Agendamento Simplificado (Cron)
# ==============================================================================
generate_cron_script() {
    local METHOD=$1
    echo "=========================================================="
    echo " CONFIGURAÇÃO DE AGENDAMENTO SIMPLIFICADA"
    echo "=========================================================="
    
    # Defaults do Cron
    local CRON_MIN="*"
    local CRON_HR="*"
    local CRON_DOM="*"
    local CRON_MON="*"
    local CRON_DOW="*"
    local RUN_ONCE="n"
    
    read -p "Digite o horário de execução (HH:MM, ex: 03:30): " EXEC_TIME
    CRON_HR=$(echo "$EXEC_TIME" | cut -d: -f1)
    CRON_MIN=$(echo "$EXEC_TIME" | cut -d: -f2)
    
    read -p "A execução será recorrente? (s/N) [Padrão: n]: " IS_RECURRING
    IS_RECURRING=${IS_RECURRING:-n}
    
    if [[ "$IS_RECURRING" == "n" || "$IS_RECURRING" == "N" ]]; then
        RUN_ONCE="s"
        log "Cron Wizard: Execução ÚNICA selecionada."
        echo "1) Hoje"
        echo "2) Amanhã"
        echo "3) Data Específica"
        read -p "Selecione o dia da execução: " DIA_OPCAO
        
        case $DIA_OPCAO in
            1) 
                CRON_DOM=$(date +%d)
                CRON_MON=$(date +%m)
                log "Cron Wizard: Execução agendada para HOJE ($CRON_DOM/$CRON_MON) às $EXEC_TIME"
                ;;
            2)
                CRON_DOM=$(date -d "tomorrow" +%d)
                CRON_MON=$(date -d "tomorrow" +%m)
                log "Cron Wizard: Execução agendada para AMANHÃ ($CRON_DOM/$CRON_MON) às $EXEC_TIME"
                ;;
            3)
                read -p "Digite a data (DD/MM, ex: 25/12): " EXEC_DATE
                CRON_DOM=$(echo "$EXEC_DATE" | cut -d/ -f1)
                CRON_MON=$(echo "$EXEC_DATE" | cut -d/ -f2)
                log "Cron Wizard: Execução agendada para DATA ESPECÍFICA ($CRON_DOM/$CRON_MON) às $EXEC_TIME"
                ;;
            *)
                echo "Opção inválida."
                handle_interrupt
                ;;
        esac
    else
        RUN_ONCE="n"
        log "Cron Wizard: Execução RECORRENTE selecionada."
        echo "1) Todos os dias"
        echo "2) Dias da semana específicos"
        echo "3) Dias do mês específicos"
        read -p "Selecione a frequência: " FREQ_OPCAO
        
        case $FREQ_OPCAO in
            1)
                log "Cron Wizard: Frequência TODOS OS DIAS às $EXEC_TIME"
                ;;
            2)
                echo "0=Dom, 1=Seg, 2=Ter, 3=Qua, 4=Qui, 5=Sex, 6=Sáb"
                read -p "Digite os números separados por vírgula (ex: 1,3,5 para Seg,Qua,Sex): " CRON_DOW
                log "Cron Wizard: Frequência DIAS DA SEMANA [$CRON_DOW] às $EXEC_TIME"
                ;;
            3)
                read -p "Digite os dias do mês separados por vírgula (ex: 1,15,30): " CRON_DOM
                log "Cron Wizard: Frequência DIAS DO MÊS [$CRON_DOM] às $EXEC_TIME"
                ;;
            *)
                echo "Opção inválida."
                handle_interrupt
                ;;
        esac
    fi

    log "Ajustando chaves SSH para execução sem senha..."
    KEY_PATH="$HOME/.ssh/id_ed25519"
    if [[ ! -f "$KEY_PATH" ]]; then ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q; fi
    sshpass -p "$TARGET_PASS" ssh-copy-id -i "$KEY_PATH.pub" ${TARGET_USER}@${TARGET_IP} >/dev/null 2>&1

    JOB_NAME="pve_export_${TIMESTAMP}"
    JOB_SCRIPT="/usr/local/bin/${JOB_NAME}.sh"
    JOB_LOG="/var/log/${JOB_NAME}.log"

    # Criação do Script Base
    cat << 'EOF' > "$JOB_SCRIPT"
#!/usr/bin/env bash
EOF
    echo "TARGET_IP=\"$TARGET_IP\"" >> "$JOB_SCRIPT"
    echo "TARGET_USER=\"$TARGET_USER\"" >> "$JOB_SCRIPT"
    echo "TARGET_STORAGE=\"$TARGET_STORAGE\"" >> "$JOB_SCRIPT"
    echo "LOCAL_STORAGE_NAME=\"$LOCAL_STORAGE_NAME\"" >> "$JOB_SCRIPT"
    echo "JOB_LOG=\"$JOB_LOG\"" >> "$JOB_SCRIPT"
    echo "VMS_ARRAY=(${SELECTED_VMS[@]})" >> "$JOB_SCRIPT"

    # Injeção da Lógica de Exportação
    if [[ "$METHOD" == "pipe" ]]; then
        cat << 'EOF' >> "$JOB_SCRIPT"
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$JOB_LOG"; }
for SRC_VMID in "${VMS_ARRAY[@]}"; do
    TARGET_VMID=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "pvesh get /cluster/nextid")
    log "Executando Pipe: VM $SRC_VMID para novo ID $TARGET_VMID..."
    vzdump $SRC_VMID --stdout --mode snapshot 2>>"$JOB_LOG" | ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "qmrestore - $TARGET_VMID --storage $TARGET_STORAGE"
    STATUS=("${PIPESTATUS[@]}")
    if [[ ${STATUS[0]} -ne 0 || ${STATUS[1]} -ne 0 ]]; then
        log "ERRO: Desfazendo VM $TARGET_VMID"
        ssh -o BatchMode=yes ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID --purge 1 || true"
    fi
done
EOF
    elif [[ "$METHOD" == "scp" ]]; then
        cat << 'EOF' >> "$JOB_SCRIPT"
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$JOB_LOG"; }
for SRC_VMID in "${VMS_ARRAY[@]}"; do
    TARGET_VMID=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "pvesh get /cluster/nextid")
    log "Gerando Backup local da VM $SRC_VMID..."
    vzdump $SRC_VMID --storage $LOCAL_STORAGE_NAME --compress zstd --mode snapshot > /tmp/cron_dump.log 2>&1
    TEMP_FILE=$(grep "creating archive" /tmp/cron_dump.log | awk -F"'" '{print $2}')
    REMOTE_FILE="/var/lib/vz/dump/$(basename "$TEMP_FILE")"
    log "Transferindo e restaurando como ID $TARGET_VMID..."
    rsync -a "$TEMP_FILE" ${TARGET_USER}@${TARGET_IP}:/var/lib/vz/dump/
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "qmrestore $REMOTE_FILE $TARGET_VMID --storage $TARGET_STORAGE"
    rm -f "$TEMP_FILE"
    ssh -o BatchMode=yes ${TARGET_USER}@${TARGET_IP} "rm -f $REMOTE_FILE"
done
EOF
    fi

    # Lógica de Autodestruição para Tarefas de Uso Único
    if [[ "$RUN_ONCE" == "s" || "$RUN_ONCE" == "S" ]]; then
        echo "rm -f /etc/cron.d/${JOB_NAME}" >> "$JOB_SCRIPT"
        echo "rm -f $JOB_SCRIPT" >> "$JOB_SCRIPT" # O script também se apaga após remover o cron
    fi

    chmod +x "$JOB_SCRIPT"
    
    # Validação do agendamento (Remove zeros à esquerda soltos do parser humano, pois cron exige '08' ou '8', mas prefere sem zeros para dias do mês)
    CRON_DOM=$(echo "$CRON_DOM" | sed 's/^0*//')
    [[ -z "$CRON_DOM" ]] && CRON_DOM="*"

    echo "$CRON_MIN $CRON_HR $CRON_DOM $CRON_MON $CRON_DOW root $JOB_SCRIPT" > "/etc/cron.d/${JOB_NAME}"
    chmod 644 "/etc/cron.d/${JOB_NAME}"
    
    log "✅ Agendamento Salvo: /etc/cron.d/${JOB_NAME}"
    log "Sintaxe Cron Gerada: $CRON_MIN $CRON_HR $CRON_DOM $CRON_MON $CRON_DOW"
    
    echo ""
    read -p "Pressione ENTER para voltar ao menu..."
}

# ==============================================================================
# Menu Principal
# ==============================================================================
main_menu() {
    while true; do
        clear
        echo "=========================================================="
        echo " MIGRATOR & EXPORTER PROXMOX"
        echo "=========================================================="
        echo "Arquivo de Log: $LOG_FILE"
        echo "Modo Atual: $( [[ $IS_CRON_MODE -eq 1 ]] && echo 'AGENDAMENTO (Gerar Cron)' || echo 'EXECUÇÃO IMEDIATA' )"
        echo "----------------------------------------------------------"
        echo "1) Exportação: SSH Backup & Restore (Seguro, gera arquivo local, transfere e restaura)"
        echo "2) Exportação: SSH Pipe Direto (Streaming direto para o destino, sem uso de disco)"
        echo "3) Replicação ZFS (ZFS Send/Receive - *Stub*)"
        echo "4) Migração Nativa (Cluster Proxmox - *Stub*)"
        echo "5) Backups Locais/Remotos/USB (*Stub*)"
        echo "0) Sair"
        echo ""
        read -p "Selecione o método de execução: " OPTION
        
        case $OPTION in
            1) ask_credentials; execute_backup_scp ;;
            2) ask_credentials; execute_direct_pipe ;;
            3|4|5) echo "Em desenvolvimento. Retornando..."; sleep 1 ;;
            0) rm -rf "$TEMP_DIR"; exit 0 ;;
            *) echo "Opção inválida."; sleep 1 ;;
        esac
    done
}

# Boot Flow
manage_existing_crons
ask_execution_mode
main_menu