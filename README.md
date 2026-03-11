# 🖥️ Mint Kiosk - Transforme seu Linux Mint em um Painel Digital

Este script transforma qualquer computador com Linux Mint em um **painel digital automático** - perfeito para murais de avisos, TV corporativa, displays de informações ou aplicações PWA.

✅ Testado no **Linux Mint 22.3**  
⚙️ Funciona em qualquer PC com Linux Mint

---

## 🚀 Instalação em UM COMANDO

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ctic-tub-ifsc/mint-kiosk/refs/heads/main/install_kiosk.sh)"
```

**O que vai acontecer:**
1. O script vai pedir a **URL do site** que você quer mostrar
2. Vai perguntar se quer **acesso remoto VNC** (opcional)
3. Faz tudo sozinho e reinicia o PC
4. Pronto! Na próxima inicialização já estará funcionando

---

## ✨ O que esse script faz por você (de forma simples)

### 📺 **1. Vira um painel automático**
- Abre o navegador em tela cheia (modo kiosk)
- Esconde o mouse quando parado
- Desliga protetor de tela e suspensão
- **Novo:** Se conectar uma TV via HDMI, ela já aparece espelhada automaticamente!

### 🧠 **2. Se cuida sozinho (monitoramento inteligente)**
- Fica de olho no navegador a cada 30 segundos
- Se perceber que travou, tenta dar um **F5** automático
- Se não resolver, reinicia o navegador
- Se mesmo assim não funcionar, recarrega tudo do zero

### 📸 **3. Tira "fotos" quando dá problema**
- Quando algo errado acontece, tira um **print da tela**
- Salva na pasta `/var/log/kiosk_screenshots/`
- Assim você pode ver **o que estava na tela na hora do erro**
- Guarda só os últimos 10 prints (não enche o disco)

### 📊 **4. Gera relatório completo no final**
- Mostra versão do sistema, kernel, ambiente gráfico
- Informa versão do Chromium instalado
- Diz se o SSH está ativo e qual IP usar
- Mostra se o VNC foi configurado

### 🔌 **5. Acesso remoto garantido**
- **SSH** ativado automático (porta 22)
- **VNC** opcional para controle remoto da tela
- Firewall liberado só para o necessário

---

## 📋 O que você precisa saber depois de instalado

### Comandos úteis para o dia a dia

```bash
# Ver se o serviço está rodando
sudo systemctl status kiosk.service

# Ver os logs em tempo real (o que está acontecendo)
sudo journalctl -u kiosk.service -f

# Ver o log principal do painel
tail -f /var/log/kiosk_monitor.log

# Se o navegador travar, force um F5 manual
sudo systemctl restart kiosk.service
```

### Scripts prontos na pasta do kiosk

O script cria alguns arquivos na pasta `/home/seu-usuario/kiosk/`:

```bash
# Diagnóstico rápido do sistema
~/kiosk/diagnostico.sh

# Emergência (se precisar reiniciar ou dar F5 manual)
~/kiosk/emergency.sh restart   # reinicia o navegador
~/kiosk/emergency.sh refresh   # dá um F5
~/kiosk/emergency.sh status    # mostra o que está rodando
~/kiosk/emergency.sh logs      # mostra os últimos logs
```

---

## 🖥️ Conectando uma TV (duplicação automática)

**Como funciona:**
1. Conecte a TV via HDMI
2. O sistema detecta automaticamente
3. Duplica a tela do monitor principal para a TV
4. Funciona tanto no boot quanto se conectar depois

**Não precisa fazer nada - já está configurado!**

---

## 🔧 Configurações que o script faz automaticamente

| O que | Como fica |
|------|-----------|
| **Login** | Automático (não pede senha) |
| **Tela** | Nunca bloqueia |
| **Suspensão** | Desligada (nunca hiberna) |
| **Mouse** | Some depois de 0.5s parado |
| **Chromium** | Instalado via Flatpak (sem depender do snap) |
| **Logs** | Salvos em `/var/log/kiosk_monitor.log` |
| **Prints de erro** | Salvos em `/var/log/kiosk_screenshots/` |

---

## 📁 Onde ficam os arquivos importantes

```
/var/log/kiosk_monitor.log           # Log principal (use: tail -f)
/var/log/kiosk_screenshots/           # Prints de quando deu erro
/home/seu-usuario/kiosk/              # Scripts do sistema
/etc/systemd/system/kiosk.service     # Serviço que roda no boot
```

---

## 🆘 Problemas comuns (e soluções rápidas)

### "O navegador fechou sozinho"
```bash
sudo systemctl restart kiosk.service
```

### "A tela está preta, mas o sistema parece rodar"
```bash
~/kiosk/emergency.sh restart
```

### "Quero ver o que aconteceu ontem"
```bash
grep "ERRO" /var/log/kiosk_monitor.log
```

### "Conectei uma TV mas não duplicou"
```bash
# O sistema já tenta fazer sozinho, mas pode esperar alguns segundos
# Se não funcionar, reinicie o serviço de display:
sudo systemctl restart display-config.service
```

---

## 📊 Relatório gerado no final da instalação

Ao terminar a instalação, o script mostra um relatório como este:

```
📌 SISTEMA OPERACIONAL
━━━━━━━━━━━━━━━━━━━━━━
Distribuição: Linux Mint 22.3
Kernel: 6.14.0-37-generic
Usuário: tubarao

🖥️  AMBIENTE GRÁFICO
━━━━━━━━━━━━━━━━━━━━━━
Login Automático: ✅ Configurado
Duplicação HDMI: ✅ Ativada

🌐 CHROMIUM
━━━━━━━━━━━━━━━━━━━━━━
Versão: 145.0.7632.159
URL: https://mural.exemplo.com

🔌 ACESSO REMOTO
━━━━━━━━━━━━━━━━━━━━━━
SSH: ✅ ssh tubarao@192.168.1.100
VNC: ✅ Porta 5900
```

---

## 📚 Quer se aprofundar?

Temos um guia completo de resolução de problemas:

👉 **[Guia de Resolução de Problemas](resolucao_de_problemas.md)**  

Lá você encontra:
- Análise detalhada de causas de erro
- Como interpretar os screenshots
- Configurações avançadas
- Recuperação de emergência

---

## 🎯 Resumo: o que você ganha com isso

✅ **Zero configuração manual** - roda sozinho  
✅ **Auto-recuperável** - se travar, tenta consertar  
✅ **Acesso remoto** - SSH e VNC prontos  
✅ **Diagnóstico fácil** - logs e prints de erro  
✅ **TV automática** - só conectar o HDMI  
✅ **Sem surpresas** - nunca desliga ou bloqueia a tela  

---

**CTIC - Campus Tubarão**  
Instituto Federal de Santa Catarina

**Dúvidas?** Abra uma issue no GitHub ou fale com a equipe!
```
