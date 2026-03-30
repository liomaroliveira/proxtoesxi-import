#!/bin/bash

# ==========================================
# Script de Importação em Lote ESXi -> Proxmox v2
# ==========================================

LOG_FILE="/var/log/importacao_esxi_$(date +%Y%m%d_%H%M).log"

# Variáveis globais para o Trap (Ctrl+C)
CURRENT_VMID=""
IMPORT_PID=""

echo "======================================================" | tee -a $LOG_FILE
echo "Iniciando sistema de importação." | tee -a $LOG_FILE
echo "Log em tempo real salvo em: $LOG_FILE" | tee -a $LOG_FILE
echo "======================================================" | tee -a $LOG_FILE

# 1. Armadilha de Interrupção (Trap)
cleanup() {
    echo -e "\n[!] AVISO: INTERRUPÇÃO DETECTADA (Ctrl+C)!" | tee -a $LOG_FILE
    if [ -n "$IMPORT_PID" ]; then
        echo "[*] Matando o processo de importação (PID $IMPORT_PID)..." | tee -a $LOG_FILE
        kill -9 $IMPORT_PID 2>/dev/null
    fi
    if [ -n "$CURRENT_VMID" ]; then
        echo "[*] Removendo VM incompleta ($CURRENT_VMID) do Proxmox..." | tee -a $LOG_FILE
        qm destroy $CURRENT_VMID --purge 1 >> $LOG_FILE 2>&1
        echo "[v] VM $CURRENT_VMID deletada com sucesso. Sem lixo no ZFS." | tee -a $LOG_FILE
    fi
    echo "[!] Script abortado com segurança." | tee -a $LOG_FILE
    exit 1
}
trap cleanup SIGINT SIGTERM

# 2. Seleção Numérica do Storage de Origem (Somente ESXi)
echo -e "\nBuscando storages do tipo ESXi conectados ao Proxmox..."
# awk filtra pela segunda coluna (Type) igual a 'esxi'
mapfile -t ESXI_STORAGES < <(pvesm status | awk 'NR>1 && $2=="esxi" {print $1}')

if [ ${#ESXI_STORAGES[@]} -eq 0 ]; then
    echo "Erro: Nenhum storage do tipo 'esxi' encontrado no Datacenter." | tee -a $LOG_FILE
    exit 1
fi

echo -e "\nArmazenamentos de Origem (ESXi) disponíveis:"
for i in "${!ESXI_STORAGES[@]}"; do
    echo "[$((i+1))] ${ESXI_STORAGES[$i]}"
done
read -p "Digite o NÚMERO do storage de origem: " NUM_ORIGEM

STORAGE_ORIGEM="${ESXI_STORAGES[$((NUM_ORIGEM-1))]}"
if [ -z "$STORAGE_ORIGEM" ]; then
    echo "Opção inválida. Abortando."
    exit 1
fi

# 3. Listagem de VMs (Sem filtros de exclusão, lista tudo)
echo -e "\nLendo catálogo de VMs em $STORAGE_ORIGEM..."
# Extrai apenas os arquivos .vmx corretos e guarda em um array
mapfile -t VMS_BRUTAS < <(pvesm list "$STORAGE_ORIGEM" | awk 'NR>1 {print $1}' | grep "\.vmx$")

declare -A MAPA_VMS
for i in "${!VMS_BRUTAS[@]}"; do
    MAPA_VMS[$((i+1))]="${VMS_BRUTAS[$i]}"
done

# 4. Seleção Numérica do Storage de Destino (Com Espaço Total e Livre)
echo -e "\nArmazenamentos de Destino disponíveis (Proxmox):"
# Captura Nome ($1), Tipo ($2), Total ($4) e Disponível ($6)
mapfile -t DEST_STORAGES < <(pvesm status | awk 'NR>1 && $4>0 {print $1, $2, $4, $6}')

declare -A MAPA_DESTINO
idx=1
for info in "${DEST_STORAGES[@]}"; do
    # Divide a string em variáveis
    read -r nome_st tipo_st total_kb livre_kb <<< "$info"
    # Converte KB para GB para exibição
    total_gb=$(awk "BEGIN {printf \"%.2f\", $total_kb / 1048576}")
    livre_gb=$(awk "BEGIN {printf \"%.2f\", $livre_kb / 1048576}")
    
    echo "[$idx] $nome_st | Tipo: $tipo_st | Total: $total_gb GB | Livre: $livre_gb GB"
    MAPA_DESTINO[$idx]=$nome_st
    ((idx++))
done

echo ""
read -p "Digite o NÚMERO do storage de destino: " NUM_DESTINO
STORAGE_DESTINO="${MAPA_DESTINO[$NUM_DESTINO]}"
if [ -z "$STORAGE_DESTINO" ]; then
    echo "Opção inválida. Abortando."
    exit 1
fi

# 5. Seleção de VMs na Ordem Exata
echo -e "\n======================================================"
echo "VMs disponíveis para importação em $STORAGE_ORIGEM:"
for i in $(seq 1 ${#VMS_BRUTAS[@]}); do
    # Mostra apenas o caminho a partir do nome da VM para ficar mais limpo na tela
    NOME_EXIBICAO=$(echo "${MAPA_VMS[$i]}" | awk -F'/' '{print $(NF-1)"/"$NF}')
    echo "[$i] $NOME_EXIBICAO"
done
echo "======================================================"

echo -e "\nDigite os NÚMEROS das VMs que deseja importar, separados por espaço (ex: 5 1 3)."
echo "As VMs serão importadas EXATAMENTE na ordem que você digitar."
echo "Ou digite 'TODAS' para importar toda a lista na ordem numérica apresentada."
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

# 6. Execução Sequencial das Importações
echo -e "\n======================================================" | tee -a $LOG_FILE
echo "Iniciando fila de importações..." | tee -a $LOG_FILE

for num_vm in "${VMS_PARA_IMPORTAR[@]}"; do
    caminho_vm="${MAPA_VMS[$num_vm]}"
    
    # Consulta o próximo ID livre do Proxmox APENAS na hora de criar a VM
    CURRENT_VMID=$(pvesh get /cluster/nextid)
    nome_arquivo_vm=$(basename "$caminho_vm")
    
    echo "------------------------------------------------------" | tee -a $LOG_FILE
    echo "[$(date +%H:%M:%S)] Importando: [$num_vm] $nome_arquivo_vm -> Novo ID: $CURRENT_VMID no pool $STORAGE_DESTINO" | tee -a $LOG_FILE
    
    # Executa a importação enviando tudo para o log e liberando o terminal para o wait e trap
    qm import $CURRENT_VMID "$caminho_vm" --storage "$STORAGE_DESTINO" 2>&1 | tee -a $LOG_FILE &
    IMPORT_PID=$!
    
    # Trava o script aguardando o fim da importação atual
    wait $IMPORT_PID
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "[v] Sucesso: VM $CURRENT_VMID importada perfeitamente." | tee -a $LOG_FILE
    else
        echo "[x] ERRO na importação da VM $CURRENT_VMID (Código: $EXIT_CODE). Verifique o log." | tee -a $LOG_FILE
    fi
    
    # Limpa as variáveis para a próxima iteração não ter resíduos em caso de Ctrl+C no intervalo
    CURRENT_VMID=""
    IMPORT_PID=""
    sleep 2
done

echo "======================================================" | tee -a $LOG_FILE
echo "Processo finalizado! Log preservado em: $LOG_FILE" | tee -a $LOG_FILE