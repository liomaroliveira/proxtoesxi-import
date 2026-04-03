#!/usr/bin/env bash
# ==============================================================================
# Migrator Proxmox - V3
# ==============================================================================

set -eE -o pipefail

# ==============================================================================
# 1. Gestão de Dependências
# ==============================================================================
DEPENDENCIES=("sshpass" "pv" "rsync")
MISSING_DEPS=()

for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "[!] Instalando dependências ausentes: ${MISSING_DEPS[*]}..."
    apt-get update -qq
    apt-get install -y -qq "${MISSING_DEPS[@]}" > /dev/null 2>&1
    echo "[!] Dependências instaladas."
fi

# ==============================================================================
# Variáveis de Configuração Global
# ==============================================================================
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/proxmox_migration_${TIMESTAMP}.log"
TEMP_DIR="/tmp/pve_migrate_$$"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no"

TARGET_IP=""
TARGET_USER=""
TARGET_PASS=""
TARGET_STORAGE=""
ACTION_IN_PROGRESS=0
CRON_MODE=0

mkdir -p "$TEMP_DIR"

# ==============================================================================
# Funções de Base e Tratamento de Erros
# ==============================================================================
log() {
    local MSG="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$MSG" | tee -a "$LOG_FILE"
}

error_handler() {
    local line=$1
    local exit_code=$2
    log "❌ ERRO CRÍTICO: Comando falhou na linha $line com código $exit_code."
    cleanup
}
trap 'error_handler ${LINENO} $?' ERR

cleanup() {
    trap - ERR
    if [[ $CRON_MODE -eq 0 ]]; then
        log "⚠️ SINAL DE INTERRUPÇÃO OU ERRO DETECTADO. Encerrando."
    fi
    # O rollback específico por VM é tratado dentro do loop de execução agora
    rm -rf "$TEMP_DIR"
    exit 1
}
trap cleanup SIGINT SIGTERM

test_ssh() {
    log "Testando conexão SSH para $TARGET_IP..."
    if sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "exit" &>/dev/null; then
        log "✅ Conexão SSH validada com o destino."
        return 0
    else
        log "❌ Falha na conexão SSH. Verifique IP e credenciais."
        return 1
    fi
}

# ==============================================================================
# Funções de Descoberta (Automação)
# ==============================================================================

get_source_vms() {
    log "Buscando VMs locais..."
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
    read -p "Digite os números das VMs a exportar (separados por espaço, ex: 1 3 4): " vm_selections
    
    SELECTED_VMS=()
    for sel in $vm_selections; do
        if [[ -n "${vm_map[$sel]}" ]]; then
            SELECTED_VMS+=("${vm_map[$sel]}")
        fi
    done

    if [ ${#SELECTED_VMS[@]} -eq 0 ]; then
        log "❌ Nenhuma VM válida selecionada."
        exit 1
    fi
    log "VMs na fila de exportação: ${SELECTED_VMS[*]}"
}

get_target_storages() {
    log "Consultando storages disponíveis no destino ($TARGET_IP)..."
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
    read -p "Selecione o ID do storage remoto para receber as VMs: " st_sel
    TARGET_STORAGE=${st_map[$st_sel]}

    if [[ -z "$TARGET_STORAGE" ]]; then
        log "❌ Storage remoto inválido."
        exit 1
    fi
    log "Storage remoto selecionado: $TARGET_STORAGE"
}

get_target_nextid() {
    # Coleta o próximo ID dinamicamente
    sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "pvesh get /cluster/nextid"
}

# ==============================================================================
# Núcleo: Exportação SSH Direto (Pipe)
# ==============================================================================
action_direct_pipe() {
    log "Iniciando processo: Exportação Direta via SSH (Pipe)"
    get_source_vms
    get_target_storages

    for SRC_VMID in "${SELECTED_VMS[@]}"; do
        TARGET_VMID=$(get_target_nextid)
        log "--------------------------------------------------------"
        log "Processando VM $SRC_VMID -> Destino ID $TARGET_VMID (Storage: $TARGET_STORAGE)"
        
        set +e
        vzdump $SRC_VMID --stdout --mode snapshot 2>>"$LOG_FILE" | pv -pteb | sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qmrestore - $TARGET_VMID --storage $TARGET_STORAGE"
        local STATUS=("${PIPESTATUS[@]}")
        set -e

        if [[ ${STATUS[0]} -eq 0 && ${STATUS[2]} -eq 0 ]]; then
            log "✅ VM $SRC_VMID exportada com sucesso como $TARGET_VMID."
        else
            log "❌ Erro na exportação da VM $SRC_VMID. Pipeline: vzdump(${STATUS[0]}), pv(${STATUS[1]}), ssh(${STATUS[2]})."
            log "Tentando rollback no destino para o ID $TARGET_VMID..."
            sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID --purge 1 >/dev/null 2>&1 || true; rm -f /var/lib/vz/dump/*${TARGET_VMID}* >/dev/null 2>&1 || true"
        fi
    done
}

# ==============================================================================
# Automação de Agendamento (Cron)
# ==============================================================================
setup_cron() {
    log "Iniciando wizard de agendamento (Cron)..."
    get_source_vms
    get_target_storages

    echo "Configuração de Frequência do Cron:"
    read -p "Minuto (0-59 ou *): " CRON_MIN
    read -p "Hora (0-23 ou *): " CRON_HR
    read -p "Dia do Mês (1-31 ou *): " CRON_DOM
    read -p "Mês (1-12 ou *): " CRON_MON
    read -p "Dia da Semana (0-7 ou *, 0=Dom): " CRON_DOW
    read -p "Destruir agendamento após a primeira execução? (s/n): " RUN_ONCE

    log "Preparando chaves SSH ED25519..."
    KEY_PATH="$HOME/.ssh/id_ed25519"
    if [[ ! -f "$KEY_PATH" ]]; then
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
    fi

    sshpass -p "$TARGET_PASS" ssh-copy-id -i "$KEY_PATH.pub" ${TARGET_USER}@${TARGET_IP} >/dev/null 2>&1
    log "Chave SSH autorizada no destino."

    JOB_NAME="export_pve_${TIMESTAMP}"
    JOB_SCRIPT="/usr/local/bin/${JOB_NAME}.sh"
    JOB_LOG="/var/log/${JOB_NAME}.log"

    # Geração do script autônomo
    cat << 'EOF' > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e -o pipefail
EOF

    # Injetando variáveis
    echo "TARGET_IP=\"$TARGET_IP\"" >> "$JOB_SCRIPT"
    echo "TARGET_USER=\"$TARGET_USER\"" >> "$JOB_SCRIPT"
    echo "TARGET_STORAGE=\"$TARGET_STORAGE\"" >> "$JOB_SCRIPT"
    echo "JOB_LOG=\"$JOB_LOG\"" >> "$JOB_SCRIPT"
    echo "VMS_ARRAY=(${SELECTED_VMS[@]})" >> "$JOB_SCRIPT"

    cat << 'EOF' >> "$JOB_SCRIPT"
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$JOB_LOG"; }
log "Iniciando cron job de exportação..."

for SRC_VMID in "${VMS_ARRAY[@]}"; do
    TARGET_VMID=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "pvesh get /cluster/nextid")
    log "Processando VM $SRC_VMID para novo ID $TARGET_VMID no destino..."
    
    set +e
    vzdump $SRC_VMID --stdout --mode snapshot 2>>"$JOB_LOG" | ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "qmrestore - $TARGET_VMID --storage $TARGET_STORAGE"
    STATUS=("${PIPESTATUS[@]}")
    set -e
    
    if [[ ${STATUS[0]} -eq 0 && ${STATUS[1]} -eq 0 ]]; then
        log "✅ VM $SRC_VMID finalizada."
    else
        log "❌ ERRO PIPELINE (vzdump=${STATUS[0]}, ssh=${STATUS[1]}). Executando rollback."
        ssh -o BatchMode=yes ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID --purge 1 || true"
    fi
done
EOF

    if [[ "$RUN_ONCE" == "s" || "$RUN_ONCE" == "S" ]]; then
        echo "rm -f /etc/cron.d/${JOB_NAME}" >> "$JOB_SCRIPT"
    fi

    chmod +x "$JOB_SCRIPT"
    echo "$CRON_MIN $CRON_HR $CRON_DOM $CRON_MON $CRON_DOW root $JOB_SCRIPT" > "/etc/cron.d/${JOB_NAME}"
    chmod 644 "/etc/cron.d/${JOB_NAME}"
    log "✅ Agendamento configurado: /etc/cron.d/${JOB_NAME}"
}

# ==============================================================================
# ZFS e Cluster (Stubs funcionais)
# ==============================================================================
action_zfs_repl() {
    log "Opção selecionada: Replicação ZFS"
    log "Verificando se o pacote pve-zsync está instalado..."
    if ! command -v "pve-zsync" &> /dev/null; then
        log "pve-zsync não encontrado. Instalando..."
        apt-get install pve-zsync -y -qq >/dev/null
    fi
    get_source_vms
    get_target_storages # Aqui idealmente listaria apenas datasets ZFS
    
    for SRC_VMID in "${SELECTED_VMS[@]}"; do
        TARGET_VMID=$(get_target_nextid)
        log "Executando ZFS Sync: VM $SRC_VMID -> Destino ID $TARGET_VMID..."
        # O pve-zsync lida nativamente com a transferência de datasets via SSH.
        # Exemplo de comando base: pve-zsync create -dest $TARGET_IP:$TARGET_STORAGE -source $SRC_VMID -name migracao_$SRC_VMID
        log "⚠️ Comando omitido: pve-zsync requer configuração prévia rigorosa de datasets. Valide a documentação oficial."
    done
}

action_cluster_mig() {
    log "Opção selecionada: Migração Nativa de Cluster"
    log "Validando estado do cluster local (pvecm status)..."
    if pvecm status >/dev/null 2>&1; then
        get_source_vms
        read -p "Digite o NOME do nó de destino (não o IP): " TARGET_NODE
        for SRC_VMID in "${SELECTED_VMS[@]}"; do
            log "Migrando VM $SRC_VMID para o nó $TARGET_NODE..."
            qm migrate $SRC_VMID $TARGET_NODE --online
        done
    else
        log "❌ Este servidor não faz parte de um cluster Proxmox."
    fi
}

# ==============================================================================
# Menu Principal
# ==============================================================================
main_menu() {
    clear
    echo "=========================================================="
    echo " PROXMOX MIGRATOR / EXPORTER"
    echo "=========================================================="
    echo "Log ativo em: $LOG_FILE"
    
    if [[ -z "$TARGET_IP" ]]; then
        read -p "IP do Servidor Destino: " TARGET_IP
        read -p "Usuário SSH (ex: root): " TARGET_USER
        read -s -p "Senha SSH: " TARGET_PASS
        echo ""
        test_ssh || exit 1
    fi

    while true; do
        echo "----------------------------------------------------------"
        echo "1) Exportação Direta via SSH (Pipe, sem disco extra)"
        echo "2) Agendar Exportação Direta (Cron + Automação Keys)"
        echo "3) Replicação ZFS (Requer pve-zsync / ZFS em ambos)"
        echo "4) Migração Nativa (Requer Cluster Proxmox)"
        echo "0) Sair"
        echo ""
        read -p "Escolha uma opção: " OPTION
        
        case $OPTION in
            1) action_direct_pipe ;;
            2) setup_cron ;;
            3) action_zfs_repl ;;
            4) action_cluster_mig ;;
            0) exit 0 ;;
            *) echo "Opção inválida." ;;
        esac
    done
}

main_menu