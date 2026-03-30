#!/bin/bash

# ==========================================
# Script de Importação em Lote ESXi -> Proxmox V3
# ==========================================

# Log fixo para ser incremental ao longo dos dias
LOG_FILE="/var/log/migracao_esxi_proxmox.log"

CURRENT_VMID=""
IMPORT_PID=""

# Função para padronizar as mensagens com Timestamp no log e na tela
log_msg() {
    local ts="[$(date +'%Y-%m-%d %H:%M:%S')]"
    echo -e "$ts $1" | tee -a "$LOG_FILE"
}

log_msg "======================================================"
log_msg "Iniciando sistema de importação V3."
log_msg "Log principal: $LOG_FILE"
log_msg "======================================================"

# 1. Armadilha de Interrupção (Trap)
cleanup() {
    log_msg "\n[!] AVISO: INTERRUPÇÃO DETECTADA (Ctrl+C)!"
    if [ -n "$IMPORT_PID" ]; then
        log_msg "[*] Matando o processo de importação (PID $IMPORT_PID)..."
        kill -9 $IMPORT_PID 2>/dev/null
    fi
    if [ -n "$CURRENT_VMID" ]; then
        log_msg "[*] Removendo VM incompleta ($CURRENT_VMID) do Proxmox..."
        qm destroy $CURRENT_VMID --purge 1 >> "$LOG_FILE" 2>&1
        log_msg "[v] VM $CURRENT_VMID deletada com sucesso. Sem lixo no pool."
    fi
    log_msg "[!] Script abortado com segurança."
    exit 1
}
trap cleanup SIGINT SIGTERM

# Função inteligente para processar a saída do qm import
# Sobrescreve a tela com \r e limpa rastros com \033[K, além de poupar o log
processar_saida() {
    local prev_was_trans=0
    local last_trans=""
    
    while IFS= read -r line; do
        local ts="[$(date +'%Y-%m-%d %H:%M:%S')]"
        
        if [[ "$line" == transferred* ]]; then
            # Imprime na tela com Carriage Return (\r) e apaga o resto da linha (\033[K)
            echo -en "\r$ts $line\033[K"
            last_trans="$line"
            prev_was_trans=1
        else
            # Se a linha anterior era progresso, quebra a linha na tela e salva o final no log
            if [[ $prev_was_trans -eq 1 ]]; then
                echo "" 
                echo "$ts $last_trans" >> "$LOG_FILE"
                prev_was_trans=0
            fi
            # Exibe a nova linha normal
            echo "$ts $line" | tee -a "$LOG_FILE"
        fi
    done
    
    # Garantia de registro caso o comando feche abruptamente
    if [[ $prev_was_trans -eq 1 ]]; then
        echo ""
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $last_trans" >> "$LOG_FILE"
    fi
}

# 2. Seleção Numérica do Storage de Origem
echo -e "\nBuscando storages do tipo ESXi..."
mapfile -t ESXI_STORAGES < <(pvesm status | awk 'NR>1 && $2=="esxi" {print $1}')

if [ ${#ESXI_STORAGES[@]} -eq 0 ]; then
    log_msg "Erro: Nenhum storage ESXi encontrado."
    exit 1
fi

echo -e "\nArmazenamentos de Origem (ESXi):"
for i in "${!ESXI_STORAGES[@]}"; do
    echo "[$((i+1))] ${ESXI_STORAGES[$i]}"
done
read -p "Digite o NÚMERO da origem: " NUM_ORIGEM
STORAGE_ORIGEM="${ESXI_STORAGES[$((NUM_ORIGEM-1))]}"

if [ -z "$STORAGE_ORIGEM" ]; then
    log_msg "Opção inválida. Abortando."
    exit 1
fi

# 3. Listagem de VMs 
echo -e "\nLendo catálogo em $STORAGE_ORIGEM..."
mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")

declare -A MAPA_VMS
for i in "${!VMS_BRUTAS[@]}"; do
    MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"
done

# 4. Seleção Numérica do Destino
echo -e "\nArmazenamentos de Destino disponíveis:"
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

echo ""
read -p "Digite o NÚMERO do destino: " NUM_DESTINO
STORAGE_DESTINO="${MAPA_DESTINO[$NUM_DESTINO]}"

if [ -z "$STORAGE_DESTINO" ]; then
    log_msg "Opção inválida. Abortando."
    exit 1
fi

# 5. Seleção de VMs Formatada
echo -e "\n======================================================"
echo "VMs em $STORAGE_ORIGEM:"
for i in $(seq 1 ${#VMS_BRUTAS[@]}); do
    # Mágica do awk que você testou aplicada ao menu
    NOME_EXIBICAO=$(echo "${MAPA_VMS[$i]}" | awk -F'/' '{print $2 " / " $NF}')
    echo "[$i] $NOME_EXIBICAO"
done
echo "======================================================"

echo -e "\nDigite os NÚMEROS separados por espaço (ex: 5 1 3)."
echo "Ou 'TODAS' para importar a lista completa."
read -p "Sua escolha: " ESCOLHA_USER

VMS_PARA_IMPORTAR=()
if [[ "${ESCOLHA_USER^^}" == "TODAS" ]]; then
    for i in $(seq 1 ${#VMS_BRUTAS[@]}); do
        VMS_PARA_IMPORTAR+=("$i")
    done
else
    for num in $ESCOLHA_USER; do
        if [ -n "${MAPA_VMS[$num]}" ]; then
            VMS_PARA_IMPORTAR+=("$num")
        fi
    done
fi

# 6. Loop de Importação Blindado
log_msg "\n======================================================"
log_msg "Iniciando fila de importações..."

for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
    caminho_vm="${MAPA_VMS[$num_vm]}"
    CURRENT_VMID=$(pvesh get /cluster/nextid)
    
    # Nome no formato limpo apenas para a exibição de cabeçalho
    nome_limpo=$(echo "$caminho_vm" | awk -F'/' '{print $2 " / " $NF}')
    
    log_msg "------------------------------------------------------"
    log_msg "Importando: [$num_vm] $nome_limpo -> Novo ID: $CURRENT_VMID no pool $STORAGE_DESTINO"
    
    # Process substitution: Envia o comando para o background mas manda a saída pro filtro inteligente
    qm import $CURRENT_VMID "$caminho_vm" --storage "$STORAGE_DESTINO" > >(processar_saida) 2>&1 &
    IMPORT_PID=$!
    
    wait $IMPORT_PID
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        log_msg "[v] Sucesso: VM $CURRENT_VMID concluída."
    else
        log_msg "[x] ERRO na importação da VM $CURRENT_VMID (Código: $EXIT_CODE)."
    fi
    
    CURRENT_VMID=""
    IMPORT_PID=""
    sleep 2
done

log_msg "======================================================"
log_msg "Lote finalizado! Log incremental salvo."