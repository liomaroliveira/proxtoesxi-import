#!/bin/bash

# ==========================================
# WIZARD GERADOR DE MIGRAÇÃO AUTÔNOMA (V22)
# ==========================================

LOG_FILE="/var/log/migracao_esxi_proxmox.log"
log_w() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [WIZARD] $1" | tee -a "$LOG_FILE"; }

clear
echo "======================================================"
echo "WIZARD DE AGENDAMENTO DE MIGRAÇÃO ESXi -> PROXMOX"
echo "======================================================"

# --- 0. GESTOR DE CRONTAB EXISTENTE ---
mapfile -t EXISTING_JOBS < <(crontab -l 2>/dev/null | grep "executa_migracao_")
if [ ${#EXISTING_JOBS[@]} -gt 0 ]; then
    echo -e "\n=== AGENDAMENTOS EXISTENTES NA FILA ==="
    idx=1
    for job in "${EXISTING_JOBS[@]}"; do
        echo "[$idx] $job"
        ((idx++))
    done
    echo "======================================================"
    read -p "Deseja remover algum? (Digite o NÚMERO, 'TODOS' ou Enter para ignorar): " REMOVE_OPT
    if [ -n "$REMOVE_OPT" ]; then
        if [[ "${REMOVE_OPT^^}" == "TODOS" ]]; then
            crontab -l | grep -v "executa_migracao_" | crontab -
            echo "[v] Todos os agendamentos foram removidos do Crontab."
            log_w "Todos os agendamentos previos foram apagados pelo usuario."
        elif [[ "$REMOVE_OPT" =~ ^[0-9]+$ ]] && [ "$REMOVE_OPT" -le "${#EXISTING_JOBS[@]}" ]; then
            JOB_TO_REMOVE="${EXISTING_JOBS[$((REMOVE_OPT-1))]}"
            ESCAPED_JOB=$(echo "$JOB_TO_REMOVE" | sed 's/[][\.^$*]/\\&/g')
            crontab -l | grep -v "$ESCAPED_JOB" | crontab -
            echo "[v] Agendamento $REMOVE_OPT removido."
            log_w "Agendamento removido: $JOB_TO_REMOVE"
        fi
    fi
fi

log_w "Iniciando criacao de nova fila V22..."

# --- 1. CONFIGURAÇÕES GLOBAIS ---
echo -e "\n=== MODO DE IMPORTAÇÃO ==="
echo "[1] Via Storage Plugin Proxmox (Padrão)"
echo "[2] Via SSHFS (Monta o ESXi remoto)"
echo "[3] Via USB/Armazenamento Local (Para backups offline)"
read -p "Escolha [1-3]: " MODO_IMPORT
log_w "Modo de Importacao: $MODO_IMPORT"

echo -e "\n=== DESTINO ==="
mapfile -t DEST_STORAGES < <(pvesm status | awk 'NR>1 && $4>0 {print $1}')
for i in "${!DEST_STORAGES[@]}"; do echo "[$((i+1))] ${DEST_STORAGES[$i]}"; done
read -p "Número do storage de Destino: " n_dest
STORAGE_DESTINO="${DEST_STORAGES[$((n_dest-1))]}"

echo -e "\n=== OPÇÕES DE AUTOMAÇÃO ==="
read -p "Injetar ISO pós-instalação (Rede/Agent)? [1] Sim / [0] Não: " OPT_INJECT
read -p "Ligar VMs no Proxmox no final? [1] Sim / [0] Não: " OPT_START
read -p "Pre-Flight (Desligar + Consolidar na origem)? [1] Sim / [0] Não: " OPT_PREFLIGHT
read -p "Religar VMs na origem no final? [1] Sim / [0] Não: " OPT_RELIGAR

# --- 2. CREDENCIAIS E ORIGEM ---
ESXI_HOST=""
ESXI_USER="root"
STORAGE_ORIGEM=""
DS_NOME=""
USB_PATH=""

if [ "$MODO_IMPORT" == "1" ] || [ "$MODO_IMPORT" == "2" ] || [ "$OPT_PREFLIGHT" == "1" ] || [ "$OPT_RELIGAR" == "1" ]; then
    read -p "IP do host ESXi de origem: " ESXI_HOST
    echo "[*] Testando conexão SSH sem senha com $ESXI_HOST..."
    log_w "Testando conexao SSH sem senha com $ESXI_HOST..."
    
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ESXI_USER@$ESXI_HOST" "echo OK" &>/dev/null; then
        echo "[!] ERRO: Conexão SSH sem senha falhou. Configure as chaves RSA."
        log_w "ERRO: Conexao SSH falhou."
        exit 1
    fi
    echo "[v] Conexão SSH validada com sucesso."
    log_w "Conexao SSH validada com sucesso."
fi

declare -A MAPA_VMS
if [ "$MODO_IMPORT" == "1" ]; then
    mapfile -t ESXI_STORAGES < <(pvesm status | awk 'NR>1 && $2=="esxi" {print $1}')
    for i in "${!ESXI_STORAGES[@]}"; do echo "[$((i+1))] ${ESXI_STORAGES[$i]}"; done
    read -p "Número do storage Origem ESXi: " n_origem
    STORAGE_ORIGEM="${ESXI_STORAGES[$((n_origem-1))]}"
    mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")

elif [ "$MODO_IMPORT" == "2" ]; then
    echo -e "\n[*] Buscando Datastores disponíveis no ESXi via SSH..."
    # Lista datastores ignorando UUIDs puros (começam com 8 caracteres hexadecimais)
    mapfile -t ESXI_DATASTORES < <(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "ls -1 /vmfs/volumes | grep -vE '^[0-9a-fA-F]{8}-'")
    
    if [ ${#ESXI_DATASTORES[@]} -eq 0 ]; then
        echo "[x] Nenhum Datastore encontrado no host remoto. Abortando."
        exit 1
    fi
    
    for i in "${!ESXI_DATASTORES[@]}"; do echo "[$((i+1))] ${ESXI_DATASTORES[$i]}"; done
    read -p "Número do Datastore Origem ESXi: " n_ds_origem
    DS_NOME="${ESXI_DATASTORES[$((n_ds_origem-1))]}"
    
    echo "[*] Mapeando VMs no datastore $DS_NOME..."
    mkdir -p /mnt/esxi_sshfs
    if ! command -v sshfs &> /dev/null; then apt-get update >/dev/null && apt-get install sshfs -y >/dev/null; fi
    
    # Resolve o symlink remoto antes de montar para evitar erro local de diretório não encontrado
    REAL_PATH=$(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "readlink -f /vmfs/volumes/$DS_NOME")
    sshfs "$ESXI_USER@$ESXI_HOST:$REAL_PATH" /mnt/esxi_sshfs -o StrictHostKeyChecking=no,allow_other,IdentityFile=~/.ssh/id_rsa
    
    mapfile -t VMS_BRUTAS < <(find /mnt/esxi_sshfs -maxdepth 2 -name "*.vmx")
    umount -f /mnt/esxi_sshfs &>/dev/null

elif [ "$MODO_IMPORT" == "3" ]; then
    read -p "Caminho ABSOLUTO do diretório USB: " USB_PATH
    mapfile -t VMS_BRUTAS < <(find "$USB_PATH" -maxdepth 2 -name "*.vmx")
fi

for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done
if [ ${#MAPA_VMS[@]} -eq 0 ]; then
    echo "[x] Nenhuma VM encontrada no armazenamento selecionado. Abortando."
    exit 1
fi

# --- 3. SELEÇÃO E VLANs ---
echo -e "\n=== VMS ENCONTRADAS ==="
for i in $(seq 1 ${#VMS_BRUTAS[@]}); do echo "[$i] $(basename "${MAPA_VMS[$i]}")"; done
echo "======================================================"
read -p "Quais VMs deseja agendar? (ex: 1 3 ou TODAS): " ESCOLHA_USER

ARRAY_VMS_CODE=""
if [[ "${ESCOLHA_USER^^}" == "TODAS" ]]; then
    ARRAY_VMS_CODE="    \"TODAS\""
else
    for num in $ESCOLHA_USER; do
        ARQ_VMX=$(basename "${MAPA_VMS[$num]}")
        read -p "VLANs para $ARQ_VMX (separadas por espaço, Enter p/ vazia): " vlan_input
        ARRAY_VMS_CODE="${ARRAY_VMS_CODE}
    \"${ARQ_VMX}|${vlan_input}\""
    done
fi

# --- 4. CONFIGURAÇÃO DE TEMPO (CRONOLOGIA) ---
echo -e "\n=== AGENDAMENTO CRON AVANÇADO ==="
read -p "Deseja agendar a execução agora? [1] Sim / [0] Não: " OPT_CRON

IS_RECURRING="0"
if [ "$OPT_CRON" == "1" ]; then
    read -p "Hora de execução (0-23): " CRON_H
    read -p "Minuto de execução (0-59): " CRON_M
    echo -e "\nData da execução:"
    echo "[1] Hoje"
    echo "[2] Amanhã"
    echo "[3] Data Específica (Dia e Mês)"
    echo "[4] Recorrente (Todos os dias)"
    read -p "Escolha [1-4]: " TIPO_DATA

    if [ "$TIPO_DATA" == "1" ]; then
        CRON_D=$(date +'%d')
        CRON_MON=$(date +'%m')
    elif [ "$TIPO_DATA" == "2" ]; then
        CRON_D=$(date -d "tomorrow" +'%d')
        CRON_MON=$(date -d "tomorrow" +'%m')
    elif [ "$TIPO_DATA" == "3" ]; then
        read -p "Dia (1-31): " CRON_D
        read -p "Mês (1-12): " CRON_MON
    elif [ "$TIPO_DATA" == "4" ]; then
        CRON_D="*"
        CRON_MON="*"
        IS_RECURRING="1"
    fi
fi

# --- 5. GERAÇÃO DO SCRIPT AUTÔNOMO (INCREMENTAL) ---
UNIQUE_ID=$(date +'%Y%m%d_%H%M%S')
SCRIPT_DESTINO="/root/executa_migracao_${UNIQUE_ID}.sh"
echo -e "\n[*] Gerando o script autônomo incremental em $SCRIPT_DESTINO..."

cat << EOF > "$SCRIPT_DESTINO"
#!/bin/bash
# ==========================================
# SCRIPT GERADO AUTOMATICAMENTE PELO WIZARD V22
# ==========================================
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

MY_SCRIPT_PATH="$SCRIPT_DESTINO"
IS_RECURRING="$IS_RECURRING"

MODO_IMPORT="$MODO_IMPORT"
STORAGE_DESTINO="$STORAGE_DESTINO"
OPT_INJECT="$OPT_INJECT"
OPT_START="$OPT_START"
OPT_PREFLIGHT="$OPT_PREFLIGHT"
OPT_RELIGAR="$OPT_RELIGAR"
ESXI_HOST="$ESXI_HOST"
ESXI_USER="$ESXI_USER"
STORAGE_ORIGEM="$STORAGE_ORIGEM"
DS_NOME="$DS_NOME"
USB_PATH="$USB_PATH"

VMS_TARGET=( $ARRAY_VMS_CODE
)

EOF

cat << 'EOF' >> "$SCRIPT_DESTINO"
# ================= INÍCIO DO MOTOR =================
LOG_FILE="/var/log/migracao_esxi_proxmox.log"
CURRENT_VMID=""
IMPORT_PID=""
ISO_SCRIPT_PATH="/var/lib/vz/template/iso/pos_install_esxi.iso"

log_msg() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log_msg "======================================================"
log_msg "INICIANDO FILA DE MIGRAÇÃO: $MY_SCRIPT_PATH"
log_msg "======================================================"

cleanup() {
    log_msg "\n[!] AVISO: INTERRUPÇÃO DETECTADA!"
    if [ -n "$IMPORT_PID" ]; then kill -9 $IMPORT_PID 2>/dev/null; fi
    if [ -n "$CURRENT_VMID" ]; then qm destroy $CURRENT_VMID --purge 1 >> "$LOG_FILE" 2>&1; fi
    umount -f /mnt/esxi_sshfs &>/dev/null
    exit 1
}
trap cleanup SIGINT SIGTERM

processar_saida() {
    local prev_was_trans=0; local last_trans=""
    while IFS= read -r line; do
        if [[ "$line" == transferred* ]]; then
            echo -en "\r[$(date +'%H:%M:%S')] $line\033[K"
            last_trans="$line"; prev_was_trans=1
        else
            if [[ $prev_was_trans -eq 1 ]]; then echo ""; echo "[$(date +'%H:%M:%S')] $last_trans" >> "$LOG_FILE"; prev_was_trans=0; fi
            log_msg "$line"
        fi
    done
    if [[ $prev_was_trans -eq 1 ]]; then echo ""; log_msg "$last_trans"; fi
}

if [ "$OPT_INJECT" == "1" ]; then
    for pkg in genisoimage; do
        if ! command -v $pkg &> /dev/null; then apt-get update >/dev/null && apt-get install $pkg -y >/dev/null; fi
    done
    TMP_DIR=$(mktemp -d)
    cat << 'INNER_EOF' > "$TMP_DIR/pos_import_esxi.sh"
#!/bin/bash
LOG="/root/migracao_completa.log"
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }
log "=== Iniciando validacao de rede ==="
mapfile -t NEW_IFS < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|altname')
mapfile -t OLD_IFS < <(awk '/^iface/ && $2 != "lo" {print $2}' /etc/network/interfaces | sort -u)
if [ ${#NEW_IFS[@]} -eq 0 ]; then log "ERRO: Interfaces nao detectadas."; exit 1; fi
ALTERADO=0
for i in "${!OLD_IFS[@]}"; do
    if [ -n "${NEW_IFS[$i]}" ] && [ "${OLD_IFS[$i]}" != "${NEW_IFS[$i]}" ]; then
        sed -i "s/\b${OLD_IFS[$i]}\b/${NEW_IFS[$i]}/g" /etc/network/interfaces
        ALTERADO=1
    fi
done
if [ $ALTERADO -eq 1 ]; then systemctl restart networking; sleep 5; fi
if ping -c 3 google.com &> /dev/null; then
    apt-get update -y && apt-get install qemu-guest-agent -y && systemctl enable --now qemu-guest-agent && apt-get purge open-vm-tools -y && apt-get autoremove -y
    log "SUCESSO: Agent instalado."
fi
INNER_EOF
    chmod +x "$TMP_DIR/pos_import_esxi.sh"
    genisoimage -quiet -J -R -V "POS_INSTALL" -o "$ISO_SCRIPT_PATH" "$TMP_DIR"
    rm -rf "$TMP_DIR"
fi

declare -A MAPA_VMS
if [ "$MODO_IMPORT" == "1" ]; then
    mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")
elif [ "$MODO_IMPORT" == "2" ]; then
    if ! command -v sshfs &> /dev/null; then apt-get update >/dev/null && apt-get install sshfs -y >/dev/null; fi
    mkdir -p /mnt/esxi_sshfs
    REAL_PATH=$(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "readlink -f /vmfs/volumes/$DS_NOME")
    sshfs "$ESXI_USER@$ESXI_HOST:$REAL_PATH" /mnt/esxi_sshfs -o StrictHostKeyChecking=no,allow_other,IdentityFile=~/.ssh/id_rsa
    mapfile -t VMS_BRUTAS < <(find /mnt/esxi_sshfs -maxdepth 2 -name "*.vmx")
elif [ "$MODO_IMPORT" == "3" ]; then
    mapfile -t VMS_BRUTAS < <(find "$USB_PATH" -maxdepth 2 -name "*.vmx")
fi

for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done

for target in "${VMS_TARGET[@]}"; do
    if [ "$target" == "TODAS" ]; then
        for i in "${!MAPA_VMS[@]}"; do
            ARQ_VMX=$(basename "${MAPA_VMS[$i]}")
            TARGETS_FINAL+=("$i|$ARQ_VMX|")
        done
        break
    else
        nome_alvo=$(echo "$target" | cut -d'|' -f1)
        vlans_alvo=$(echo "$target" | cut -d'|' -f2)
        for i in "${!MAPA_VMS[@]}"; do
            if [ "$(basename "${MAPA_VMS[$i]}")" == "$nome_alvo" ]; then
                TARGETS_FINAL+=("$i|$nome_alvo|$vlans_alvo")
            fi
        done
    fi
done

for info in "${TARGETS_FINAL[@]}"; do
    num_vm=$(echo "$info" | cut -d'|' -f1)
    ARQ_VMX=$(echo "$info" | cut -d'|' -f2)
    VLANS_REQ=$(echo "$info" | cut -d'|' -f3)
    caminho_vm="${MAPA_VMS[$num_vm]}"
    CURRENT_VMID=$(pvesh get /cluster/nextid)
    NOME_LIMPO=$(grep -i '^displayName' "$caminho_vm" 2>/dev/null | cut -d'"' -f2 | tr -d '\r')
    [ -z "$NOME_LIMPO" ] && NOME_LIMPO="$ARQ_VMX"

    log_msg "------------------------------------------------------"
    log_msg "Processando: $NOME_LIMPO -> ID Proxmox $CURRENT_VMID"

    if [ "$OPT_PREFLIGHT" == "1" ] && [[ "$MODO_IMPORT" == "1" || "$MODO_IMPORT" == "2" ]]; then
        ESXI_VMID=$(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/getallvms" | grep "$ARQ_VMX" | awk '{print $1}' | head -n 1)
        if [ -n "$ESXI_VMID" ]; then
            if ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.getstate $ESXI_VMID" | grep -qi 'Powered on'; then
                ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.off $ESXI_VMID" > /dev/null
                sleep 5
            fi
            
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/snapshot.create $ESXI_VMID 'Migracao-Proxmox' 'Forced-Consolidation' 0 0" > /dev/null
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/snapshot.removeall $ESXI_VMID" > /dev/null
            
            while true; do
                TASKS=$(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/get.tasklist $ESXI_VMID" | grep -o "haTask-[a-zA-Z0-9.-]*")
                IS_RUNNING=0
                for t in $TASKS; do
                    STATUS=$(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vimsvc/task_info $t" 2>/dev/null | grep -iE 'state =' | awk -F'"' '{print $2}')
                    if [ "$STATUS" == "running" ]; then IS_RUNNING=1; break; fi
                done
                if [ "$IS_RUNNING" == "0" ]; then break; fi
                sleep 5
            done
        fi
    fi

    if [ "$MODO_IMPORT" == "1" ]; then
        qm import $CURRENT_VMID "$caminho_vm" --storage "$STORAGE_DESTINO" > >(processar_saida) 2>&1 &
        wait $!
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 0 ]; then
            OLD_CORES=$(qm config $CURRENT_VMID | awk '/^cores:/ {print $2}'); [ -z "$OLD_CORES" ] && OLD_CORES=1
            OLD_SOCKETS=$(qm config $CURRENT_VMID | awk '/^sockets:/ {print $2}'); [ -z "$OLD_SOCKETS" ] && OLD_SOCKETS=1
            qm set $CURRENT_VMID --sockets 1 --cores $((OLD_CORES * OLD_SOCKETS)) --cpu host --vga virtio --scsihw virtio-scsi-single --agent 1 --onboot 1
            DISCO_BOOT=$(qm config $CURRENT_VMID | grep -E '^(scsi|ide|sata|virtio)[0-9]+:' | grep -v 'cdrom' | head -n 1 | awk -F: '{print $1}')
            [ -n "$DISCO_BOOT" ] && qm set $CURRENT_VMID --boot "order=$DISCO_BOOT"

            mapfile -t PLACAS_REDE < <(qm config $CURRENT_VMID | grep -E '^net[0-9]+:' | awk -F: '{print $1}')
            IFS=' ' read -r -a VLAN_ARRAY <<< "$VLANS_REQ"
            for idx in "${!PLACAS_REDE[@]}"; do
                placa="${PLACAS_REDE[$idx]}"
                OLD_NET=$(qm config $CURRENT_VMID | grep "^${placa}:" | sed "s/^${placa}: //")
                MAC=$(echo "$OLD_NET" | grep -o -i -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
                NET_CONFIG="virtio=${MAC:-},bridge=vmbr0"
                [ -n "${VLAN_ARRAY[$idx]}" ] && NET_CONFIG="$NET_CONFIG,tag=${VLAN_ARRAY[$idx]}"
                qm set $CURRENT_VMID --$placa "$NET_CONFIG"
            done
        fi
    else
        MEM=$(grep -iE '^memSize' "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
        CORES=$(grep -iE '^numvcpus' "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
        qm create $CURRENT_VMID --name "$NOME_LIMPO" --memory "${MEM:-2048}" --sockets 1 --cores "${CORES:-1}" --cpu host --scsihw virtio-scsi-single --vga virtio --agent 1 --onboot 1
        
        EXIT_CODE=0
        while read -r line; do
            dev=$(echo "$line" | cut -d'.' -f1)
            bus=$(echo "$dev" | cut -d':' -f1)
            vmdk_name=$(echo "$line" | cut -d'"' -f2 | tr -d '\r')
            vmdk_path="$(dirname "$caminho_vm")/$vmdk_name"
            
            qm importdisk $CURRENT_VMID "$vmdk_path" "$STORAGE_DESTINO" --format raw > /tmp/imp_${CURRENT_VMID}.log 2>&1
            VOL=$(grep -o "$STORAGE_DESTINO:vm-$CURRENT_VMID-disk-[0-9]*" /tmp/imp_${CURRENT_VMID}.log | head -n 1)
            if [ -n "$VOL" ]; then
                qm set $CURRENT_VMID --$bus "$VOL"
                [ "$bus" == "scsi0" ] && qm set $CURRENT_VMID --boot "order=$bus"
            else
                EXIT_CODE=1
            fi
        done < <(grep -i '\.fileName' "$caminho_vm" | grep -i '\.vmdk' | tr -d '\r')

        IFS=' ' read -r -a VLAN_ARRAY <<< "$VLANS_REQ"
        net_idx=0
        while read -r eth_line; do
            eth_prefix=$(echo "$eth_line" | awk -F'.' '{print $1}')
            mac=$(grep -i "^${eth_prefix}.generatedAddress" "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
            [ -z "$mac" ] && mac=$(grep -i "^${eth_prefix}.address " "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
            NET_CONFIG="virtio,bridge=vmbr0"
            [ -n "$mac" ] && NET_CONFIG="virtio=${mac},bridge=vmbr0"
            [ -n "${VLAN_ARRAY[$net_idx]}" ] && NET_CONFIG="$NET_CONFIG,tag=${VLAN_ARRAY[$net_idx]}"
            qm set $CURRENT_VMID --net${net_idx} "$NET_CONFIG"
            ((net_idx++))
        done < <(grep -iE '^ethernet[0-9]+\.present.*=.*"TRUE"' "$caminho_vm" | tr -d '\r')
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        if [ "$OPT_INJECT" == "1" ]; then
            for drive in $(qm config $CURRENT_VMID | grep 'media=cdrom' | awk -F: '{print $1}'); do qm set $CURRENT_VMID --delete "$drive"; done
            qm set $CURRENT_VMID --ide2 local:iso/pos_install_esxi.iso,media=cdrom
        fi
        if [ "$OPT_RELIGAR" == "1" ]; then ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.on $ESXI_VMID" > /dev/null; fi
        if [ "$OPT_START" == "1" ]; then qm start $CURRENT_VMID; fi
        log_msg "[v] VM $NOME_LIMPO concluída!"
    else
        log_msg "[x] ERRO na VM $NOME_LIMPO."
    fi
    sleep 2
done

if [ "$MODO_IMPORT" == "2" ]; then umount -f /mnt/esxi_sshfs &>/dev/null; fi

# --- ROTINA DE AUTODESTRUIÇÃO ---
if [ "$IS_RECURRING" == "0" ]; then
    log_msg "Lote finalizado. Removendo este agendamento unico do Crontab..."
    crontab -l 2>/dev/null | grep -v "$MY_SCRIPT_PATH" | crontab -
else
    log_msg "Lote finalizado. Agendamento mantido (Recorrente)."
fi
EOF

chmod +x "$SCRIPT_DESTINO"
echo "[v] Script gerado em $SCRIPT_DESTINO"

# --- 6. AGENDAMENTO NO CRONTAB ---
if [ "$OPT_CRON" == "1" ]; then
    crontab -l 2>/dev/null | grep -v "$SCRIPT_DESTINO" > /tmp/crontmp
    echo "$CRON_M $CRON_H $CRON_D $CRON_MON * $SCRIPT_DESTINO > /dev/null 2>&1" >> /tmp/crontmp
    crontab /tmp/crontmp
    rm /tmp/crontmp
    
    DATA_NOME="${CRON_D}/${CRON_MON}"
    [ "$TIPO_DATA" == "4" ] && DATA_NOME="Diario"
    echo "[v] Agendado para: $DATA_NOME as $CRON_H:$CRON_M."
    log_w "Novo script engatilhado no cron: $SCRIPT_DESTINO (Data: $DATA_NOME $CRON_H:$CRON_M)"
fi