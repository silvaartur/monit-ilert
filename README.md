# monit-ilert

[![shellcheck](https://github.com/silvaartur/monit-ilert/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/silvaartur/monit-ilert/actions/workflows/shellcheck.yml)

Instalador que configura o [Monit](https://mmonit.com/monit/) integrado ao [ilert](https://www.ilert.com/) em um servidor Linux, com alertas que **abrem e fecham sozinhos**, limiares calculados a partir do hardware real da máquina e proteção contra tempestade de alertas em crash loop.

Não existe integração nativa Monit ↔ ilert no catálogo deles. Este script preenche essa lacuna usando a Events API.

## O que ele faz

1. Detecta a distro e instala as dependências (`monit`, `curl`)
2. Pede as credenciais do ilert e grava em `/etc/ilert.env` (modo 600)
3. Instala três scripts: envio de eventos, ping de heartbeat e despacho de resolves adiados
4. Escreve o `monitrc` base, preservando includes existentes
5. **Calcula os limiares a partir do host**: load em função do `nproc`, memória escalonada pela RAM total, disco derivado do tamanho de cada volume
6. Detecta os serviços instalados e pergunta quais monitorar
7. Detecta portas publicadas de containers Docker e permite escolher, renomear e adicionar serviços externos
8. Valida com `monit -t`, sobe o serviço e faz um teste ponta a ponta

## Instalação

O script é interativo, então baixe e execute — não use `curl | sudo bash` às cegas, você deve ler o que vai rodar como root na sua máquina:

```bash
cd ~                                 # precisa de um diretorio com permissao de escrita
curl -fsSL https://raw.githubusercontent.com/silvaartur/monit-ilert/main/install-monit-ilert.sh -o install-monit-ilert.sh
less install-monit-ilert.sh          # leia antes de executar
chmod +x install-monit-ilert.sh
sudo ./install-monit-ilert.sh
```

Se preferir o atalho, ele funciona porque as perguntas são lidas de `/dev/tty`:

```bash
curl -fsSL https://raw.githubusercontent.com/silvaartur/monit-ilert/main/install-monit-ilert.sh | sudo bash
```

### Antes de começar, no painel do ilert

**1. Alert source para os eventos.** Alert sources → Create → tipo **API**. Copie a *integration key* (`il1api...`). Uma só para toda a frota.

**2. Heartbeat.** São dois objetos distintos e é aqui que quase todo mundo tropeça:

- O **alert source** do tipo Heartbeat (`il1hb2...`) apenas roteia o alerta. **Essa chave não é pingável.**
- O **heartbeat monitor** (Alert sources → Heartbeat monitors → Create) é o que gera a URL de ping, no formato `https://beat.ilert.com/api/pings/<key>`.

Um alert source serve toda a frota; **cada servidor precisa do seu próprio monitor**. Um monitor mede silêncio, não origem: se dez hosts pingarem a mesma URL, ele fica saudável enquanto qualquer um estiver vivo e os outros nove podem morrer sem gerar alerta.

Intervalo sugerido: 15 minutos (o script pinga a cada 5, dando margem de 3x).

## Modo não-interativo

Para Ansible, cloud-init ou qualquer automação:

```bash
sudo ./install-monit-ilert.sh --yes \
  --key-file /run/secrets/ilert.key \
  --heartbeat-key "https://beat.ilert.com/api/pings/<key-do-monitor>" \
  --host web-prod-01 \
  --env prod \
  --services nginx,mariadb,php8.2-fpm \
  --ports "loja:8080:http,cache:6379:redis,erp:10.0.0.50:8080:http"
```

Prefira `--key-file` a `--key`: argumentos de linha de comando aparecem em `ps` e no history do shell.

### Flags

| Flag | Efeito |
|---|---|
| `--yes`, `-y` | Não pergunta nada; usa defaults |
| `--key CHAVE` | Integration key do alert source |
| `--key-file ARQ` | Lê a key de um arquivo (não vaza em `ps`) |
| `--heartbeat-key VALOR` | Key **ou** URL completa do heartbeat monitor |
| `--beat-url URL` | Base do ping, sem a chave |
| `--host NOME` | Nome do host nos alertas (default: `hostname`) |
| `--env AMBIENTE` | Vai no label `env` (default: `prod`) |
| `--services LISTA` | Serviços a monitorar, separados por vírgula |
| `--ports LISTA` | Serviços TCP (veja formato abaixo) |
| `--gateway IP` | Host do check ICMP interno |
| `--auto-restart MODO` | `safe` (default), `all` ou `none` — veja abaixo |
| `--warn-priority P` | `LOW` (default) ou `HIGH` para warnings de recurso |
| `--swap-warn N` | Limiar de warning de swap em % (default 10) |
| `--swap-crit N` | Limiar de critical de swap em % (default 30) |
| `--ping-target IP` | Alvo externo de ICMP e DNS (default `1.1.1.1`) |
| `--connectivity MODO` | `auto` (default), `icmp`, `tcp` ou `none` |
| `--resolve-name NOME` | Nome usado no teste de resolução (default `google.com`) |
| `--swap-warn N` | % de swap para warning (default 10) |
| `--swap-crit N` | % de swap para critical (default 30) |
| `--no-heartbeat` | Não configura heartbeat |
| `--dry-run` | Mostra o que faria, sem escrever nada |
| `--uninstall` | Remove o que o instalador criou |

Também aceita `ILERT_KEY`, `ILERT_HEARTBEAT_URL`, `ILERT_HOST` e `ILERT_ENV` como variáveis de ambiente.

## Atualização

O script é idempotente e **preserva o `/etc/ilert.env`**, inclusive ajustes manuais como a URL do heartbeat. Arquivos cujo conteúdo não mudou não são reescritos.

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/silvaartur/monit-ilert/main/install-monit-ilert.sh -o install-monit-ilert.sh
chmod +x install-monit-ilert.sh
sudo ./install-monit-ilert.sh --host $(hostname)
```

**Não desinstale antes de atualizar.** Reexecutar é mais seguro: o Monit continua rodando durante o processo (no fim é `reload`, não `stop`+`start`), os arquivos substituídos ganham backup em `/var/backups/monit-ilert/`, e se o `monit -t` falhar o script **restaura tudo automaticamente** antes de sair.

Depois de atualizar, confira:

```bash
sudo grep ILERT_HEARTBEAT_URL /etc/ilert.env
sudo /usr/local/bin/ilert-beat.sh; echo "exit=$?"
sudo monit status
```

## Serviços detectados

| Serviço | Testes | Restart automático |
|---|---|---|
| nginx | PID, HTTP :80, CPU | não |
| apache2 / httpd | PID, HTTP :80, children | não |
| mariadb / mysql | PID, protocolo mysql :3306, memória | **não, deliberado** |
| postgresql | PID, protocolo pgsql :5432, memória | **não, deliberado** |
| redis / valkey | PID, protocolo redis :6379, socket, memória, CPU | **não, deliberado** |
| docker | PID, unixsocket | **não, deliberado** |
| php\*-fpm | PID, unixsocket, children, memória total | não |

A versão do PHP-FPM é detectada sozinha, então 7.x, 8.x e futuras funcionam sem alteração.

### Auto-restart

Por padrão (`--auto-restart safe`), nginx, apache2, php-fpm e Redis se reerguem sozinhos: o Monit alerta em 2 ciclos e tenta `restart` em 3. **Se o serviço não estabilizar após 3 restarts em 20 ciclos, o Monit desiste**, suspende o check e escala SEV1 pelo `ilert-giveup.sh` — reiniciar em loop mascara a causa, queima I/O e pode corromper estado.

Para voltar a monitorar depois de resolver:

```bash
sudo monit monitor <serviço>
```

O alerta `restartloop` **não fecha sozinho** — o check estava suspenso, então não houve recuperação para o Monit detectar. Resolva no painel do ilert ao religar, ou deixe o `auto_resolution_timeout` do alert source cuidar disso.

Se a unit do serviço já tem `Restart=on-failure` no systemd, você terá duas camadas tentando reerguer a mesma coisa. Verifique com `systemctl show <serviço> -p Restart` e, se já houver política lá, prefira `--auto-restart none` para esse serviço.

`--auto-restart all` inclui bancos e Docker; `none` desliga e só alerta.

Bancos e Docker ficam fora do modo `safe` de propósito: reiniciar um banco no meio de uma corrupção piora o quadro, reiniciar `dockerd` derruba toda a stack, e reiniciar Redis com persistência pode descartar escritas ainda não gravadas. O script alerta; a decisão é humana.

Além dos serviços, sempre são criados checks de sistema (load, CPU system/iowait, memória, swap), de cada filesystem real, ICMP para o gateway, ICMP e DNS para um alvo externo, e o heartbeat.

O instalador **testa a rede antes de gerar o check**. Se o ICMP não responder — comum em EC2, GCP e redes corporativas, onde o firewall bloqueia ping mas libera HTTPS — ele gera um teste de TCP 443 no lugar. Isso mede o caminho que a aplicação realmente usa e evita um alerta permanente de "sem internet" num host saudável. O check de gateway só entra se o gateway responder; em nuvem, o roteador virtual costuma ignorar ICMP e o teste não teria valor diagnóstico.

O alvo externo é sempre um **IP**, nunca um nome como `google.com`: pingar um nome junta duas falhas distintas — rede fora do ar e DNS quebrado — no mesmo alerta.

A resolução de nomes tem dois checks separados, que respondem a perguntas diferentes:

- **`dns`** consulta o servidor externo na porta 53 — prova que o resolver remoto está de pé.
- **`resolucao`** pinga o nome configurado (`google.com` por padrão). Como o check `internet` usa IP, uma falha só aqui isola a resolução de nomes.
- **`dns-resolver`** roda `getent hosts` e valida o resolver **deste host**: `/etc/resolv.conf`, `systemd-resolved`, `nsswitch`. É o caminho que a aplicação usa de verdade, e o único que detecta um resolver local quebrado.

## Portas TCP

Formato de cada item em `--ports`:

```
nome:porta                     # host 127.0.0.1, TCP puro
nome:host:porta
nome:porta:protocolo
nome:host:porta:protocolo
```

No modo interativo, o script lista as portas publicadas dos containers e oferece **todas**, **nenhuma** ou **escolher uma a uma** — nesse último caso você define o nome que vai aparecer no alerta e o protocolo. Depois disso, permite adicionar serviços em outros hosts.

Protocolos suportados pelo Monit: `http`, `https`, `mysql`, `pgsql`, `redis`, `mongodb`, `smtp`, `imap`, `ssh`, `dns`, `ldap`, `amqp`, `memcache`, entre outros. O script sugere um a partir da porta.

**Use protocolo sempre que possível.** TCP puro só prova que algo aceitou o socket — um container com a aplicação travada mas o proxy interno de pé passaria no teste. Com protocolo, o Monit conversa de verdade com o serviço.

## Arquivos criados

```
/usr/local/bin/ilert.sh          700  envia eventos ao ilert
/usr/local/bin/ilert-beat.sh     700  ping do heartbeat
/usr/local/bin/ilert-flush.sh    700  despacha resolves adiados
/etc/ilert.env                   600  ÚNICO arquivo com segredo
/etc/monit/monitrc               700
/etc/monit/conf.d/00-system.conf      load, cpu, memória, swap
/etc/monit/conf.d/01-filesystem.conf  disco e inodes
/etc/monit/conf.d/02-network.conf     ICMP
/etc/monit/conf.d/03-heartbeat.conf
/etc/monit/conf.d/04-flush.conf
/etc/monit/conf.d/10-services.conf
/etc/monit/conf.d/15-ports.conf
/var/lib/ilert/pending/               marcadores de resolve adiado
/var/backups/monit-ilert/             backups dos arquivos substituídos
```

Caminhos variam em RHEL (`/etc/monitrc`, `/etc/monit.d/`).

## Convivência com checks existentes

O instalador preserva o que já existe (`conf-enabled`, arquivos de terceiros em `conf.d`) e detecta os nomes de check já usados. Como o Monit exige nomes únicos em toda a configuração, uma colisão abortaria a validação — nesses casos ele sufixa o **seu** check com `-ilert` e avisa. Você fica com os dois e decide qual remover.

Se o check antigo não alerta para lugar nenhum, remova-o: dois checks no mesmo processo desperdiçam ciclo e confundem o diagnóstico.

## Customização

O instalador só gerencia os arquivos com os nomes acima. **Qualquer arquivo com outro nome sobrevive a reexecuções** — use `20-custom.conf` para o que for seu:

```
# /etc/monit/conf.d/20-custom.conf

# endpoint de saúde da aplicação, em vez da raiz
check host app_health with address 127.0.0.1
  if failed port 8080 protocol http request "/health" status = 200 for 3 cycles
    then exec "/usr/local/bin/ilert.sh ALERT HIGH 1 health"
    else if succeeded then exec "/usr/local/bin/ilert.sh RESOLVE HIGH 1 health"

# detecta crash loop: 3 quedas em 10 minutos, mesmo que cada uma dure segundos
check process minha-app with pidfile /run/minha-app.pid
  if does not exist 3 times within 10 cycles
    then exec "/usr/local/bin/ilert.sh ALERT HIGH 1 crashloop"
```

Depois: `sudo monit -t && sudo monit reload`.

### Chamando o `ilert.sh` direto

```
ilert.sh <ALERT|ACCEPT|RESOLVE> [PRIORITY] [SEVERITY] [SUFFIX]
```

- `PRIORITY`: `HIGH` escala pela escalation policy, `LOW` só registra
- `SEVERITY`: 1 a 5, sendo 1 o mais grave
- `SUFFIX`: token **sem espaço**, compõe o `alertKey` (`host/serviço/sufixo`)

O `SUFFIX` é obrigatório quando o mesmo serviço tem mais de um teste — sem ele, o recovery de um teste fecharia o alerta de outro. O `RESOLVE` precisa repetir exatamente o mesmo sufixo do `ALERT`.

## Como os limiares são calculados

Os defaults saem do hardware, não de números redondos:

- **Load**: warning em 1×`nproc`, critical em 2×`nproc`, sempre na média de 5min (a de 1min dispara em qualquer `apt upgrade`)
- **Memória**: escalonada pela RAM total — hosts pequenos recebem limiar mais apertado
- **Disco**: percentual **e** espaço livre em MB simultaneamente, ambos derivados do tamanho do volume. 10% de 4 TB são 400 GB (tranquilo); 10% de 20 GB são 2 GB (crítico). Volumes pequenos como `/boot` usam piso de 512 MB no warning — o suficiente para instalar um kernel — em vez de um valor fixo em GB que alertaria desde o primeiro dia
- **Swap**: warning em 10%, critical em 30%, com debounce longo de propósito. Swap pontual durante backup é normal; o que importa é swap que **não volta**. Ajuste com `--swap-warn` / `--swap-crit`

Depois de 1–2 semanas rodando, ajuste com dados reais: instale `sysstat` e use **p95 + 20%** como warning.

## Prioridades

Todo alerta chega no formato `<host> / <serviço>: <descrição>`.

**Falha de disponibilidade é `HIGH`** — processo caído, porta fora, socket inacessível, disco ou memória em nível crítico. Aciona a escalation policy.

**Warning de recurso é `LOW`** — load, memória, swap, disco e CPU nos limiares de aviso. Registra no ilert, aparece na lista e no app, mas não escala. Sem isso, disco em 86% e disco em 96% geram dois alertas `HIGH` do mesmo assunto e acordam alguém duas vezes pelo mesmo problema.

Para voltar ao comportamento anterior: `--warn-priority HIGH`.

### O crítico absorve o warning

Os sufixos seguem a convenção `<algo>-warn` e `<algo>-crit` para o mesmo assunto em dois níveis. Quando o crítico abre, o `ilert.sh` **fecha o warning correspondente** antes de enviar o alerta: você já foi acordado pelo `HIGH`, e o `LOW` do mesmo disco só ocuparia espaço na lista.

Se o crítico se resolver mas o valor continuar acima do limiar de aviso, o warning reaparece sozinho — o teste do Monit segue casando e o `repeat every` reemite dentro da janela.

Desligue com `ILERT_SUPERSEDE=0` em `/etc/ilert.env`.

## Anti-flapping

Um serviço em crash loop geraria pares ALERT/RESOLVE. Como cada RESOLVE fecha o alerta, o ALERT seguinte abre um **novo** — a deduplicação por `alertKey` só vale enquanto o alerta está aberto. Resultado: N alertas, N notificações, N escalations.

A solução é adiar o RESOLVE. Ele vira um marcador em `/var/lib/ilert/pending/` e só é despachado pelo `ilert-flush.sh` se o serviço continuar de pé por `ILERT_RESOLVE_DELAY` segundos (padrão 300). Se cair de novo antes disso, o ALERT cancela o pendente e o alerta original segue aberto acumulando eventos na timeline.

**Crash loop vira um alerta, não trinta.** Ajuste ou desative em `/etc/ilert.env` com `ILERT_RESOLVE_DELAY=0`.

## Recomendado no ilert

**`auto_resolution_timeout` no alert source.** Se o host morrer sem enviar RESOLVE, o alerta fica aberto para sempre. Algo como `PT4H` é uma boa rede de segurança.

**Confira se o `priority` do evento é respeitado.** Dependendo do tipo de integração, o alert source pode ignorar o campo e usar a prioridade dele. Se isso acontecer, derive a prioridade via event filter em ICL em vez de mexer no script.

**Mapeie a severity** no alert source de Heartbeat, que vem como `None` por padrão.

## Solução de problemas

```bash
sudo monit status                    # estado de todos os checks
sudo monit summary                   # visão compacta
sudo monit -t                        # valida sintaxe após editar
sudo systemctl reload monit          # aplica mudanças
sudo tail -f /var/log/monit.log
sudo journalctl -t ilert             # falhas de envio ao ilert
```

**Heartbeat com HTTP 400 ou 404.** Quase sempre é chave do objeto errado. A key do *alert source* (`il1hb2...`) não é pingável; você precisa da URL do *heartbeat monitor*. Teste direto:

```bash
sudo grep ILERT_HEARTBEAT_URL /etc/ilert.env
curl -i "<a URL completa do monitor>"
```

Se a doc do ilert mostrar `${YOUR-APIKEY}` e você colar isso literalmente no bash, o shell interpreta como "valor de `$YOUR`, ou `APIKEY` se não existir" e pinga o endpoint errado. Use a chave crua.

**`Cannot create unix socket` / `Connection failed` com o serviço saudável.** A mensagem engana: o Monit não tenta criar o arquivo `.sock`. Para conectar num socket unix o cliente cria seu próprio endpoint local e chama `connect()` — a mensagem cobre a operação toda. O teste é só "esse socket aceita conexão?". Se a unit do Monit tem `ProtectSystem=strict` ou `full`, `/run` e `/var` ficam somente-leitura para ele — e `connect()` num socket unix exige escrita no arquivo do socket. O mesmo sandbox impede o `ilert.sh` de gravar os marcadores de resolve adiado, desligando o anti-flapping em silêncio. Verifique com `systemctl show monit -p ProtectSystem`; o instalador detecta e cria um drop-in com `ReadWritePaths` para os diretórios de socket usados no host.

**Alerta chega como `status failed (1) -- no output`.** O Monit captura o stdout do programa e coloca na descrição. Se um script seu não imprime nada ao falhar, o alerta fica sem informação — imprima o erro no stdout.

**Permission denied.** `/etc/ilert.env` é 600 e os scripts são 700, ambos `root:root`, porque contêm a integration key em texto plano. Use `sudo -i` para uma sessão inteira em vez de `sudo` em cada comando — `sudo echo x >> /etc/arquivo` não funciona, o redirecionamento acontece no shell do usuário.

## Segurança

- A integration key fica **apenas** em `/etc/ilert.env`, modo 600. **Nunca versione esse arquivo.**
- O `ilert.sh` monta JSON em bash puro, sem `jq`, para não depender de nada além de `curl` no caminho de alerta.
- Textos vindos dos serviços monitorados (as descrições do Monit) são tratados como dados, nunca interpretados como shell.
- Prefira `--key-file` a `--key`.

Se você suspeita que uma key vazou — colada num chat, num print, num commit — **rotacione**: gere uma nova no ilert, atualize o `/etc/ilert.env` dos hosts e revogue a antiga.

Sugestão de `.gitignore` para quem for forkar:

```gitignore
*.env
*.key
ilert.env
*.bak-*
```

## Desinstalação

```bash
sudo ./install-monit-ilert.sh --uninstall
```

Remove os scripts, os arquivos de config gerados e o diretório de estado. **Preserva** `/etc/ilert.env`, o `monitrc` e os backups em `/var/backups/monit-ilert/` — remoção de segredo e de config base fica manual, de propósito.

## Requisitos

- Linux com **systemd** (a detecção de serviços usa `systemctl`)
- bash 4+
- root
- Debian/Ubuntu, RHEL/Rocky/Alma/Fedora, openSUSE

Em RHEL, o `monit` vem do EPEL — o script instala se necessário.

O gerenciador de pacotes do Alpine é reconhecido, mas o Alpine usa OpenRC e não
systemd: a detecção de serviços e os `start/stop program` não vão funcionar lá
sem adaptação. Considere Alpine não suportado por enquanto.

## Licença

MIT
