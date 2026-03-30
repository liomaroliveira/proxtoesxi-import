#!/bin/bash

# ==========================================
# Script de Importação Automática ESXi -> Proxmox V5
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
log_msg "Iniciando sistema de importação V5 (Boot Seguro & MAC Preserve)."
log_msg "Log principal: $LOG_FILE"
log_msg "======================================================"

if ! command -v genisoimage &> /dev/null; then
    log_msg "[*] Instalando 'genisoimage' para criação do CD virtual..."
    apt-get update >/dev/null && apt-get install genisoimage -y >/dev/null
fi

cleanup() {
    log_msg "\n[!] AVISO: INTERRUPÇÃO DETECTADA (Ctrl+C)!"
    if [ -n "$IMPORT_PID" ]; then
        kill -9 $IMPORT_PID 2>/dev/null
    fi
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
            if [[ $prev_was_trans -eq 1 ]]; then
                echo "" 
                echo "$ts $last_trans" >> "$LOG_FILE"
                prev_was_trans=0
            fi
            echo "$ts $line" | tee -a "$LOG_FILE"
        fi
    done
    if [[ $prev_was_trans -eq 1 ]]; then
        echo ""
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $last_trans" >> "$LOG_FILE"
    fi
}

# ================= SELETORES DE AUTOMAÇÃO =================
echo -e "\n=== OPÇÕES DE PÓS-IMPORTAÇÃO ==="
read -p "Deseja informar VLANs para cada VM? [1] Sim / [2] Não: " OPT_VLAN
read -p "Aplicar ajustes de Hardware (Agent, Boot, VirtIO, Sockets)? [1] Sim / [2] Não: " OPT_HW
read -p "Disponibilizar script pós-instalação via CD-ROM virtual? [1] Sim / [2] Não: " OPT_INJECT
read -p "Ligar as VMs automaticamente após a importação? [1] Sim / [2] Não: " OPT_START

if [ "$OPT_INJECT" == "1" ]; then
    log_msg "Gerando ISO com script de pós-instalação..."
    TMP_DIR=$(mktemp -d)
    cat << 'EOF' > "$TMP_DIR/pos_import_esxi.sh"
#!/bin/bash
LOG="/root/migracao_completa.log"
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }

log "=== Iniciando validacao de rede e agentes ==="
NEW_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo\|altname' | head -n 1)
OLD_IF=$(awk '/^iface/ && $2 != "lo" {print $2; exit}' /etc/network/interfaces)

log "Hardware detectado: $NEW_IF"
log "Configuracao atual: $OLD_IF"

if [ -z "$NEW_IF" ] || [ -z "$OLD_IF" ]; then
    log "ERRO: Interfaces nao detectadas. Abortando."
    exit 1
fi

if [ "$NEW_IF" != "$OLD_IF" ]; then
    log "Inconsistencia detectada. Atualizando $OLD_IF -> $NEW_IF..."
    sed -i "s/$OLD_IF/$NEW_IF/g" /etc/network/interfaces
    log "Reiniciando serviço de rede..."
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
    log "FALHA: Sem internet. Abortando para evitar quebra."
    exit 1
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
    for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
        nome_limpo=$(echo "${MAPA_VMS[$num_vm]}" | awk -F'/' '{print $2 " / " $NF}')
        read -p "VLAN para [$nome_limpo] (Enter para deixar em branco/sem vlan): " vlan_id
        MAPA_VLANS[$num_vm]=$vlan_id
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
        log_msg "[v] VM $CURRENT_VMID importada. Aplicando automações..."
        
        if [ "$OPT_HW" == "1" ]; then
            # FILTRO CORRIGIDO: Ignora qualquer cdrom e pega o primeiro disco real
            DISCO_BOOT=$(qm config $CURRENT_VMID | grep -E '^(scsi|ide|sata|virtio)[0-9]+:' | grep -v 'cdrom' | head -n 1 | awk -F: '{print $1}')
            
            qm set $CURRENT_VMID --agent 1
            qm set $CURRENT_VMID --onboot 1
            qm set $CURRENT_VMID --sockets 1
            qm set $CURRENT_VMID --vga virtio
            qm set $CURRENT_VMID --scsihw virtio-scsi-single
            
            # Aplica o boot no disco real garantindo que cdrom fique de fora da ordem
            if [ -n "$DISCO_BOOT" ]; then
                qm set $CURRENT_VMID --boot order=$DISCO_BOOT
            fi
            
            # PRESERVAÇÃO DO MAC ADDRESS ORIGINAL
            MAC_ATUAL=$(qm config $CURRENT_VMID | grep '^net0:' | grep -o -i -E '([0-9a-f]{2}:){5}[0-9a-f]{2}')
            
            if [ -n "$MAC_ATUAL" ]; then
                NET_CONFIG="virtio=${MAC_ATUAL},bridge=vmbr0"
            else
                NET_CONFIG="virtio,bridge=vmbr0"
            fi
            
            if [ -n "${MAPA_VLANS[$num_vm]}" ]; then
                NET_CONFIG="$NET_CONFIG,tag=${MAPA_VLANS[$num_vm]}"
            fi
            
            qm set $CURRENT_VMID --net0 "$NET_CONFIG"
        fi
        
        if [ "$OPT_INJECT" == "1" ]; then
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
log_msg "Lote finalizado com sucesso!"