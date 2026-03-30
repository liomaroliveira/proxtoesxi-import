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