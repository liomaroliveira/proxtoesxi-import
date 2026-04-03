#!/usr/bin/env bash
# ==============================================================================
# Variáveis de Configuração
# ==============================================================================
LOG_FILE="/var/log/proxmox_migration_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/pve_migrate_$$"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

# Variáveis de Estado (para o rollback)
TARGET_IP=""
TARGET_USER=""
TARGET_PASS=""
TARGET_VMID=""
TEMP_BACKUP_FILE=""
ACTION_IN_PROGRESS=0

# ==============================================================================
# Funções de Base
# ==============================================================================

log() {
    local MSG="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$MSG" | tee -a "$LOG_FILE"
}

# Tratamento de interrupção (Ctrl+C ou Kill)
cleanup() {
    log "⚠️ INTERRUPÇÃO DETECTADA. Iniciando rollback..."
    if [[ $ACTION_IN_PROGRESS -eq 1 ]]; then
        if [[ -n "$TEMP_BACKUP_FILE" && -f "$TEMP_BACKUP_FILE" ]]; then
            log "Removendo backup local incompleto: $TEMP_BACKUP_FILE"
            rm -f "$TEMP_BACKUP_FILE"
        fi
        if [[ -n "$TARGET_IP" && -n "$TARGET_VMID" ]]; then
            log "Removendo resquícios da VM $TARGET_VMID no destino ($TARGET_IP)..."
            sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qm destroy $TARGET_VMID || true; rm -f /var/lib/vz/dump/*${TARGET_VMID}* || true"
        fi
    fi
    rm -rf "$TEMP_DIR"
    log "Rollback concluído. Saindo."
    exit 1
}

trap cleanup SIGINT SIGTERM

test_ssh() {
    log "Testando conexão SSH para $TARGET_IP..."
    if sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "exit"; then
        log "✅ Conexão SSH estabelecida com sucesso."
        return 0
    else
        log "❌ Falha na conexão SSH. Verifique credenciais."
        return 1
    fi
}

# ==============================================================================
# Funções de Operação Proxmox
# ==============================================================================

check_local_storage() {
    log "Analisando storages locais disponíveis..."
    echo -e "ID\tNOME\t\tTIPO\tLIVRE"
    
    # Extrai storages que suportam backup (vzdump)
    local storages=$(pvesm status -content backup | awk 'NR>1 {print $1, $2, $4}')
    local count=1
    
    declare -A st_map
    
    while read -r name type free_bytes; do
        # Converte bytes para GB
        local free_gb=$((free_bytes / 1024 / 1024 / 1024))
        echo -e "[$count]\t$name\t\t$type\t${free_gb}GB"
        st_map[$count]="$name|$free_gb"
        ((count++))
    done <<< "$storages"
    
    read -p "Selecione o storage de destino para o backup temporário: " st_sel
    local selected_data=${st_map[$st_sel]}
    
    if [[ -z "$selected_data" ]]; then
        log "❌ Seleção inválida."
        return 1
    fi
    
    STORAGE_NAME=$(echo "$selected_data" | cut -d'|' -f1)
    STORAGE_FREE=$(echo "$selected_data" | cut -d'|' -f2)
    
    log "Storage selecionado: $STORAGE_NAME (Livre: ${STORAGE_FREE}GB)"
    # Aqui entraria a lógica de validar tamanho da VM vs STORAGE_FREE
}

# ==============================================================================
# Ações do Menu
# ==============================================================================

action_backup_scp_restore() {
    log "Iniciando processo: Backup -> SCP -> Restore"
    read -p "ID da VM de Origem: " SRC_VMID
    read -p "Novo ID da VM no Destino: " TARGET_VMID
    read -p "Nome do Storage no Destino: " TARGET_STORAGE

    check_local_storage || return 1
    
    ACTION_IN_PROGRESS=1
    log "Iniciando vzdump da VM $SRC_VMID..."
    
    # Executa o dump e extrai o nome do arquivo resultante
    vzdump $SRC_VMID --storage $STORAGE_NAME --compress zstd --mode snapshot > "$TEMP_DIR/dump.log" 2>&1
    
    TEMP_BACKUP_FILE=$(grep "creating archive" "$TEMP_DIR/dump.log" | awk -F"'" '{print $2}')
    
    if [[ ! -f "$TEMP_BACKUP_FILE" ]]; then
        log "❌ Falha ao gerar backup. Log completo salvo em $LOG_FILE"
        cat "$TEMP_DIR/dump.log" >> "$LOG_FILE"
        ACTION_IN_PROGRESS=0
        return 1
    fi

    log "Backup gerado: $TEMP_BACKUP_FILE"
    log "Iniciando transferência via rede (SCP)..."
    
    # Transferência com rsync para mostrar progresso
    sshpass -p "$TARGET_PASS" rsync -a --info=progress2 "$TEMP_BACKUP_FILE" ${TARGET_USER}@${TARGET_IP}:/var/lib/vz/dump/ | while read line; do
        echo -ne "$line\r"
        # Grava apenas marcações de 10% no log texto para não encher de lixo
        if [[ "$line" =~ (10%|20%|30%|40%|50%|60%|70%|80%|90%|100%) ]]; then
            echo "[Transferência] $line" >> "$LOG_FILE"
        fi
    done
    echo "" # Quebra de linha final

    TARGET_FILE="/var/lib/vz/dump/$(basename "$TEMP_BACKUP_FILE")"
    
    log "Restaurando VM no destino..."
    sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qmrestore $TARGET_FILE $TARGET_VMID --storage $TARGET_STORAGE"
    
    log "Limpando arquivos temporários..."
    rm -f "$TEMP_BACKUP_FILE"
    sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "rm -f $TARGET_FILE"
    
    ACTION_IN_PROGRESS=0
    log "✅ Migração finalizada com sucesso."
}

action_direct_pipe() {
    log "Iniciando processo: SSH Import Direto (Pipe)"
    read -p "ID da VM de Origem: " SRC_VMID
    read -p "Novo ID da VM no Destino: " TARGET_VMID
    read -p "Nome do Storage no Destino: " TARGET_STORAGE

    ACTION_IN_PROGRESS=1
    log "Gerando stream do disco da VM $SRC_VMID diretamente para $TARGET_IP..."
    
    # Utiliza o pv para monitorar o trafego do pipe
    vzdump $SRC_VMID --stdout --mode snapshot 2>>"$LOG_FILE" | pv -pteb | sshpass -p "$TARGET_PASS" ssh $SSH_OPTS ${TARGET_USER}@${TARGET_IP} "qmrestore - $TARGET_VMID --storage $TARGET_STORAGE"
    
    if [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[2]} -eq 0 ]]; then
        log "✅ Migração (Direct Pipe) finalizada com sucesso."
    else
        log "❌ Erro na transferência. Desfazendo no destino..."
        cleanup
    fi
    ACTION_IN_PROGRESS=0
}

# ==============================================================================
# Menu Principal
# ==============================================================================

main_menu() {
    mkdir -p "$TEMP_DIR"
    clear
    echo "=========================================================="
    echo " ⚙️  MIGRATOR PROXMOX SCRIPT"
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
        echo "1) SSH Backup & Restore (Seguro, requer disco livre na origem)"
        echo "2) SSH Import Direto (Pipe, sem uso de disco extra)"
        echo "3) Replicação ZFS (Requer ZFS em ambos os nós)"
        echo "4) Import Cluster Proxmox (Live Migration)"
        echo "5) Gerar rotina de Crontab (Agendamento)"
        echo "0) Sair"
        echo ""
        read -p "Escolha uma opção: " OPTION
        
        case $OPTION in
            1) action_backup_scp_restore ;;
            2) action_direct_pipe ;;
            3) log "ZFS SEND/RECV: Lógica a implementar. Requer parse de 'zfs list'. Comando base: zfs send pool/disk@snap | ssh ip zfs recv pool/disk" ;;
            4) log "CLUSTER: Lógica a implementar. Requer validação 'pvecm status'. Comando base: qm migrate <vmid> <target_node>" ;;
            5) log "CRON: Cria script estático com 'sshpass ... rsync' e insere no /etc/crontab. Usa 'crontab -r' no próprio gerado se for run-once." ;;
            0) exit 0 ;;
            *) echo "Opção inválida." ;;
        esac
    done
}

main_menu