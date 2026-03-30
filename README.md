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
* **Post-Install Injection:** Gera e acopla um CD-ROM (ISO) dinâmico com um script Bash que reconfigura o `/etc/network/interfaces` do Debian/Ubuntu e instala o `qemu-guest-agent` sem depender de rede prévia.

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