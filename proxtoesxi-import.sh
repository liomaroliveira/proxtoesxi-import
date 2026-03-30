#!/bin/bash

# ==========================================
# ESXi to Proxmox Migration Toolkit V14 (Enterprise Edition)
# Desenvolvido para migrações via Plugin, SSHFS ou USB.
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
log_msg "Iniciando ESXi Migration Toolkit V14."
log_msg "Log principal: $LOG_FILE"
log_msg "======================================================"

# 1. Instalação de Dependências
for pkg in genisoimage sshpass sshfs jq; do
    if ! command -v $pkg &> /dev/null; then
        log_msg "[*] Instalando pacote ausente: $pkg..."
        apt-get update >/dev/null && apt-get install $pkg -y >/dev/null
    fi
done

cleanup() {
    log_msg "\n[!] AVISO: INTERRUPÇÃO DETECTADA (Ctrl+C)!"
    if [ -n "$IMPORT_PID" ]; then kill -9 $IMPORT_PID 2>/dev/null; fi
    if [ -n "$CURRENT_VMID" ]; then
        log_msg "[*] Removendo VM incompleta ($CURRENT_VMID)..."
        qm destroy $CURRENT_VMID --purge 1 >> "$LOG_FILE" 2>&1
    fi
    umount -f /mnt/esxi_sshfs &>/dev/null
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

# ================= MENU PRINCIPAL =================
echo -e "\n=== MODO DE IMPORTAÇÃO ==="
echo "[1] Via Storage Plugin Proxmox (Padrão, mais seguro)"
echo "[2] Via SSHFS (Monta o ESXi remoto, ideal para contornar falhas de API)"
echo "[3] Via USB/Armazenamento Local (Para backups offline)"
read -p "Sua escolha [1-3]: " MODO_IMPORT

echo -e "\n=== OPÇÕES GLOBAIS ==="
read -p "Deseja informar VLANs para as VMs? [1] Sim / [2] Não: " OPT_VLAN
read -p "Disponibilizar script pós-instalação via CD-ROM virtual? [1] Sim / [2] Não: " OPT_INJECT
read -p "Ligar as VMs NO PROXMOX automaticamente após a importação? [1] Sim / [2] Não: " OPT_START

# Credenciais SSH (Necessário para Pre-Flight de Modo 1 e Modo 2)
SSH_VALIDO=0
if [ "$MODO_IMPORT" == "1" ] || [ "$MODO_IMPORT" == "2" ]; then
    echo -e "\n=== CREDENCIAIS DO ESXI (Para Snapshot/Desligamento) ==="
    read -p "Deseja aplicar Pre-Flight (Desligar + Consolidar Snapshots) via SSH? [1] Sim / [2] Não: " OPT_PREFLIGHT
    read -p "Religar a VM no ESXi após concluir com sucesso? [1] Sim / [2] Não: " OPT_RELIGAR_GLOBAL
    
    if [ "$OPT_PREFLIGHT" == "1" ] || [ "$OPT_RELIGAR_GLOBAL" == "1" ] || [ "$MODO_IMPORT" == "2" ]; then
        read -p "IP do servidor ESXi de origem: " ESXI_HOST
        read -p "Usuário SSH do ESXi (ex: root): " ESXI_USER
        read -s -p "Senha do ESXi: " ESXI_PASS
        echo ""
        
        log_msg "[*] Testando conexão SSH com $ESXI_HOST..."
        if sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ESXI_USER@$ESXI_HOST" "echo OK" &>/dev/null; then
            log_msg "[v] Conexão SSH estabelecida."
            SSH_VALIDO=1
        else
            log_msg "[x] Falha SSH. Funcionalidades de controle remoto desativadas."
            OPT_PREFLIGHT="2"; OPT_RELIGAR_GLOBAL="2"
            if [ "$MODO_IMPORT" == "2" ]; then log_msg "Modo SSHFS abortado por falha de login."; exit 1; fi
        fi
    fi
else
    OPT_PREFLIGHT="2"; OPT_RELIGAR_GLOBAL="2"
fi

# Cria o ISO do Agent
if [ "$OPT_INJECT" == "1" ]; then
    log_msg "Gerando ISO pós-instalação..."
    TMP_DIR=$(mktemp -d)
    cat << 'EOF' > "$TMP_DIR/pos_import_esxi.sh"
#!/bin/bash
LOG="/root/migracao_completa.log"
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }
log "=== Iniciando validacao de rede e agentes ==="
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
else
    log "FALHA: Sem internet. Abortando."; exit 1
fi
EOF
    chmod +x "$TMP_DIR/pos_import_esxi.sh"
    genisoimage -quiet -J -R -V "POS_INSTALL" -o "$ISO_SCRIPT_PATH" "$TMP_DIR"
    rm -rf "$TMP_DIR"
fi

# ================= BUSCA DE VMS =================
declare -A MAPA_VMS
if [ "$MODO_IMPORT" == "1" ]; then
    mapfile -t ESXI_STORAGES < <(pvesm status | awk 'NR>1 && $2=="esxi" {print $1}')
    for i in "${!ESXI_STORAGES[@]}"; do echo "[$((i+1))] ${ESXI_STORAGES[$i]}"; done
    read -p "Selecione o storage origem: " n_origem
    STORAGE_ORIGEM="${ESXI_STORAGES[$((n_origem-1))]}"
    mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")
    for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done

elif [ "$MODO_IMPORT" == "2" ]; then
    mkdir -p /mnt/esxi_sshfs
    log_msg "[*] Montando Datastore remoto via SSHFS..."
    echo "$ESXI_PASS" | sshfs "$ESXI_USER@$ESXI_HOST:/vmfs/volumes" /mnt/esxi_sshfs -o password_stdin,StrictHostKeyChecking=no,allow_other
    read -p "Digite o NOME do Datastore no ESXi (ex: datastore1): " DS_NOME
    log_msg "[*] Mapeando VMs no datastore $DS_NOME..."
    mapfile -t VMS_BRUTAS < <(find /mnt/esxi_sshfs/$DS_NOME -maxdepth 2 -name "*.vmx")
    for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done

elif [ "$MODO_IMPORT" == "3" ]; then
    read -p "Digite o caminho absoluto do diretório (ex: /mnt/hdd_bkp/VM_UNIFI_BACKUP): " USB_PATH
    log_msg "[*] Mapeando VMs em $USB_PATH..."
    mapfile -t VMS_BRUTAS < <(find "$USB_PATH" -maxdepth 2 -name "*.vmx")
    for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done
fi

if [ ${#MAPA_VMS[@]} -eq 0 ]; then log_msg "[x] Nenhuma VM encontrada. Abortando."; exit 1; fi

# Seleção de Destino
echo -e "\nArmazenamentos de Destino:"
mapfile -t DEST_STORAGES < <(pvesm status | awk 'NR>1 && $4>0 {print $1}')
for i in "${!DEST_STORAGES[@]}"; do echo "[$((i+1))] ${DEST_STORAGES[$i]}"; done
read -p "Destino: " n_dest
STORAGE_DESTINO="${DEST_STORAGES[$((n_dest-1))]}"

# Seleção de VMs
echo -e "\n======================================================"
for i in $(seq 1 ${#VMS_BRUTAS[@]}); do echo "[$i] ${MAPA_VMS[$i]}"; done
echo "======================================================"
read -p "VMs a importar (ex: 1 3) ou 'TODAS': " ESCOLHA_USER

VMS_PARA_IMPORTAR=()
if [[ "${ESCOLHA_USER^^}" == "TODAS" ]]; then
    for i in $(seq 1 ${#VMS_BRUTAS[@]}); do VMS_PARA_IMPORTAR+=("$i"); done
else
    for num in $ESCOLHA_USER; do VMS_PARA_IMPORTAR+=("$num"); done
fi

# Configurações Individuais
declare -A MAPA_VLANS
declare -A MAPA_RELIGAR
if [ "$OPT_VLAN" == "1" ] || [ "$OPT_RELIGAR_GLOBAL" == "1" ]; then
    echo -e "\n=== SETUP INDIVIDUAL ==="
    for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
        ARQ_NOME=$(basename "${MAPA_VMS[$num_vm]}")
        echo -e "\n[*] VM: $ARQ_NOME"
        if [ "$OPT_VLAN" == "1" ]; then read -p "    -> VLAN(s) (separadas por espaço): " vlan_input; MAPA_VLANS[$num_vm]=$vlan_input; fi
        if [ "$OPT_RELIGAR_GLOBAL" == "1" ]; then read -p "    -> Religar na origem no final? [1] Sim / [2] Não: " rel_in; MAPA_RELIGAR[$num_vm]=$rel_in; fi
    done
fi

# ================= LOOP DE IMPORTAÇÃO =================
log_msg "\n======================================================"
log_msg "Iniciando fila..."

for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
    caminho_vm="${MAPA_VMS[$num_vm]}"
    CURRENT_VMID=$(pvesh get /cluster/nextid)
    ARQUIVO_VMX=$(basename "$caminho_vm")
    NOME_LIMPO=$(grep -i '^displayName' "$caminho_vm" 2>/dev/null | cut -d'"' -f2)
    [ -z "$NOME_LIMPO" ] && NOME_LIMPO="$ARQUIVO_VMX"

    log_msg "------------------------------------------------------"
    log_msg "Processando: [$num_vm] $NOME_LIMPO -> ID Proxmox $CURRENT_VMID"

    # PRE-FLIGHT (Modo 1 e 2 via SSH)
    if [ "$OPT_PREFLIGHT" == "1" ] && [ "$SSH_VALIDO" == "1" ]; then
        ESXI_VMID=$(sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/getallvms" | grep "$ARQUIVO_VMX" | awk '{print $1}' | head -n 1)
        if [ -n "$ESXI_VMID" ]; then
            ESTADO_ANTES=$(sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.getstate $ESXI_VMID" | grep -i 'Powered')
            if echo "$ESTADO_ANTES" | grep -qi "Powered on"; then
                log_msg "    [Pre-Flight] Desligando VM no ESXi..."
                sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.off $ESXI_VMID" > /dev/null
                sleep 5
            fi
            log_msg "    [Pre-Flight] Disparando Consolidacao de Snapshots..."
            sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/snapshot.removeall $ESXI_VMID" > /dev/null
            
            log_msg "    [Pre-Flight] Aguardando conclusao da consolidacao (isso pode demorar)..."
            while sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vimsvc/task_list" | grep -qi "removeAllSnapshots"; do
                sleep 5
            done
            log_msg "    [Pre-Flight] Consolidacao concluida!"
        else
            log_msg "    [Pre-Flight] VM não encontrada na origem para consolidar. Seguindo..."
        fi
    fi

    # MODO 1: Importação via API NATIVA
    if [ "$MODO_IMPORT" == "1" ]; then
        log_msg "    -> Importando via Plugin ESXi..."
        qm import $CURRENT_VMID "$caminho_vm" --storage "$STORAGE_DESTINO" > >(processar_saida) 2>&1 &
        IMPORT_PID=$!
        wait $IMPORT_PID
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            log_msg "    -> Aplicando Mutações Nativas..."
            OLD_CORES=$(qm config $CURRENT_VMID | awk '/^cores:/ {print $2}'); [ -z "$OLD_CORES" ] && OLD_CORES=1
            OLD_SOCKETS=$(qm config $CURRENT_VMID | awk '/^sockets:/ {print $2}'); [ -z "$OLD_SOCKETS" ] && OLD_SOCKETS=1
            qm set $CURRENT_VMID --sockets 1 --cores $((OLD_CORES * OLD_SOCKETS)) --cpu host --vga virtio --scsihw virtio-scsi-single --agent 1 --onboot 1
            
            DISCO_BOOT=$(qm config $CURRENT_VMID | grep -E '^(scsi|ide|sata|virtio)[0-9]+:' | grep -v 'cdrom' | head -n 1 | awk -F: '{print $1}')
            [ -n "$DISCO_BOOT" ] && qm set $CURRENT_VMID --boot "order=$DISCO_BOOT"

            mapfile -t PLACAS_REDE < <(qm config $CURRENT_VMID | grep -E '^net[0-9]+:' | awk -F: '{print $1}')
            IFS=' ' read -r -a VLAN_ARRAY <<< "${MAPA_VLANS[$num_vm]}"
            for idx in "${!PLACAS_REDE[@]}"; do
                placa="${PLACAS_REDE[$idx]}"
                OLD_NET=$(qm config $CURRENT_VMID | grep "^${placa}:" | sed "s/^${placa}: //")
                MAC=$(echo "$OLD_NET" | grep -o -i -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
                NET_CONFIG="virtio=${MAC:-},bridge=vmbr0"
                [ -n "${VLAN_ARRAY[$idx]}" ] && NET_CONFIG="$NET_CONFIG,tag=${VLAN_ARRAY[$idx]}"
                qm set $CURRENT_VMID --$placa "$NET_CONFIG"
            done
        fi

    # MODO 2/3: VMX PARSER + IMPORT DISK
    else
        log_msg "    -> Parsing do VMX via Modo Analítico (Local/SSHFS)..."
        MEM=$(grep -i '^memSize' "$caminho_vm" | cut -d'"' -f2 | tr -d ' ')
        CORES=$(grep -i '^numvcpus' "$caminho_vm" | cut -d'"' -f2 | tr -d ' ')
        
        log_msg "    -> Criando Casca da VM (RAM: ${MEM:-2048}MB, Cores: ${CORES:-1})..."
        qm create $CURRENT_VMID --name "$NOME_LIMPO" --memory "${MEM:-2048}" --sockets 1 --cores "${CORES:-1}" --cpu host --scsihw virtio-scsi-single --vga virtio --agent 1 --onboot 1
        
        # Parse Discos
        EXIT_CODE=0
        grep -i '\.fileName' "$caminho_vm" | grep -i '\.vmdk' | while read -r line; do
            dev=$(echo "$line" | cut -d'.' -f1) # ex: scsi0:0
            bus=$(echo "$dev" | cut -d':' -f1)  # ex: scsi0
            vmdk_name=$(echo "$line" | cut -d'"' -f2)
            vmdk_path="$(dirname "$caminho_vm")/$vmdk_name"
            
            log_msg "    -> Importando disco $vmdk_name no barramento $bus (Isso vai demorar)..."
            qm importdisk $CURRENT_VMID "$vmdk_path" "$STORAGE_DESTINO" --format raw > /tmp/imp_${CURRENT_VMID}.log 2>&1
            VOL=$(grep -o "$STORAGE_DESTINO:vm-$CURRENT_VMID-disk-[0-9]*" /tmp/imp_${CURRENT_VMID}.log | head -n 1)
            if [ -n "$VOL" ]; then
                qm set $CURRENT_VMID --$bus "$VOL"
                [ "$bus" == "scsi0" ] && qm set $CURRENT_VMID --boot "order=$bus"
            else
                log_msg "    [x] Falha ao importar disco $vmdk_name!"
                EXIT_CODE=1
            fi
        done

        # Parse Redes
        IFS=' ' read -r -a VLAN_ARRAY <<< "${MAPA_VLANS[$num_vm]}"
        net_idx=0
        grep -i 'ethernet[0-9]*\.present.*TRUE' "$caminho_vm" | while read -r eth_line; do
            eth_prefix=$(echo "$eth_line" | cut -d'.' -f1) # ex: ethernet0
            mac=$(grep -i "^${eth_prefix}.generatedAddress" "$caminho_vm" | cut -d'"' -f2)
            [ -z "$mac" ] && mac=$(grep -i "^${eth_prefix}.address " "$caminho_vm" | cut -d'"' -f2)
            
            NET_CONFIG="virtio,bridge=vmbr0"
            [ -n "$mac" ] && NET_CONFIG="virtio=${mac},bridge=vmbr0"
            [ -n "${VLAN_ARRAY[$net_idx]}" ] && NET_CONFIG="$NET_CONFIG,tag=${VLAN_ARRAY[$net_idx]}"
            
            qm set $CURRENT_VMID --net${net_idx} "$NET_CONFIG"
            ((net_idx++))
        done
    fi

    # AÇÕES PÓS-IMPORTAÇÃO (Todos os modos)
    if [ $EXIT_CODE -eq 0 ]; then
        if [ "$OPT_INJECT" == "1" ]; then
            for drive in $(qm config $CURRENT_VMID | grep 'media=cdrom' | awk -F: '{print $1}'); do qm set $CURRENT_VMID --delete "$drive"; done
            qm set $CURRENT_VMID --ide2 local:iso/pos_install_esxi.iso,media=cdrom
        fi
        
        if [ "${MAPA_RELIGAR[$num_vm]}" == "1" ] && [ "$SSH_VALIDO" == "1" ]; then
            log_msg "    -> Relocando Power ON no ESXi..."
            sshpass -p "$ESXI_PASS" ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.on $ESXI_VMID" > /dev/null
        fi

        if [ "$OPT_START" == "1" ]; then
            log_msg "    [*] Ligando a VM $CURRENT_VMID no Proxmox..."
            qm start $CURRENT_VMID
        fi
        log_msg "[v] Concluído com sucesso!"
    else
        log_msg "[x] ERRO na importação da VM."
    fi
    
    sleep 2
done

# Limpeza Final
if [ "$MODO_IMPORT" == "2" ]; then umount -f /mnt/esxi_sshfs &>/dev/null; fi
log_msg "======================================================"
log_msg "Lote V14 finalizado com sucesso!"