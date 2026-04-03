#!/usr/bin/env bash
# ==============================================================================
# Migrator Proxmox - V2
# ==============================================================================

# Validação estrita de erros no bash
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
TARGET_VMID=""
TEMP_BACKUP_FILE=""
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

# Captura erros não tratados
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
        log "⚠️ SINAL DE INTERRUPÇÃO OU ERRO DETECTADO. Iniciando rollback..."
    fi
    
    if [[ $ACTION_IN_PROGRESS -eq 1 ]]; then
        if [[ -n "$TEMP_BACKUP_FILE" && -f "$TEMP_BACKUP_FILE" ]]; then
            log "Removendo backup local incompleto: $TEMP_BACKUP_FILE"
            rm -f "$TEMP_BACKUP_FILE"
        fi
        
        if [[ -n "$TARGET_IP" && -n "$TARGET_VMID" ]]; then
            log "Testando conectividade para rollback remoto..."
            if ping -c 1 -W 2 "$TARGET_IP" &> /dev/null; then
                log "Conexão ativa. Removendo resquícios da VM $TARGET_VMID no destino ($TARGET_IP)..."
                # Executa limpeza ignorando erros (|| true) se a VM não existir ainda
                if [[ -n "$TARGET_PASS" ]]; then
                    sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID --purge 1 >/dev/null 2>&1 || true; rm -f /var/lib/vz/dump/*${TARGET_VMID}* >/dev/null 2>&1 || true"
                else
                    ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID --purge 1 >/dev/null 2>&1 || true; rm -f /var/lib/vz/dump/*${TARGET_VMID}* >/dev/null 2>&1 || true"
                fi
                log "Rollback remoto concluído."
            else
                log "❌ FALHA: Sem comunicação com o destino ($TARGET_IP). Rollback remoto abortado. Podem existir artefatos órfãos da VM $TARGET_VMID no destino."
            fi
        fi
    fi
    rm -rf "$TEMP_DIR"
    exit 1
}
trap cleanup SIGINT SIGTERM

test_ssh() {
    log "Testando conexão SSH para $TARGET_IP..."
    if sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "exit" &>/dev/null; then
        log "✅ Conexão SSH validada."
        return 0
    else
        log "❌ Falha na conexão SSH. Motivo: Credenciais inválidas ou host inacessível."
        return 1
    fi
}

check_local_storage() {
    log "Analisando storages locais..."
    echo -e "ID\tNOME\t\tTIPO\tLIVRE"
    
    local storages=$(pvesm status -content backup | awk 'NR>1 {print $1, $2, $4}')
    local count=1
    declare -A st_map
    
    while read -r name type free_bytes; do
        local free_gb=$((free_bytes / 1024 / 1024 / 1024))
        echo -e "[$count]\t$name\t\t$type\t${free_gb}GB"
        st_map[$count]="$name|$free_gb"
        ((count++))
    done <<< "$storages"
    
    read -p "Selecione o ID do storage para o backup temporário: " st_sel
    local selected_data=${st_map[$st_sel]}
    
    if [[ -z "$selected_data" ]]; then
        log "❌ Seleção inválida."
        exit 1
    fi
    
    STORAGE_NAME=$(echo "$selected_data" | cut -d'|' -f1)
    STORAGE_FREE=$(echo "$selected_data" | cut -d'|' -f2)
    log "Storage selecionado: $STORAGE_NAME (Livre: ${STORAGE_FREE}GB)"
}

# ==============================================================================
# Núcleo: Importação SSH Direto (Pipe)
# ==============================================================================
action_direct_pipe() {
    log "Iniciando processo: SSH Import Direto (Pipe)"
    read -p "ID da VM de Origem: " SRC_VMID
    read -p "Novo ID da VM no Destino: " TARGET_VMID
    read -p "Nome do Storage no Destino (ex: local-lvm): " TARGET_STORAGE

    ACTION_IN_PROGRESS=1
    log "Gerando stream do disco da VM $SRC_VMID diretamente para $TARGET_IP..."
    
    # Desativa errexit momentaneamente para gerenciar o array PIPESTATUS manualmente
    set +e
    vzdump $SRC_VMID --stdout --mode snapshot 2>>"$LOG_FILE" | pv -pteb | sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qmrestore - $TARGET_VMID --storage $TARGET_STORAGE"
    
    local STATUS=("${PIPESTATUS[@]}")
    set -e

    if [[ ${STATUS[0]} -eq 0 && ${STATUS[2]} -eq 0 ]]; then
        log "✅ Migração (Direct Pipe) finalizada com sucesso."
    else
        log "❌ Erro na transferência de dados. Status Pipeline: vzdump(${STATUS[0]}), pv(${STATUS[1]}), ssh(${STATUS[2]})."
        cleanup
    fi
    ACTION_IN_PROGRESS=0
}

# ==============================================================================
# Automação de Agendamento (Wizard & Chaves SSH)
# ==============================================================================
setup_cron() {
    log "Iniciando wizard de agendamento (Cron)..."
    read -p "ID da VM de Origem: " SRC_VMID
    read -p "Novo ID da VM no Destino: " TARGET_VMID
    read -p "Nome do Storage no Destino: " TARGET_STORAGE

    echo "Configuração de Frequência do Cron:"
    read -p "Minuto (0-59 ou *): " CRON_MIN
    read -p "Hora (0-23 ou *): " CRON_HR
    read -p "Dia do Mês (1-31 ou *): " CRON_DOM
    read -p "Mês (1-12 ou *): " CRON_MON
    read -p "Dia da Semana (0-7 ou *, onde 0 e 7 = Domingo): " CRON_DOW
    
    read -p "Este agendamento deve rodar apenas uma vez e se autodestruir? (s/n): " RUN_ONCE

    log "Preparando chaves SSH para execução autônoma sem senha..."
    KEY_PATH="$HOME/.ssh/id_ed25519"
    if [[ ! -f "$KEY_PATH" ]]; then
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
        log "Nova chave ED25519 gerada."
    fi

    log "Exportando chave para o destino. A senha será solicitada pelo sistema:"
    sshpass -p "$TARGET_PASS" ssh-copy-id -i "$KEY_PATH.pub" ${TARGET_USER}@${TARGET_IP} >/dev/null 2>&1
    log "Chave SSH autorizada no destino."

    # Gerar script autônomo
    JOB_NAME="migrate_vmid_${SRC_VMID}_to_${TARGET_IP}"
    JOB_SCRIPT="/usr/local/bin/${JOB_NAME}.sh"
    JOB_LOG="/var/log/${JOB_NAME}.log"

    cat << 'EOF' > "$JOB_SCRIPT"
#!/usr/bin/env bash
# Script gerado automaticamente
set -e -o pipefail
EOF

    # Injetar variáveis fixas no script gerado
    echo "SRC_VMID=\"$SRC_VMID\"" >> "$JOB_SCRIPT"
    echo "TARGET_VMID=\"$TARGET_VMID\"" >> "$JOB_SCRIPT"
    echo "TARGET_STORAGE=\"$TARGET_STORAGE\"" >> "$JOB_SCRIPT"
    echo "TARGET_IP=\"$TARGET_IP\"" >> "$JOB_SCRIPT"
    echo "TARGET_USER=\"$TARGET_USER\"" >> "$JOB_SCRIPT"
    echo "JOB_LOG=\"$JOB_LOG\"" >> "$JOB_SCRIPT"
    
    cat << 'EOF' >> "$JOB_SCRIPT"
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$JOB_LOG"; }
log "Iniciando cron job de migração direta..."
set +e
vzdump $SRC_VMID --stdout --mode snapshot 2>>"$JOB_LOG" | ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${TARGET_USER}@${TARGET_IP} "qmrestore - $TARGET_VMID --storage $TARGET_STORAGE"
STATUS=("${PIPESTATUS[@]}")
set -e
if [[ ${STATUS[0]} -eq 0 && ${STATUS[1]} -eq 0 ]]; then
    log "Sucesso."
else
    log "ERRO PIPELINE: vzdump=${STATUS[0]}, ssh=${STATUS[1]}"
    ssh -o BatchMode=yes ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID --purge 1 || true"
fi
EOF

    if [[ "$RUN_ONCE" == "s" || "$RUN_ONCE" == "S" ]]; then
        echo "rm -f /etc/cron.d/${JOB_NAME}" >> "$JOB_SCRIPT"
        log "Configurado para autodestruição após a primeira execução."
    fi

    chmod +x "$JOB_SCRIPT"

    # Injetar no Cron
    echo "$CRON_MIN $CRON_HR $CRON_DOM $CRON_MON $CRON_DOW root $JOB_SCRIPT" > "/etc/cron.d/${JOB_NAME}"
    chmod 644 "/etc/cron.d/${JOB_NAME}"
    
    log "✅ Agendamento configurado no arquivo: /etc/cron.d/${JOB_NAME}"
}

# ==============================================================================
# Menu Principal
# ==============================================================================
main_menu() {
    clear
    echo "=========================================================="
    echo " MIGRATOR PROXMOX"
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
        echo ""
        echo "1) SSH Import Direto (Pipe, sem uso de disco extra)"
        echo "2) Agendar Migração Direta (Cron + SSH Keys)"
        echo "0) Sair"
        echo ""
        read -p "Escolha uma opção: " OPTION
        
        case $OPTION in
            1) action_direct_pipe ;;
            2) setup_cron ;;
            0) exit 0 ;;
            *) echo "Opção inválida." ;;
        esac
    done
}

main_menu