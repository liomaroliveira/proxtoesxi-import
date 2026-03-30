#!/bin/bash

# ==========================================
# Script de Importação Automática ESXi -> Proxmox V10 (CPU Host & Multi-NIC)
# ==========================================

LOG_FILE="/var/log/migracao_esxi_proxmox.log"
CURRENT_VMID=""
IMPORT_PID=""
ISO_SCRIPT_PATH="/var/lib/vz/template/iso/pos_install_esxi.iso"

log_msg() {
    local ts="[$(date +'%Y-%m-%d %H:%M:%S')]"
    echo -e "$ts $1" | tee -a "$LOG_FILE"
}

log_msg "======================================================"
log_msg "Iniciando sistema de importação V10 (CPU Host)."
log_msg "Log principal: $LOG_FILE"
log_msg "======================================================"

if ! command -v genisoimage &> /dev/null; then
    log_msg "[*] Instalando 'genisoimage' para criação do CD virtual..."
    apt-get update >/dev/null && apt-get install genisoimage -y >/dev/null
fi

cleanup() {
    log_msg "\n[!] AVISO: INTERRUPÇÃO DETECTADA (Ctrl+C)!"
    if [ -n "$IMPORT_PID" ]; then kill -9 $IMPORT_PID 2>/dev/null; fi
    if [ -n "$CURRENT_VMID" ]; then
        log_msg "[*] Removendo VM incompleta ($CURRENT_VMID)..."
        qm destroy $CURRENT_VMID --purge 1 >> "$LOG_FILE" 2>&1
    fi
    exit 1
}
trap cleanup SIGINT SIGTERM

processar_saida() {
    local prev_was_trans=0
    local last_trans=""
    while IFS= read -r line; do
        local ts="[$(date +'%Y-%m-%d %H:%M:%S')]"
        if [[ "$line" == transferred* ]]; then
            echo -en "\r$ts $line\033[K"
            last_trans="$line"
            prev_was_trans=1
        else
            if [[ $prev_was_trans -eq 1 ]]; then echo ""; echo "$ts $last_trans" >> "$LOG_FILE"; prev_was_trans=0; fi
            echo "$ts $line" | tee -a "$LOG_FILE"
        fi
    done
    if [[ $prev_was_trans -eq 1 ]]; then echo ""; echo "[$(date +'%Y-%m-%d %H:%M:%S')] $last_trans" >> "$LOG_FILE"; fi
}

# ================= SELETORES DE AUTOMAÇÃO =================
echo -e "\n=== OPÇÕES DE PÓS-IMPORTAÇÃO ==="
read -p "Deseja informar VLANs para as VMs? [1] Sim / [2] Não: " OPT_VLAN
read -p "Aplicar mutação cirúrgica de Hardware (Mantendo originais)? [1] Sim / [2] Não: " OPT_HW
read -p "Disponibilizar script pós-instalação via CD-ROM virtual? [1] Sim / [2] Não: " OPT_INJECT
read -p "Ligar as VMs automaticamente após a importação? [1] Sim / [2] Não: " OPT_START

if [ "$OPT_INJECT" == "1" ]; then
    log_msg "Gerando ISO com script de pós-instalação Multi-NIC..."
    TMP_DIR=$(mktemp -d)
    cat << 'EOF' > "$TMP_DIR/pos_import_esxi.sh"
#!/bin/bash
LOG="/root/migracao_completa.log"
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }
log "=== Iniciando validacao de rede e agentes ==="

mapfile -t NEW_IFS < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|altname')
mapfile -t OLD_IFS < <(awk '/^iface/ && $2 != "lo" {print $2}' /etc/network/interfaces | sort -u)

log "Hardware detectado: ${NEW_IFS[*]} | Config atual: ${OLD_IFS[*]}"

if [ ${#NEW_IFS[@]} -eq 0 ] || [ ${#OLD_IFS[@]} -eq 0 ]; then
    log "ERRO: Interfaces nao detectadas. Abortando."; exit 1
fi

ALTERADO=0
for i in "${!OLD_IFS[@]}"; do
    if [ -n "${NEW_IFS[$i]}" ] && [ "${OLD_IFS[$i]}" != "${NEW_IFS[$i]}" ]; then
        log "Atualizando ${OLD_IFS[$i]} -> ${NEW_IFS[$i]}..."
        sed -i "s/\b${OLD_IFS[$i]}\b/${NEW_IFS[$i]}/g" /etc/network/interfaces
        ALTERADO=1
    fi
done

if [ $ALTERADO -eq 1 ]; then
    log "Reiniciando servico de rede..."
    systemctl restart networking
    sleep 5
else
    log "Nomes corretos. Nenhuma alteracao necessaria."
fi

log "Testando conectividade..."
if ping -c 3 google.com &> /dev/null; then
    log "SUCESSO: Conectividade confirmada!"
    apt-get update -y &>> "$LOG"
    apt-get install qemu-guest-agent -y &>> "$LOG"
    systemctl enable --now qemu-guest-agent
    apt-get purge open-vm-tools -y &>> "$LOG"
    apt-get autoremove -y &>> "$LOG"
    log "=== Concluido com sucesso! ==="
else
    log "FALHA: Sem internet. Abortando para evitar quebra."; exit 1
fi
EOF
    chmod +x "$TMP_DIR/pos_import_esxi.sh"
    genisoimage -quiet -J -R -V "POS_INSTALL" -o "$ISO_SCRIPT_PATH" "$TMP_DIR"
    rm -rf "$TMP_DIR"
fi

# ================= BUSCA DE STORAGES E VMS =================
echo -e "\nBuscando storages do tipo ESXi..."
mapfile -t ESXI_STORAGES < <(pvesm status | awk 'NR>1 && $2=="esxi" {print $1}')
if [ ${#ESXI_STORAGES[@]} -eq 0 ]; then log_msg "Erro: Nenhum storage ESXi."; exit 1; fi

for i in "${!ESXI_STORAGES[@]}"; do echo "[$((i+1))] ${ESXI_STORAGES[$i]}"; done
read -p "Digite o NÚMERO da origem: " NUM_ORIGEM
STORAGE_ORIGEM="${ESXI_STORAGES[$((NUM_ORIGEM-1))]}"

mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")
declare -A MAPA_VMS
for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done

mapfile -t DEST_STORAGES < <(pvesm status | awk 'NR>1 && $4>0 {print $1, $2, $4, $6}')
declare -A MAPA_DESTINO
idx=1
for info in "${DEST_STORAGES[@]}"; do
    read -r nome_st tipo_st total_kb livre_kb <<< "$info"
    total_gb=$(awk "BEGIN {printf \"%.2f\", $total_kb / 1048576}")
    livre_gb=$(awk "BEGIN {printf \"%.2f\", $livre_kb / 1048576}")
    echo "[$idx] $nome_st | Tipo: $tipo_st | Total: $total_gb GB | Livre: $livre_gb GB"
    MAPA_DESTINO[$idx]=$nome_st
    ((idx++))
done
read -p "Digite o NÚMERO do destino: " NUM_DESTINO
STORAGE_DESTINO="${MAPA_DESTINO[$NUM_DESTINO]}"

echo -e "\n======================================================"
for i in $(seq 1 ${#VMS_BRUTAS[@]}); do
    NOME_EXIBICAO=$(echo "${MAPA_VMS[$i]}" | awk -F'/' '{print $2 " / " $NF}')
    echo "[$i] $NOME_EXIBICAO"
done
echo "======================================================"
read -p "VMs a importar (ex: 1 3 5) ou 'TODAS': " ESCOLHA_USER

VMS_PARA_IMPORTAR=()
if [[ "${ESCOLHA_USER^^}" == "TODAS" ]]; then
    for i in $(seq 1 ${#VMS_BRUTAS[@]}); do VMS_PARA_IMPORTAR+=("$i"); done
else
    for num in $ESCOLHA_USER; do VMS_PARA_IMPORTAR+=("$num"); done
fi

declare -A MAPA_VLANS
if [ "$OPT_VLAN" == "1" ]; then
    echo -e "\n=== CONFIGURAÇÃO DE VLAN ==="
    echo "DICA: Se a VM tiver mais de 1 placa, digite as VLANs na ordem separadas por espaço (ex: 321 305)."
    echo "DICA: Pressione Enter para deixar sem VLAN."
    for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
        nome_limpo=$(echo "${MAPA_VMS[$num_vm]}" | awk -F'/' '{print $2 " / " $NF}')
        read -p "VLAN(s) para [$nome_limpo]: " vlan_input
        MAPA_VLANS[$num_vm]=$vlan_input
    done
fi

# ================= LOOP DE IMPORTAÇÃO =================
log_msg "\n======================================================"
log_msg "Iniciando fila..."

for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
    caminho_vm="${MAPA_VMS[$num_vm]}"
    CURRENT_VMID=$(pvesh get /cluster/nextid)
    nome_limpo=$(echo "$caminho_vm" | awk -F'/' '{print $2 " / " $NF}')
    
    log_msg "------------------------------------------------------"
    log_msg "Importando: [$num_vm] $nome_limpo -> ID $CURRENT_VMID"
    
    qm import $CURRENT_VMID "$caminho_vm" --storage "$STORAGE_DESTINO" > >(processar_saida) 2>&1 &
    IMPORT_PID=$!
    wait $IMPORT_PID
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        log_msg "[v] VM $CURRENT_VMID importada. Aplicando mutações..."
        
        if [ "$OPT_HW" == "1" ]; then
            OLD_CORES=$(qm config $CURRENT_VMID | awk '/^cores:/ {print $2}')
            OLD_SOCKETS=$(qm config $CURRENT_VMID | awk '/^sockets:/ {print $2}')
            [ -z "$OLD_CORES" ] && OLD_CORES=1
            [ -z "$OLD_SOCKETS" ] && OLD_SOCKETS=1
            TOTAL_CORES=$((OLD_CORES * OLD_SOCKETS))
            
            DISCO_BOOT=$(qm config $CURRENT_VMID | grep -E '^(scsi|ide|sata|virtio)[0-9]+:' | grep -v 'cdrom' | head -n 1 | awk -F: '{print $1}')
            
            # --- ATUALIZAÇÃO V10: INSERIDO --cpu host ---
            qm set $CURRENT_VMID --sockets 1 --cores $TOTAL_CORES --cpu host --vga virtio --scsihw virtio-scsi-single --agent 1 --onboot 1
            
            if [ -n "$DISCO_BOOT" ]; then
                qm set $CURRENT_VMID --boot "order=$DISCO_BOOT"
            fi
            
            mapfile -t PLACAS_REDE < <(qm config $CURRENT_VMID | grep -E '^net[0-9]+:' | awk -F: '{print $1}')
            IFS=' ' read -r -a VLAN_ARRAY <<< "${MAPA_VLANS[$num_vm]}"
            
            for idx in "${!PLACAS_REDE[@]}"; do
                placa="${PLACAS_REDE[$idx]}"
                OLD_NET=$(qm config $CURRENT_VMID | grep "^${placa}:" | sed "s/^${placa}: //")
                MAC=$(echo "$OLD_NET" | grep -o -i -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
                BRIDGE=$(echo "$OLD_NET" | grep -o 'bridge=[^,]*')
                FIREWALL=$(echo "$OLD_NET" | grep -o 'firewall=[0-9]')
                
                NEW_NET="virtio"
                [ -n "$MAC" ] && NEW_NET="${NEW_NET}=${MAC}"
                [ -n "$BRIDGE" ] && NEW_NET="${NEW_NET},${BRIDGE}" || NEW_NET="${NEW_NET},bridge=vmbr0"
                [ -n "$FIREWALL" ] && NEW_NET="${NEW_NET},${FIREWALL}"
                
                if [ -n "${VLAN_ARRAY[$idx]}" ]; then
                    NEW_NET="${NEW_NET},tag=${VLAN_ARRAY[$idx]}"
                fi
                
                qm set $CURRENT_VMID --$placa "$NEW_NET"
                log_msg "    -> Placa $placa convertida. MAC: $MAC | VLAN: ${VLAN_ARRAY[$idx]:-Nenhuma}"
            done
        fi
        
        if [ "$OPT_INJECT" == "1" ]; then
            DRIVES_CD=$(qm config $CURRENT_VMID | grep 'media=cdrom' | awk -F: '{print $1}')
            for drive in $DRIVES_CD; do
                qm set $CURRENT_VMID --delete "$drive"
            done
            qm set $CURRENT_VMID --ide2 local:iso/pos_install_esxi.iso,media=cdrom
        fi
        
        if [ "$OPT_START" == "1" ]; then
            log_msg "[*] Ligando a VM $CURRENT_VMID..."
            qm start $CURRENT_VMID
        fi
        
        log_msg "[v] Concluído: $nome_limpo."
    else
        log_msg "[x] ERRO na importação (Código: $EXIT_CODE)."
    fi
    
    CURRENT_VMID=""
    IMPORT_PID=""
    sleep 2
done

log_msg "======================================================"
log_msg "Lote finalizado com sucesso! Script V10 concluído."