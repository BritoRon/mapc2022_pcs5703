# mapc2022_pcs5703

Esqueleto JaCaMo para o **2º Exercício Prático** de **PCS 5703 — Sistemas Multi-Agentes** (1º Quadrimestre de 2026, Escola Politécnica da USP).

Implementa um time de agentes para o **Multi-Agent Programming Contest 2022** (cenário *Agents Assemble II*), conforme exigido pelo enunciado, usando:

- **Jason** (plataforma de agentes BDI) — referência [4]
- **MOISE+** (modelo organizacional) — referência [3]
- **JaCaMo** (arcabouço integrador) — referência [2]
- **EISMASSim** (ponte EIS para o servidor MASSim 2022) — referência [6]

## Estrutura do projeto

```
mapc2022_pcs5703/
├── mapc2022.jcm              # arquivo principal: declara MAS, agentes, env e org
├── build.gradle              # build Gradle (chama jacamo.infra.JaCaMoLauncher)
├── settings.gradle
├── conf/
│   └── eismassimconfig.json  # config da ponte EIS<->MASSim
├── lib/
│   └── eismassim.jar         # eismassim-4.5-jar-with-dependencies copiado
└── src/
    ├── agt/                  # agentes Jason (.asl)
    │   ├── agente_base.asl   # planos comuns a todos
    │   ├── coordenador.asl   # papel social MOISE+ "coordinator"
    │   └── explorador.asl    # papel social MOISE+ "explorer"
    ├── env/                  # artefatos CArtAgO (Java)
    │   └── mapc/
    │       └── QuadroEquipe.java
    ├── org/                  # especificação MOISE+
    │   └── org.xml
    └── java/                 # código Java auxiliar
        └── jason/eis/
            └── EISAdapter.java  # ponte Jason<->EISMASSim
```

## Pré-requisitos

- JDK ≥ 17 (verifique: `java -version`)
- O servidor MASSim 2022 já compilado (em `../massim_2022/`, basta rodar `mvn package` lá uma vez)

## Como rodar

### 1. Suba o servidor MASSim em outro terminal

```bash
cd ../massim_2022
java -jar server/target/server-2022-1.1-jar-with-dependencies.jar \
     -conf server/conf/SampleConfig.json --monitor 8000
```

Servidor escutará em `localhost:12300`. Monitor web em [http://localhost:8000/](http://localhost:8000/).

### 2. Suba o time JaCaMo

```bash
cd mapc2022_pcs5703
./gradlew run
```

A primeira execução baixa o JaCaMo 1.3.0 do Maven (≈2 min). Depois é instantânea.

### 3. Inicie a partida no servidor

No terminal do servidor, pressione **ENTER** quando os 3 agentes do `mapc2022_pcs5703` (e idealmente os 3+ do time adversário) estiverem autenticados.

## Mapeamento Jason ↔ servidor

| Agente Jason (`.jcm`) | Entidade EIS (`eismassimconfig.json`) | Username MASSim |
|---|---|---|
| `coordenador1` | `coordenador1` | `agentA1` |
| `explorador1` | `explorador1` | `agentA2` |
| `explorador2` | `explorador2` | `agentA3` |

A senha de todos é `1` (vem do `SampleConfig.json` do servidor). Para usar o time **B** em vez do **A**, troque `agentA*` por `agentB*` no `eismassimconfig.json`.

## Como o servidor do contest (MASSim 2022) é configurado

Toda a configuração é feita por **arquivos JSON**. Um config de torneio (ex.: `server/conf/SampleConfig.json`) referencia uma **lista de simulações**, cada uma num arquivo em `server/conf/sim/`. O torneio roda esses sims **em sequência**, podendo cada um ter regras diferentes. Cada simulação define:

- **grid** (largura × altura) e os obstáculos/cavernas;
- **agentes por time** (`entities`) e quantos times competem (`teamsPerMatch`);
- **dispensers**, **goal zones** e **role zones** (quantidade);
- **tasks**: tamanho (nº de blocos), quantas simultâneas, reward, deadline;
- **papéis** (`default`/`worker`/`digger`/…), cada um com suas ações, visão e velocidade;
- **normas**, **eventos** (clear events) e o número de **passos**.

Os parâmetros **variam entre simulações** — não são fixos. Exemplos dos sims de amostra que acompanham o servidor:

| Sim | Grid | Agentes/time | Dispensers | Goal/Role zones | Tasks | Passos |
|---|---|---|---|---|---|---|
| `sim1` | **70×70** | **20** | 5–10 | 4 / 5 | tamanho 1–4, 2 simultâneas | 750 |
| `sim2` | **100×100** | **40** | 5–10 | 7 / 5 | tamanho 2–4, 3 simultâneas | 750 |

Pontos importantes para a estratégia:

- **Dois times competem** (`teamsPerMatch: 2`), cada um com **20–40 agentes**. Este esqueleto controla apenas **3 agentes** (declarados no `.jcm`/`eismassimconfig.json`) — para escalar, declare mais entidades.
- **O grid é TOROIDAL**: ao sair por uma borda, o agente reaparece na borda oposta. Isso afeta diretamente o rastreio de posição absoluta por soma de deslocamentos (a coordenada cresce sem limite a cada volta) — uma solução robusta precisa de **coordenadas conscientes do tamanho do grid** (módulo).
- As percepções são **relativas** (`absolutePosition: false`); o agente não recebe sua posição absoluta nem o tamanho do grid — precisa inferir/mapear.

### Alcance de visão por papel (e como foi determinado)

A visão é um **raio em distância de Manhattan**: um agente percebe toda célula a no máximo `r` passos de si (`scenario.md` §"Vision range"). O valor de `r` é **propriedade do papel**, definido em `server/conf/sim/roles/standard.json`:

| Papel | `vision` na config |
|---|---|
| `default` | 5 |
| `explorer` | 7 |
| `worker`, `constructor`, `digger` | (ausente) |

Surge a dúvida: se `worker` **não** declara `vision`, ele fica **cego** (visão 0) ao ser adotado? Isso é decisivo para a estratégia, pois um worker cego não conseguiria navegar até dispensers/goal zones por percepção.

**Método de verificação:** inspeção do código-fonte do servidor (`massim_2022/protocol/src/main/java/massim/protocol/data/Role.java`). O parser de papéis lê a visão com

```java
jsonRole.optInt("vision", baseRole.vision)
```

ou seja, quando a chave `vision` está ausente, o papel **herda a visão do papel-base** (o `default`, `vision = 5`). Confirmado também por `Entity.getVision()`, que retorna `this.role.vision()`.

**Conclusão:** `worker`/`constructor`/`digger` têm **visão 5** (herdada), não são cegos. Por isso a estratégia de **navegação por percepção relativa** (mover-se rumo a alvos *visíveis*) funciona inclusive na fase de worker — escolha de projeto adotada justamente por ser robusta ao **grid toroidal** (ver decisão de design abaixo).

## Decisões de design e validação (formato de relatório)

> Esta seção registra, em estilo de relatório, decisões técnicas tomadas durante o desenvolvimento e como foram validadas em testes ao vivo contra o servidor MASSim 2022. É material de apoio ao Item 5 (estratégia) e Item 6 (características técnicas) do enunciado.

### D1 — Navegação robusta ao grid toroidal: percepção relativa em vez de coordenadas absolutas

**Contexto.** O grid do cenário é **toroidal** (ao sair por uma borda, o agente reaparece na oposta) — verificado empiricamente: num grid 20×20 a posição rastreada chegou a `x = 300` apenas somando *moves* bem-sucedidos. O esqueleto mantém um mapa em **coordenadas absolutas** obtidas pela soma dos deslocamentos a partir do *spawn* (Passo 1).

**Problema observado.** A navegação gulosa em direção a uma coordenada absoluta gravada **diverge** num toro: a direção "alvo − posição" no referencial ilimitado pode corresponder ao caminho *longo* (dando a volta). O agente então se afasta do alvo; ao se mover, **re-percebe o mesmo alvo numa coordenada ainda mais distante** (o erro acumula), e passa a persegui-lo indefinidamente — comportamento visível como agentes "subindo direto, sumindo numa borda e reaparecendo na oposta". Em mapas grandes com obstáculos o efeito é lento (o agente perambula localmente); em grids pequenos e abertos, explode.

**Decisão.** Para o trecho final de aproximação, **navegar pela percepção relativa a alvos visíveis** (role zone, dispenser, goal zone): se o alvo está dentro do raio de visão, mover-se rumo ao seu *offset relativo* `(rx,ry)` — que é **sempre o caminho curto correto num toro**, independente de qualquer wrap. O mapa absoluto fica como **guia grosseiro** ("chegar perto") e *fallback* quando nada está visível. Implementado nos planos `acao_worker` do `explorador.asl` (regras `*_visivel` + plano `!mover_rel`).

**Limitação conhecida.** Uma solução plenamente correta exigiria **coordenadas conscientes do tamanho do grid** (aritmética modular), mas o servidor não fornece o tamanho do grid em modo `absolutePosition: false`; inferi-lo demandaria detecção de *loop closure*. A navegação por visão contorna o problema no que importa (aproximação final).

### D2 — Cenário de teste controlado (`DemoConfig.json`) para validar o pipeline de tarefa

**Contexto.** Os mapas do `SampleConfig` são grandes (70×70, 100×100) e aleatórios, com tarefas de 1–4 blocos. Completar uma tarefa de fato exige a **conjunção** de muitas condições no mesmo episódio (tarefa de 1 bloco *cardinal* + dispenser do tipo descoberto + role zone e goal zone alcançáveis + passos suficientes). Em testes ao vivo, essa conjunção quase nunca se alinhava por acaso, impedindo a **observação** do caminho `request → attach → submit` mesmo com o código implementado.

**Decisão.** Criar um cenário de demonstração controlado, **aditivo** (não altera os configs originais do servidor), em `massim_2022/server/conf/`:

- `DemoConfig.json` — config de torneio que roda o mesmo sim de demo algumas vezes em sequência (evita reiniciar o servidor a cada teste);
- `sim/sim_demo.json` — grid **30×30** aberto, **apenas tarefas de 1 bloco** (`size: [1,1]`), ~20 dispensers (todos os 3 tipos), 5 goal zones e 5 role zones, **3 agentes por time**.

Rodar com: `java -jar server/target/server-2022-1.1-jar-with-dependencies.jar -conf server/conf/DemoConfig.json --monitor 8000`.

**Resultados dos testes (parciais).** Neste cenário validou-se ao vivo a maior parte do pipeline: o coordenador **seleciona e anuncia** uma tarefa de 1 bloco; ambos exploradores **se promovem a worker**; e os workers **alcançam um role zone e adotam o papel `worker`** (≈ passo 12, `adopt: success`). A navegação foi tornada **exclusivamente por visão + exploração** (a navegação por coordenada absoluta foi removida do worker, pois divergia no toro — ver D1/D3): com isso o *runaway* de posição desapareceu (a posição fica contida, ex. `x[0,22] y[0,24]`) e a adoção do papel passou a ser confiável. As fases finais (`request → attach → submit`) ainda **não foram observadas**: após adotar o papel, o worker precisa **avistar e posicionar-se** num dispenser do tipo exigido (bloco a `(0,1)`), e isso depende de a exploração levá-lo até lá com o bloco no campo de visão — o que nem sempre ocorreu dentro de um episódio. Próximo passo focado: instrumentar e robustecer a fase de coleta (posicionamento por visão no dispenser).

### D3 — Exploração por cobertura (varredura serpentina) em vez de *random walk*

**Contexto.** A descoberta de recursos (role zones, dispensers, goal zones) dependia de *random walk*, deixando o sucesso ao acaso — agravado pelo *drift* toroidal quando havia viés direcional. Times fortes do MAPC usam **exploração sistemática** (cobertura), não sorte.

**Decisão.** Substituir o *random walk* por uma **varredura serpentina (*lawnmower*)** em `explorador.asl`: cada explorador segue uma direção primária por `cob_leg` passos, dá um passo perpendicular, reverte e repete, varrendo faixas. É **robusto ao toro** (conta passos *relativos*, sem coordenadas absolutas) e os dois exploradores partem de orientações diferentes para cobrir mais. **Efeito medido:** a área coberta cresceu (faixa larga em vez de coluna fina) e a adoção do papel `worker` passou a ocorrer cedo e de forma consistente.

**Limitação conhecida.** O comprimento da perna (`cob_leg`) idealmente acompanha a largura do grid; como o tamanho do grid não é perceptível, ele é um parâmetro ajustável (heurístico). Para o cenário de demo 30×30, `cob_leg = 20` deu boa cobertura.

## Como o exercício é atendido (mapeamento para o template do relatório)

| Item do enunciado | Onde está no projeto |
|---|---|
| **Item 2** — Análise e especificação do SMA | A definir no relatório, ancorado em [src/org/org.xml](src/org/org.xml) (papéis, missões, normas) |
| **Item 3** — Arquitetura e design do SMA | [mapc2022.jcm](mapc2022.jcm) (visão geral) + [src/org/org.xml](src/org/org.xml) (organização) + [src/env/mapc/QuadroEquipe.java](src/env/mapc/QuadroEquipe.java) (ambiente) |
| **Item 4** — Linguagens e plataforma | Jason (agentes), CArtAgO (ambiente), MOISE+ (org), tudo orquestrado por JaCaMo 1.3.0 |
| **Item 5** — Estratégia para time | A desenvolver: lógica em [src/agt/coordenador.asl](src/agt/coordenador.asl) (escolha de tarefa) e [src/agt/explorador.asl](src/agt/explorador.asl) (movimentação) |
| **Item 6** — Características técnicas | Robustez: tratamento de timeout, recuperação de agentes individuais (a evoluir) |
| **Item 7** — Discussão | Diferencial deste trabalho: uso explícito de MOISE+, ausente em [5] LTI-USP e nos JaCaMo Builders 2020/21 |

## Próximos passos sugeridos

Este esqueleto **conecta, percebe e age**, mas a inteligência ainda é trivial (random walk). Para evoluir, focar em:

1. **Logs/memória de exploração** — `explorador.asl` precisa registrar dispensers, taskboards e goal zones que vir, em coordenadas absolutas relativas à posição inicial. Padrão: ver paper [5] §3.1.
2. **Identificação de companheiros** — quando agentes se vêem, reconhecer-se via posição-espelho. Padrão: ver paper [5] §3.2.
3. **Protocolo de tarefa** — o coordenador escolhe task no taskboard, anuncia no `QuadroEquipe`, agentes que adotam papel `worker` (compatível via `formation-constraints` no org.xml) buscam blocos.
4. **Submissão** — montar pattern e chamar `submit(NomeTask)` numa goal zone.

## Referências consultadas

- Stabile Jr., M.F.; Sichman, J.S. *The LTI-USP Strategy to the 2020/2021 MAPC*. LNAI 12947, 2021. — referência [5] do enunciado.
- Amaral, C.J. et al. *JaCaMo Builders: Team Description for the MAPC 2020/21*. LNAI 12947, 2021. — discutido por usar JaCaMo+CArtAgO mas **sem MOISE+**, gap que este projeto preenche.
- Documentação oficial do cenário: [`../massim_2022/docs/scenario.md`](../massim_2022/docs/scenario.md)
