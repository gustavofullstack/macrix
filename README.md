# macrix

Automação do macOS + computer-use + metering de uso — servidor MCP aberto (open-core). **v0.31.0: 109 tools**, console web e medição por chave. Sem o teto de 100 chamadas/dia do Macuse, com quantos agentes quiser ao mesmo tempo.

Inspirado no [Macuse](https://macuse.app), reescrito do zero em Swift, sem dependências externas.

## Por que existe

- **Sem o teto deles**: o free do Macuse trava em 100 chamadas/dia; aqui o tier `free` tem 1000/dia/chave e os pagos são ilimitados na prática. O limite é o seu hardware.
- **Multi-agente provado**: registro de tools com lock, uma conexão por task — 25 chamadas paralelas com a mesma chave respondem 25/25 (medido em 21/09/2026).
- **Chaves múltiplas**: `MACRIX_KEYS` (vírgula) e/ou `~/.config/macrix/keys` (uma por linha). Qualquer chave válida entra, ao mesmo tempo que qualquer outra.

## Build

```sh
swift build -c release   # binário em .build/release/macrix
swift test               # 80 testes, zero rede
```

Só macOS 13+. Só frameworks do sistema (Foundation, EventKit, Network, CryptoKit, CoreImage) + o `sqlite3` que já vem no sistema.

## Uso

```sh
export MACRIX_KEYS="chave-agente-1,chave-agente-2"
macrix serve --port 35730
macrix keys     # de onde as chaves vêm + quantas
macrix version
```

Endpoints: `POST /mcp` (Bearer [REDACTED]ório), `GET /health` (aberto), `GET /` (console, aberto), `GET /catalog` (109 tools em JSON, aberto), `GET /usage` (medição da chave, Bearer).

## Tools (v0.30 — 109)

Contagem medida via `GET /catalog` em 21/09/2026. Fonte da verdade é o endpoint; a tabela agrupa por família:

| Família | Tools |
|---|---|
| Apps Apple (calendário, lembretes, notas, atalhos, mail/messages, contatos, tela) | 14 |
| Sistema e sondas (sys, launchd, host, tailscale, meta, plist, áudio, markdown) | 19 |
| Arquivos e texto (file, zip, text, grep, csv) | 12 |
| Web e rede (chromium, url, net) | 11 |
| Codec e dados (b64, sha, uuid, json, qr, random, imagem, dir) | 11 |
| Computer-use | 9 |
| Jev/TypeSafe (route, rerank, eval, check, skill, models, ping) | 7 |
| Clipboard e UI (clip, open, notify, voz-arquivo, quit) | 6 |
| Catálogo e metering (catalog, usage, providers, health) | 6 |
| Git (status, log, diff) + relógio | 5 |
| Voz → Jev → ação antes da frase acabar (`voice_decide`, `voice_listen`) | 2 |
| Harness: CLIs como tools + Jev escolhe a faixa (`agents_list`, `agent_run`, `agent_route`, `agents_gate`, `journey_run`, `journey_approve`, `env_inventory`) | 7 |

Calendário/Lembretes pedem autorização na 1ª vez; Notas pede Full Disk Access. Sem permissão, a tool devolve erro estruturado — nunca quebra a sessão. Voz nunca toca no alto-falante (`tts_render` gera arquivo).

## Harness: os CLIs do Mac como tools, o Jev escolhe a faixa (v0.26)

`agents_list` mostra as faixas instaladas: `claude_fable` (o mais difícil: arquitetura, verificação), `claude_opus` (implementação média), `claude_sonnet` (simples e repetitivo), `muse` (volume barato, Meta Muse Spark 1.3 community), `codex` e `antigravity` (revisão cruzada, limitados por cota), `opencode`, `goose`. `agent_run` roda um prompt headless numa faixa dentro de um workspace permitido (`~/Projetos`, `~/Documents`, `/tmp`), com timeout e saída limitada; o prompt vai como argv, nunca por shell; `yolo=true` acrescenta a flag de auto-aprovação do próprio CLI. `agent_route` pergunta ao Jev (choice) qual faixa a tarefa merece e se precisa de revisão cruzada (noul); `execute=true` já roda. **Gate (v0.27):** no máximo 2 `agent_run` em voo; `op_id` repetido em 10 min não roda de novo; faixa que responde 429/quota fica suspensa 30 min; kill por timeout registra `unknown`, nunca `settled`; filhos do CLI são mortos junto (`pkill -P`). Cada tentativa vai para `~/.config/macrix/agent-ledger.jsonl` (ts, lane, op_id, seconds, exit, status). `agents_gate` mostra o estado. No ledger, `execution_status` (settled/unknown/quota/refused) e `cost_status` andam separados: `exit 0` prova execução, nunca custo — `cost_status` fica `unknown` até algo conciliar com o medidor do provider.

**Jornada (v0.29):** `journey_run` amarra tudo num `journey_id` único: Jev roteia → `needs_review ≥ 0,70` para e devolve `needs_human_review` → gate admite (o mesmo id nunca roda duas vezes) → a faixa executa no workspace → ledger grava execution/cost → log de 5 passos com o desfecho.

**Aprovação e persistência (v0.30):** quando a jornada para em `needs_human_review`, sai um token `apr_…` de **uso único**, válido 15 min, amarrado ao `journey_id`, à faixa e ao hash do texto da tarefa; `journey_approve` só executa com id + token + o mesmo texto. Tarefa que cita marcador de produção (IPs das VPS, EasyPanel, `docker restart/stop`, `rm -rf /`…) é bloqueada por padrão, com ou sem token. O estado do gate (op_ids vistos, suspensões, execuções em voo, aprovações) vive em `~/.config/macrix/agent-ledger-state.json`, gravado atomicamente; ao reiniciar, execução que estava em voo vira `unknown` no ledger e o slot é liberado.

**Ledger canônico (v0.31):** o MACRIX não reimplementa contabilidade. Com `~/.config/macrix/ledger.json` (`python` ≥ 3.11, `bridge` = `scripts/ledger_bridge.py` do triqhub-os fixado por SHA num worktree, `database`, `tenant`, `attempt_units`), cada `agent_run` faz `reserve → dispatch` antes de o processo existir e `settle` (unidades de tentativa, `price_version=attempt-units-v0`) ou `mark_unknown` (kill por timeout: reserva preservada, conta congelada até revisão) depois. Conta congelada recusa novas tentativas. O tenant é separado do do JEV. Sem o arquivo, o ledger fica desligado e o `agents_gate` diz isso. `env_inventory` é o censo do que os agentes têm aqui: MCPs, skills, commands, plugins, hooks, agentes do opencode, perfis do codex, skills do muse (só nomes).

## Voz: age antes de a frase acabar (v0.25)

O padrão do demo de Andy Gao (X, 18/09/2026) com o Jev: a fala é transcrita em streaming pelo Speech.framework e **cada trecho parcial vira uma chamada ao Jev** com perguntas tipadas — `intent` (choice), `app` (choice entre candidatos que o código extraiu), `complete`, `addressed`, `destructive` (noul). O código decide: abrir app dispara assim que `intent ≥ 0,70` e `app ≥ 0,60`, mesmo com `complete` baixo; fechar app, abrir URL e pesquisar esperam `complete ≥ 0,60`; conversa (`addressed < 0,50`) é ignorada; a mesma ação não repete dentro da mesma frase. O Jev nunca gera texto: nome de app, URL e termo de busca saem do transcript por código e o Jev só escolhe.

**Preparar ≠ executar (v0.28):** duas perguntas a mais por parcial, `cancel` e `review` (noul). Negação (`cancel ≥ 0,70`: “não, cancela, esquece”) cancela a frase inteira e nada mais dispara nela. Ação destrutiva (`≥ 0,70`) ou que o Jev diz merecer confirmação (`review ≥ 0,60`, exceto abrir app) vira `CONFIRM`: fica preparada e só executa quando o código vê um “sim / pode / confirma” no fim do próximo trecho. Nenhum número de confiança passa por cima disso. Medido com Jev real: “abre o notas… não, esquece, cancela” → cancel 0,98 → CANCELLED; “abre o notas e” → ACT em ~700 ms.

```sh
macrix voice-say "abre o notas e"             # dry-run: mostra os números do Jev e o veredito
macrix voice-say "abre o notas e" --execute   # age (abre o Notes)
macrix voice --seconds 20 --locale pt-BR      # microfone ao vivo; --dry-run só mostra
```

Tools MCP: `voice_decide` (transcript → decisão; `execute=true` age; `is_final=true` fecha a frase) e `voice_listen` (microfone por N s, age a cada parcial). Chave: `TYPESAFE_API_KEY` no ambiente ou no cofre `~/.config/frota/credenciais.env`; modelo fixado `jev-1.13.0`.

Permissões: o binário embute um `Info.plist` (`__info_plist`) com `NSMicrophoneUsageDescription` e `NSSpeechRecognitionUsageDescription`. Rodando a partir de um terminal de outro app, o macOS atribui o pedido ao **app pai** (Claude, Terminal…) e pode abortar com TCC; via launchd (`com.sug.macrix`) ou `launchctl submit` a atribuição é ao próprio macrix e o diálogo de permissão aparece uma vez.

## cmux

`cmux/mcp.json` tem o bloco pronto (agora apontando o binário `macrix`) para os agentes que rodam nos painéis do [cmux](https://cmux.dev). `SKILL.md` documenta o uso agente-a-agente.

## Modelo (open-core, igual ao Macuse)

Código MIT e grátis: `free` 1000/dia, `starter` US$20 (10k/dia), `growth` US$50 (50k/dia), `scale` US$100 (200k/dia), `max` US$200 e `lifetime` ilimitados. Quota estourada devolve erro `-32000` nomeando o tier — nunca silencia. Tudo passa pelo `usage_status` e pelo `GET /usage`. Cobrança via processador: checklist em `BILLING.md` (conta e emissão são do dono; o servidor já sabe ler o arquivo de licença e rebaixar sozinho no vencimento).

## Licença

MIT (código). Tiers comerciais via arquivo de licença local.
