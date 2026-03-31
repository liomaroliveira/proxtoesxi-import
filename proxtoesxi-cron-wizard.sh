#!/bin/bash

# ==========================================
# WIZARD GERADOR DE MIGRAÇÃO AUTÔNOMA (V18)
# ==========================================

LOG_FILE="/var/log/migracao_esxi_proxmox.log"
log_w() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [WIZARD] $1" | tee -a "$LOG_FILE"; }

clear
echo "======================================================"
echo "WIZARD DE AGENDAMENTO DE MIGRAÇÃO ESXi -> PROXMOX"
echo "======================================================"
log_w "Iniciando Wizard de Agendamento V18..."

# --- 1. CONFIGURAÇÕES GLOBAIS ---
echo -e "\n=== MODO DE IMPORTAÇÃO ==="
echo "[1] Via Storage Plugin Proxmox (Padrão)"
echo "[2] Via SSHFS (Monta o ESXi remoto)"
echo "[3] Via USB/Armazenamento Local (Para backups offline)"
read -p "Escolha [1-3]: " MODO_IMPORT
log_w "Modo de Importação selecionado: $MODO_IMPORT"

echo -e "\n=== DESTINO ==="
mapfile -t DEST_STORAGES < <(pvesm status | awk 'NR>1 && $4>0 {print $1}')
for i in "${!DEST_STORAGES[@]}"; do echo "[$((i+1))] ${DEST_STORAGES[$i]}"; done
read -p "Número do storage de Destino: " n_dest
STORAGE_DESTINO="${DEST_STORAGES[$((n_dest-1))]}"
log_w "Storage de Destino selecionado: $STORAGE_DESTINO"

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
    log_w "Testando conexao SSH sem senha com $ESXI_HOST..."
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ESXI_USER@$ESXI_HOST" "echo OK" &>/dev/null; then
        log_w "ERRO: Conexao SSH sem senha falhou."
        echo "[!] ERRO: Conexão SSH sem senha falhou. Configure as chaves RSA antes de agendar."
        exit 1
    fi
    log_w "Conexao SSH validada com sucesso."
fi

declare -A MAPA_VMS
if [ "$MODO_IMPORT" == "1" ]; then
    mapfile -t ESXI_STORAGES < <(pvesm status | awk 'NR>1 && $2=="esxi" {print $1}')
    for i in "${!ESXI_STORAGES[@]}"; do echo "[$((i+1))] ${ESXI_STORAGES[$i]}"; done
    read -p "Número do storage Origem ESXi: " n_origem
    STORAGE_ORIGEM="${ESXI_STORAGES[$((n_origem-1))]}"
    log_w "Storage de Origem selecionado: $STORAGE_ORIGEM"
    mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")

elif [ "$MODO_IMPORT" == "2" ]; then
    read -p "Digite o NOME do Datastore no ESXi (ex: datastore1): " DS_NOME
    log_w "Mapeando Datastore $DS_NOME via SSHFS..."
    mkdir -p /mnt/esxi_sshfs
    sshfs "$ESXI_USER@$ESXI_HOST:/vmfs/volumes" /mnt/esxi_sshfs -o StrictHostKeyChecking=no,allow_other,IdentityFile=~/.ssh/id_rsa
    mapfile -t VMS_BRUTAS < <(find /mnt/esxi_sshfs/$DS_NOME -maxdepth 2 -name "*.vmx")
    umount -f /mnt/esxi_sshfs &>/dev/null

elif [ "$MODO_IMPORT" == "3" ]; then
    read -p "Digite o caminho ABSOLUTO do diretório USB (ex: /mnt/hdd_bkp/VM_UNIFI_BACKUP): " USB_PATH
    log_w "Mapeando VMs locais em $USB_PATH..."
    mapfile -t VMS_BRUTAS < <(find "$USB_PATH" -maxdepth 2 -name "*.vmx")
fi

for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done
if [ ${#MAPA_VMS[@]} -eq 0 ]; then
    log_w "ERRO: Nenhuma VM encontrada na origem."
    echo "[x] Nenhuma VM encontrada na origem. Abortando."
    exit 1
fi

# --- 3. SELEÇÃO E VLANs ---
echo -e "\n=== VMS ENCONTRADAS ==="
for i in $(seq 1 ${#VMS_BRUTAS[@]}); do
    ARQ=$(basename "${MAPA_VMS[$i]}")
    echo "[$i] $ARQ"
done
echo "======================================================"
read -p "Quais VMs deseja agendar? (ex: 1 3 ou TODAS): " ESCOLHA_USER

ARRAY_VMS_CODE=""
if [[ "${ESCOLHA_USER^^}" == "TODAS" ]]; then
    ARRAY_VMS_CODE="    \"TODAS\""
else
    for num in $ESCOLHA_USER; do
        ARQ_VMX=$(basename "${MAPA_VMS[$num]}")
        read -p "VLANs para $ARQ_VMX (separadas por espaço, ou Enter p/ sem VLAN): " vlan_input
        ARRAY_VMS_CODE="${ARRAY_VMS_CODE}
    \"${ARQ_VMX}|${vlan_input}\""
        log_w "VM agendada: $ARQ_VMX | VLANs: ${vlan_input:-Nenhuma}"
    done
fi

# --- 4. GERAÇÃO DO SCRIPT AUTÔNOMO ---
SCRIPT_DESTINO="/root/executa_migracao_agendada.sh"
echo "[*] Gerando o script autônomo em $SCRIPT_DESTINO..."
log_w "Gerando script motor autônomo..."

cat << EOF > "$SCRIPT_DESTINO"
#!/bin/bash
# ==========================================
# SCRIPT GERADO AUTOMATICAMENTE PELO WIZARD V18
# ==========================================
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
log_msg "INICIANDO MIGRAÇÃO AUTÔNOMA V18 (Modo $MODO_IMPORT)"
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
    cat << 'INNER_EOF' > "$TMP_DIR/pos_import_esxi.sh"
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
INNER_EOF
    chmod +x "$TMP_DIR/pos_import_esxi.sh"
    genisoimage -quiet -J -R -V "POS_INSTALL" -o "$ISO_SCRIPT_PATH" "$TMP_DIR"
    rm -rf "$TMP_DIR"
fi

declare -A MAPA_VMS
if [ "$MODO_IMPORT" == "1" ]; then
    mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")
elif [ "$MODO_IMPORT" == "2" ]; then
    mkdir -p /mnt/esxi_sshfs
    sshfs "$ESXI_USER@$ESXI_HOST:/vmfs/volumes" /mnt/esxi_sshfs -o StrictHostKeyChecking=no,allow_other,IdentityFile=~/.ssh/id_rsa
    mapfile -t VMS_BRUTAS < <(find /mnt/esxi_sshfs/$DS_NOME -maxdepth 2 -name "*.vmx")
elif [ "$MODO_IMPORT" == "3" ]; then
    mapfile -t VMS_BRUTAS < <(find "$USB_PATH" -maxdepth 2 -name "*.vmx")
fi

for i in "${!VMS_BRUTAS[@]}"; do MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"; done
if [ ${#MAPA_VMS[@]} -eq 0 ]; then log_msg "[x] Nenhuma VM encontrada. Abortando."; exit 1; fi

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
        log_msg "    [Pre-Flight] Buscando ID da VM no ESXi de origem..."
        ESXI_VMID=$(ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/getallvms" | grep "$ARQ_VMX" | awk '{print $1}' | head -n 1)
        if [ -n "$ESXI_VMID" ]; then
            log_msg "    [Pre-Flight] Checando estado de energia..."
            if ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.getstate $ESXI_VMID" | grep -qi 'Powered on'; then
                log_msg "    [Pre-Flight] Desligando VM no ESXi..."
                ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.off $ESXI_VMID" > /dev/null
                sleep 5
            fi
            
            # TRUQUE DA CONSOLIDAÇÃO FORÇADA (Dummy Snapshot -> RemoveAll)
            log_msg "    [Pre-Flight] Forcando consolidacao de discos orfaos..."
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/snapshot.create $ESXI_VMID 'Migracao-Proxmox' 'Forced-Consolidation' 0 0" > /dev/null
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/snapshot.removeall $ESXI_VMID" > /dev/null
            
            log_msg "    [Pre-Flight] Aguardando conclusao das tarefas em background no VMware..."
            while ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/get.tasklist $ESXI_VMID" | grep -q "vim.Task"; do 
                sleep 5
            done
            log_msg "    [Pre-Flight] Pre-Flight concluido com sucesso!"
        else
            log_msg "    [Pre-Flight] AVISO: VM nao encontrada via API do VMware. Pulando validacao de discos."
        fi
    fi

    if [ "$MODO_IMPORT" == "1" ]; then
        log_msg "    -> Disparando o importador nativo do Proxmox (Isso pode demorar a exibir progresso se o disco for grande)..."
        qm import $CURRENT_VMID "$caminho_vm" --storage "$STORAGE_DESTINO" > >(processar_saida) 2>&1 &
        wait $!
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 0 ]; then
            log_msg "    -> Aplicando mutacoes de hardware VirtIO..."
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
        log_msg "    -> VMX Parser Analítico. Recriando esqueleto da VM..."
        MEM=$(grep -iE '^memSize' "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
        CORES=$(grep -iE '^numvcpus' "$caminho_vm" | cut -d'"' -f2 | tr -d '\r')
        qm create $CURRENT_VMID --name "$NOME_LIMPO" --memory "${MEM:-2048}" --sockets 1 --cores "${CORES:-1}" --cpu host --scsihw virtio-scsi-single --vga virtio --agent 1 --onboot 1
        
        EXIT_CODE=0
        while read -r line; do
            dev=$(echo "$line" | cut -d'.' -f1)
            bus=$(echo "$dev" | cut -d':' -f1)
            vmdk_name=$(echo "$line" | cut -d'"' -f2 | tr -d '\r')
            vmdk_path="$(dirname "$caminho_vm")/$vmdk_name"
            
            log_msg "    -> Injetando disco $vmdk_name no barramento $bus (Aguarde o processamento)..."
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
            log_msg "    -> Acoplando ISO do script de Post-Install..."
            for drive in $(qm config $CURRENT_VMID | grep 'media=cdrom' | awk -F: '{print $1}'); do qm set $CURRENT_VMID --delete "$drive"; done
            qm set $CURRENT_VMID --ide2 local:iso/pos_install_esxi.iso,media=cdrom
        fi
        if [ "$OPT_RELIGAR" == "1" ]; then 
            log_msg "    -> Relocando Power ON na VM original do ESXi..."
            ssh -o StrictHostKeyChecking=no "$ESXI_USER@$ESXI_HOST" "vim-cmd vmsvc/power.on $ESXI_VMID" > /dev/null
        fi
        if [ "$OPT_START" == "1" ]; then 
            log_msg "    [*] Inicializando VM no Proxmox..."
            qm start $CURRENT_VMID
        fi
        log_msg "[v] VM $NOME_LIMPO concluída com sucesso!"
    else
        log_msg "[x] ERRO: Falha crítica na importação da VM $NOME_LIMPO."
    fi
    sleep 2
done
if [ "$MODO_IMPORT" == "2" ]; then umount -f /mnt/esxi_sshfs &>/dev/null; fi
log_msg "Lote finalizado com sucesso!"
EOF

chmod +x "$SCRIPT_DESTINO"
echo "[v] Script autônomo gerado com sucesso."
log_w "Script autônomo gravado em $SCRIPT_DESTINO"

# --- 5. AGENDAMENTO NO CRONTAB ---
echo -e "\n=== AGENDAMENTO CRON ==="
read -p "Deseja agendar a execução agora? [1] Sim / [0] Não: " OPT_CRON
if [ "$OPT_CRON" == "1" ]; then
    read -p "Hora de execução (0-23): " CRON_H
    read -p "Minuto de execução (0-59): " CRON_M
    
    crontab -l 2>/dev/null | grep -v "$SCRIPT_DESTINO" > /tmp/crontmp
    echo "$CRON_M $CRON_H * * * $SCRIPT_DESTINO > /dev/null 2>&1" >> /tmp/crontmp
    crontab /tmp/crontmp
    rm /tmp/crontmp
    
    echo "[v] Agendamento criado! A migração rodará às $CRON_H:$CRON_M."
    echo "[*] Para monitorar os logs na hora agendada: tail -f /var/log/migracao_esxi_proxmox.log"
    log_w "Agendamento confirmado no Crontab para as $CRON_H:$CRON_M"
else
    echo "[*] Agendamento pulado. Para rodar manualmente depois, digite: $SCRIPT_DESTINO"
    log_w "Agendamento ignorado pelo usuario."
fi