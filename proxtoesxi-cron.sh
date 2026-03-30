#!/bin/bash

# ==========================================
# ESXi to Proxmox Migration Toolkit V15 (AUTONOMOUS CRON EDITION)
# ==========================================

# ==========================================
# ⚙️ CONFIGURAÇÃO AUTÔNOMA (CÉREBRO)
# Edite as variáveis abaixo antes de executar ou agendar.
# ==========================================

MODO_IMPORT="3" # [1] Plugin ESXi | [2] SSHFS Remoto | [3] Backup USB/Local

STORAGE_DESTINO="zfs_raid10"

# Automações (1=Sim | 0=Não)
OPT_INJECT="1"       # Injeta ISO com script pós-install de rede/agent
OPT_START="1"        # Liga a VM no Proxmox após o sucesso
OPT_PREFLIGHT="0"    # Desliga VM e consolida Snapshot no ESXi (Modos 1 e 2)
OPT_RELIGAR="0"      # Religa a VM no ESXi após sucesso da cópia

# Informações de Origem (Ajuste conforme o Modo escolhido acima)
ESXI_HOST="172.16.180.190"              # Obrigatório se PREFLIGHT=1 ou RELIGAR=1 ou MODO=2
ESXI_USER="root"                        # Usuário via SSH Keys
STORAGE_ORIGEM="dl380-vms"              # Obrigatório para Modo 1
DS_NOME="datastore1"                    # Obrigatório para Modo 2
USB_PATH="/mnt/hdd_bkp/VM_UNIFI_BACKUP" # Obrigatório para Modo 3

# 📋 FILA DE EXECUÇÃO
# Sintaxe: "nome_do_arquivo.vmx|vlan1 vlan2" (Deixe vazio após o | se não tiver VLAN)
# Para importar TODAS as VMs do diretório/storage sem VLAN, use: VMS_TARGET=("TODAS")
VMS_TARGET=(
    "unifi.vmx|"
    "ten-grafana.vmx|321 305"
)
# ==========================================


# ================= INÍCIO DO MOTOR (NÃO ALTERAR) =================
LOG_FILE="/var/log/migracao_esxi_proxmox.log"
CURRENT_VMID=""
IMPORT_PID=""
ISO_SCRIPT_PATH="/var/lib/vz/template/iso/pos_install_esxi.iso"

log_msg() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log_msg "======================================================"
log_msg "INICIANDO MIGRAÇÃO AUTÔNOMA V15 (Modo $MODO_IMPORT)"
log_msg "======================================================"

for pkg in genisoimage sshfs; do
    if ! command -v $pkg &> /dev/null; then apt-get update >/dev/null && apt-get install $pkg -y >/dev/null; fi
done

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

declare -A MAPA_VMS
if [ "$MODO_IMPORT" == "1" ]; then
    mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")
elif [ "$MODO_IMPORT" == "2" ]; then
    mkdir -p /mnt/esxi_sshfs
    log_msg "[*] Montando Datastore remoto via SSHFS..."
    sshfs "$ESXI_USER@$ESXI_HOST:/vmfs/volumes" /mnt/esxi_sshfs -o StrictHostKeyChecking=no,allow_other,IdentityFile=~/.ssh/id_rsa
    mapfile -t VMS_BRUTAS < <(find /mnt/esxi_sshfs/$DS_NOME -maxdepth 2 -name "*.vmx")
elif [ "$MODO_IMPORT" == "3" ]; then
    log_msg "[*] Mapeando VMs em $USB_PATH..."
    mapfile -t VMS_BRUTAS < <(find "$USB_PATH" -maxdepth 2 -name "*.vmx")
fi

for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done
if [ ${#MAPA_VMS[@]} -eq 0 ]; then log_msg "[x] Nenhuma VM encontrada. Verifique os caminhos. Abortando."; exit 1; fi

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

log_msg "Iniciando fila processamento..."

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
                log_msg "    [Pre-Flight] Desligando VM no ESXi..."
                ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.off $ESXI_VMID" > /dev/null
                sleep 5
            fi
            log_msg "    [Pre-Flight] Disparando Consolidacao de Snapshots..."
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/snapshot.removeall $ESXI_VMID" > /dev/null
            log_msg "    [Pre-Flight] Aguardando conclusao da consolidacao..."
            while ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vimsvc/task_list" | grep -qi "removeAllSnapshots"; do sleep 5; done
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
        log_msg "    -> VMX Parser Analítico..."
        MEM=$(grep -iE '^memSize' "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
        CORES=$(grep -iE '^numvcpus' "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
        
        qm create $CURRENT_VMID --name "$NOME_LIMPO" --memory "${MEM:-2048}" --sockets 1 --cores "${CORES:-1}" --cpu host --scsihw virtio-scsi-single --vga virtio --agent 1 --onboot 1
        
        EXIT_CODE=0
        while read -r line; do
            dev=$(echo "$line" | cut -d'.' -f1)
            bus=$(echo "$dev" | cut -d':' -f1)
            vmdk_name=$(echo "$line" | cut -d'"' -f2 | tr -d '\r')
            vmdk_path="$(dirname "$caminho_vm")/$vmdk_name"
            
            log_msg "    -> Importando disco $vmdk_name ($bus)..."
            qm importdisk $CURRENT_VMID "$vmdk_path" "$STORAGE_DESTINO" --format raw > /tmp/imp_${CURRENT_VMID}.log 2>&1
            VOL=$(grep -o "$STORAGE_DESTINO:vm-$CURRENT_VMID-disk-[0-9]*" /tmp/imp_${CURRENT_VMID}.log | head -n 1)
            if [ -n "$VOL" ]; then
                qm set $CURRENT_VMID --$bus "$VOL"
                [ "$bus" == "scsi0" ] && qm set $CURRENT_VMID --boot "order=$bus"
            else
                log_msg "    [x] Falha no disco $vmdk_name!"
                EXIT_CODE=1
            fi
        done < <(grep -i '\.fileName' "$caminho_vm" | grep -i '\.vmdk' | tr -d '\r')

        # VMX PARSER: Fixado para resolver as múltiplas NICs do USB
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
            log_msg "    -> Placa net${net_idx} VirtIO criada (MAC: $mac | VLAN: ${VLAN_ARRAY[$net_idx]:-Nenhuma})."
            ((net_idx++))
        done < <(grep -iE '^ethernet[0-9]+\.present.*=.*"TRUE"' "$caminho_vm" | tr -d '\r')
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        if [ "$OPT_INJECT" == "1" ]; then
            for drive in $(qm config $CURRENT_VMID | grep 'media=cdrom' | awk -F: '{print $1}'); do qm set $CURRENT_VMID --delete "$drive"; done
            qm set $CURRENT_VMID --ide2 local:iso/pos_install_esxi.iso,media=cdrom
        fi
        if [ "$OPT_RELIGAR" == "1" ]; then
            log_msg "    -> Relocando Power ON no ESXi..."
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.on $ESXI_VMID" > /dev/null
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

if [ "$MODO_IMPORT" == "2" ]; then umount -f /mnt/esxi_sshfs &>/dev/null; fi
log_msg "======================================================"
log_msg "Lote V15 finalizado!"