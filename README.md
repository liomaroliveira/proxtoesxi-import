# 🚀 ESXi to Proxmox Migration Toolkit (Autonomous Edition V15)

Um motor de automação avançado e "Zero-Touch" para migração em massa de máquinas virtuais do VMware ESXi para o Proxmox VE. Desenhado para operar via Cron, o script lida com múltiplas topologias de origem, aplica engenharia reversa em arquivos `.vmx` corrompidos e realiza mutações cirúrgicas de hardware para otimização nativa no Proxmox.

## ⚙️ Principais Funcionalidades

* **Autonomia Total (Cron-Ready):** Execução baseada em variáveis de pré-configuração, sem necessidade de intervenção humana (sem prompts de `read`).
* **3 Vias de Importação:**
    * `[1] Storage Plugin`: Via API nativa do Proxmox (Ideal para ambientes saudáveis).
    * `[2] SSHFS Remoto`: Túnel direto ignorando a API nativa (Ideal para contornar falhas de integração).
    * `[3] USB / Local`: Modo offline lendo arquivos `.vmdk` e `.vmx` diretamente de um disco externo.
* **Fábrica de Mutação de Hardware:** Converte automaticamente discos para `VirtIO-SCSI`, placas de rede para `VirtIO` (preservando o MAC Address original) e CPU para `Host`.
* **Injeção Dinâmica de VLANs:** Suporte a mapeamento de múltiplas placas de rede (Multi-NIC) com inserção de tags VLAN na exata ordem do hardware.
* **Pre-Flight Check (ESXi):** Desliga VMs ativas e consolida snapshots automaticamente via SSH antes de iniciar o I/O de disco.
* **Post-Install Injection:** Gera e acopla um CD-ROM (ISO) dinâmico com um script Bash que reconfigura o `/etc/network/interfaces` do Debian/Ubuntu e instala o `qemu-guest-agent` sem depender de rede prévia. "mount /dev/cdrom /mnt", "bash /mnt/pos_import_esxi.sh".

---

## 📦 Dependências

O script faz a checagem e instalação automática das ferramentas necessárias no Proxmox no início de sua execução:
* `genisoimage` (Para criação da ISO de injeção)
* `sshfs` (Para montagem de datastores remotos)
* `sshpass` (Fallback para operações de legado)
* `jq` (Manipulação de payloads)

---

## 🔑 Configuração de Autenticação Sem Senha (SSH Keys)

Para que o script opere de forma 100% autônoma no agendador de tarefas (Cron) executando comandos remotos de desligamento e consolidação no ESXi, é obrigatório injetar a chave SSH do Proxmox no host VMware.

Execute no terminal do **Proxmox**:

1. **Gere a chave criptográfica** (Se já existir, pule este passo. Pressione `Enter` para todas as perguntas):
   ```bash
   ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

1. **Injete a chave pública no ESXi** (Substitua `IP_DO_ESXI` pelo IP real do VMware. A senha será solicitada apenas nesta vez):
    
    ```bash
    cat ~/.ssh/id_rsa.pub | ssh root@IP_DO_ESXI 'cat >> /etc/ssh/keys-root/authorized_keys'
    ```
    
2. **Valide a relação de confiança** (Não deve solicitar senha):
    
    ```bash
    ssh root@IP_DO_ESXI "echo SUCESSO"
    ```
    

---

## 🧠 Configuração do Motor (O Cérebro do Script)

Antes de executar, edite as variáveis no topo do arquivo `proxtoesxi-import.sh`. Este é o painel de controle que dita o comportamento do script:

```bash
MODO_IMPORT="3"          # 1=Plugin, 2=SSHFS, 3=USB
STORAGE_DESTINO="zfs_raid10"

# Automações Booleanas (1 = Habilitado | 0 = Desabilitado)
OPT_INJECT="1"           # Injeta a ISO com script de rede
OPT_START="1"            # Liga a VM no Proxmox no final
OPT_PREFLIGHT="0"        # Força PowerOff e Remove Snapshots na Origem
OPT_RELIGAR="0"          # Religa a VM no ESXi original se sucesso
```

### 📋 Mapeamento da Fila de VMs (`VMS_TARGET`)

A variável de array `VMS_TARGET` define o lote de execução. A sintaxe rigorosa é: `"nome_do_arquivo.vmx|vlan_nic1 vlan_nic2"`.

**Exemplos de uso:**

- Para uma VM sem VLAN: `"unifi.vmx|"`
- Para uma VM com duas placas de rede (VLAN 321 na net0 e 305 na net1): `"ten-grafana.vmx|321 305"`
- Para migrar um datastore ou diretório inteiro varrendo tudo sem VLAN: `VMS_TARGET=("TODAS")`

---

## 🚀 Execução e Agendamento

### Opção A: Execução Manual (Dry Run / Acompanhamento)

Ideal para validar a configuração das variáveis antes de agendar.

```
chmod +x proxtoesxi-import.sh
./proxtoesxi-import.sh
```

### Opção B: Operação Autônoma (Agendador Cron)

Para rodar massivamente durante a madrugada sem dependência de terminal aberto.

1. Abra o editor de tarefas do Proxmox:
    
    ```bash
    crontab -e
    ```
    
2. Adicione a linha abaixo no final do arquivo (Exemplo: execução programada para todos os dias às **02:00 AM**):
    
    ```bash
    0 2 * * * /caminho/absoluto/para/proxtoesxi-cron.sh > /dev/null 2>&1
    ```
    

---

## 📄 Logs e Auditoria

Toda a operação (desde o mapeamento até erros de I/O de disco) é gravada de forma incremental com *timestamps*. Para auditar a migração:

```bash
tail -f /var/log/migracao_esxi_proxmox.log
```

-------------------------------
# ⚙️ Proxmox VM Migrator - proxtoprox-import-cron-wizard.sh

Este repositório/script automatiza a migração de Máquinas Virtuais (VMs) entre nós Proxmox VE autônomos (fora de um cluster) utilizando transferência direta via SSH e pipes, eliminando a necessidade de armazenamento temporário no nó de origem.

## 🚀 Funcionalidades

* **Importação Direta via SSH (Pipe):** Utiliza `vzdump --stdout` na origem e `qmrestore -` no destino. O tráfego não toca no disco da origem.
* **Monitoramento de Tráfego:** Implementa `pv` (Pipe Viewer) para monitoramento em tempo real do tráfego na rede durante a execução interativa.
* **Resolução Automática de Dependências:** Verifica e instala silenciosamente dependências ausentes (`sshpass`, `pv`, `rsync`) no nó de origem.
* **Agendamento Autônomo (Cron):** Wizard interativo para criação de rotinas no diretório `/etc/cron.d/`.
* **Autenticação Key-Based Automática:** Gera e exporta chaves ED25519 para o nó de destino, viabilizando a execução autônoma via cron sem senhas em texto plano.
* **Rollback Remoto Resiliente:** Intercepta sinais de erro (`SIGINT`, `SIGTERM`, `ERR`) e limpa arquivos residuais locais e destrói VMs incompletas no nó de destino.
* **Isolamento de Logs:** Separa rigorosamente os logs de execuções interativas e execuções via Cron.

## 📋 Pré-requisitos

O script deve ser executado com privilégios de **root** no nó Proxmox de **origem**. 

As seguintes ferramentas serão instaladas automaticamente se ausentes:
* `sshpass`: Para injeção da senha no primeiro contato interativo.
* `pv`: Para métricas de fluxo do pipe.
* `rsync`: (Planejado para rotinas de SCP com progresso iterativo).

*Nota: O nó de destino precisa ter o serviço SSH rodando na porta padrão (22) e permitir login de root (comportamento padrão do Proxmox).*

## 💻 Uso

1.  Faça o download do script no servidor de origem.
2.  Conceda permissão de execução:
    ```bash
    chmod +x migrate_pve.sh
    ```
3.  Execute o script:
    ```bash
    ./migrate_pve.sh
    ```
4.  O assistente solicitará o IP de destino, usuário (`root`) e senha. Em seguida, o menu principal será exibido.

## 📂 Estrutura de Logs e Agendamentos

* **Logs Interativos:** `/var/log/proxmox_migration_YYYYMMDD_HHMMSS.log`
* **Logs de Cron:** `/var/log/migrate_vmid_<ID>_to_<IP>.log`
* **Arquivos de Cron:** `/etc/cron.d/migrate_vmid_<ID>_to_<IP>`
* **Scripts Autônomos (Gerados pelo Cron):** `/usr/local/bin/migrate_vmid_<ID>_to_<IP>.sh`

## ⚠️ Limitações e Comportamento Crítico

* **Downtime Inerente:** Este script realiza backups em modo `snapshot`. A VM permanece online durante o processo, porém, quaisquer dados gravados na VM de origem após o início do processo de migração não estarão presentes na VM de destino. Será necessário um pequeno downtime manual para desligar a origem e ligar o destino após a conclusão.
* **Sensibilidade de Rede:** O método Pipe (vzdump -> ssh -> qmrestore) é extremamente sensível a oscilações de rede. Uma queda de milissegundos na conexão SSH pode abortar o processo (acionando o rollback).
* **Ausência de Parse Complexo:** O script assume que o storage de destino informado pelo usuário (ex: `local-lvm`, `zfs-pool`) realmente existe no nó remoto. A validação prévia remota não está implementada nesta versão.

## 🔄 Alternativas e Sugestões Arquiteturais

A depender da escala e topologia da infraestrutura, scripts Bash monolíticos tornam-se difíceis de manter. Para cenários de produção de médio e grande porte, as seguintes abordagens são tecnicamente superiores:

1.  **Proxmox Backup Server (PBS):**
    * **Por que:** Utiliza deduplicação na fonte, criptografia e validação de integridade.
    * **Fluxo:** O nó A faz backup (incremental) para o PBS. O nó B restaura a partir do PBS. O tráfego de rede é brutalmente reduzido.
2.  **Cluster Proxmox (pvecm):**
    * **Por que:** Se ambos os nós estiverem na mesma sub-rede física (latência < 2ms), agrupá-los em um cluster permite **Live Migration** nativo via interface web ou CLI, transferindo a RAM e o disco em tempo real sem interrupção de serviço.
3.  **Automação via Ansible:**
    * **Por que:** O Bash imperativo lida mal com estados e exceções complexas. O Ansible (com a coleção `community.general.proxmox`) utiliza a API REST do Proxmox para orquestrar a migração de forma declarativa e idempotente.
4.  **ZFS Send/Receive Remoto (Para Storages ZFS):**
    * **Por que:** Se ambos os nós usam ZFS, transferir os datasets em blocos via `zfs send` é substancialmente mais rápido e utiliza menos CPU do que empacotar tudo no formato `.vma` via `vzdump`.